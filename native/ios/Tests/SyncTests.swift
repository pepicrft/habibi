import CryptoKit
import Foundation
import Testing

private final class SyncSecrets: HabibiSyncSecretStorage, @unchecked Sendable {
    var data: Data?
    var rejectWrites = false
    func load() throws -> Data? { data }
    func save(_ value: Data) throws {
        if rejectWrites { throw HabibiFailure(message: "Keychain unavailable") }
        data = value
    }
    func delete() throws { data = nil }
}

// Fake only the network/storage service. Encryption, sync lineage, validation,
// outbox persistence and restoration all run through the real Rust bridge.
private actor SyncServer: HabibiSyncHTTP {
    let origin = try! HabibiSyncOrigin("https://sync.example")
    var vaultToken: String?
    var records: [(String, Data)] = []
    var drafts: Data?
    var dropUpload = false
    var dropRefresh = false
    var badDigest = false
    var badIssuer = false
    var refreshConsumed = false
    var revoked = false
    let clientID = "37eb736a-a2da-47a3-8c07-9fa07dd8bcc5"

    func loseNextUpload() { dropUpload = true }
    func loseRefresh() { dropRefresh = true }
    func corruptDigest() { badDigest = true }
    func corruptIssuer() { badIssuer = true }
    func count() -> Int { records.count }

    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        #expect(url.scheme == "https" && url.host == "sync.example")
        func response(_ status: Int, _ value: [String: Any]) throws -> (Data, HTTPURLResponse) {
            let data = try JSONSerialization.data(withJSONObject: value)
            #expect(data.count <= limit)
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        func metadata(_ index: Int) -> [String: Any] {
            ["id": records[index].0, "sequence": index + 1, "bytes": records[index].1.count,
             "sha256": badDigest ? String(repeating: "0", count: 64) : SHA256.hash(data: records[index].1).map { String(format: "%02x", $0) }.joined()]
        }
        if url.path == "/.well-known/oauth-authorization-server" {
            return try response(200, ["issuer": badIssuer ? "https://other.example" : origin.value,
                "authorization_endpoint": origin.value + "/oauth/authorize", "token_endpoint": origin.value + "/oauth/token",
                "registration_endpoint": origin.value + "/oauth/register", "revocation_endpoint": origin.value + "/oauth/revoke",
                "code_challenge_methods_supported": ["S256"], "authorization_response_iss_parameter_supported": true])
        }
        if url.path == "/oauth/register" {
            return try response(201, ["client_id": clientID, "redirect_uris": [HabibiSyncAuthorization.redirect], "token_endpoint_auth_method": "none"])
        }
        if url.path == "/oauth/token" {
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            if body.contains("grant_type=refresh_token") {
                #expect(!refreshConsumed)
                refreshConsumed = true
                if dropRefresh { throw HabibiFailure(message: "Response lost after refresh rotation") }
            } else { #expect(body.contains("code_verifier=")) }
            return try response(200, ["access_token": "fictional-access-token", "refresh_token": "fictional-refresh-token", "token_type": "Bearer", "expires_in": 900, "scope": "vaults:sync"])
        }
        if url.path == "/oauth/revoke" { revoked = true; return try response(200, [:]) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fictional-access-token", !revoked else { return try response(401, [:]) }
        if url.path == "/v1/me" { return try response(200, ["sub": "18af5843-6b1f-46cd-b3fa-829e215c5d16"]) }
        if url.path == "/v1/vaults" {
            let value = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            if vaultToken != nil { return try response(409, [:]) }
            vaultToken = value["token"]
            #expect(value["key"] == nil)
            return try response(201, ["id": value["id"]!])
        }
        guard let vaultToken, request.value(forHTTPHeaderField: "X-Habibi-Vault-Token") == vaultToken else { return try response(401, [:]) }
        if url.path.hasSuffix("/drafts") {
            func etag(_ bytes: Data) -> String { "\"" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "\"" }
            if request.httpMethod == "PUT" {
                let bytes = request.httpBody!
                if let drafts {
                    guard request.value(forHTTPHeaderField: "If-Match") == etag(drafts) else { return try response(412, [:]) }
                } else {
                    guard request.value(forHTTPHeaderField: "If-None-Match") == "*" else { return try response(412, [:]) }
                }
                drafts = bytes
                return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }
            guard let drafts else { return try response(404, [:]) }
            return (drafts, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/octet-stream", "ETag": etag(drafts)])!)
        }
        if url.path.hasSuffix("/records") {
            let after = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)!
            let indices = Array(records.indices.dropFirst(after).prefix(100))
            return try response(200, ["records": indices.map(metadata), "cursor": indices.last.map { $0 + 1 } ?? after])
        }
        let id = url.lastPathComponent
        if request.httpMethod == "PUT" {
            let bytes = request.httpBody!
            #expect(bytes.prefix(4) == Data("HAB1".utf8))
            if let index = records.firstIndex(where: { $0.0 == id }) {
                return try response(records[index].1 == bytes ? 200 : 409, metadata(index))
            }
            records.append((id, bytes))
            if dropUpload { dropUpload = false; throw HabibiFailure(message: "Response lost after durable server upload") }
            return try response(201, metadata(records.count - 1))
        }
        guard let entry = records.first(where: { $0.0 == id }) else { return try response(404, [:]) }
        return (entry.1, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/octet-stream"])!)
    }
}

private func connect(_ server: SyncServer, secrets: SyncSecrets = SyncSecrets()) async throws -> HabibiSyncAccount {
    let account = HabibiSyncAccount(origin: server.origin, storage: secrets, http: server)
    let pending = try await account.begin()
    var callback = URLComponents(string: HabibiSyncAuthorization.redirect)!
    callback.queryItems = [URLQueryItem(name: "state", value: pending.state), URLQueryItem(name: "iss", value: server.origin.value), URLQueryItem(name: "code", value: "fictional-code")]
    try await account.finish(pending, callback: callback.url!)
    return account
}

@MainActor
@Test func automaticEncryptedDraftHandoffPreservesOfflineVersionsAndLiveContext() async throws {
    let server = SyncServer()
    let a = HabibiSession(store: HabibiStore(persistence: MemoryPersistence()), syncAccount: try await connect(server), draftDeviceID: UUID().uuidString.lowercased())
    #expect(await a.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    a.newConversation(); a.composer = "Start here"
    let recovery = try await a.exportRecovery()
    let backup = try JSONSerialization.data(withJSONObject: recovery["backup"]!)
    let b = HabibiSession(store: HabibiStore(persistence: MemoryPersistence()), syncAccount: try await connect(server), draftDeviceID: UUID().uuidString.lowercased())
    #expect(await b.recover(backup, key: recovery["recoveryKey"] as! String))
    let id = try #require(a.activeConversationID)
    b.openConversation(id)
    a.draftSyncActive = true; b.draftSyncActive = true
    a.composer = "Phone draft"; await a.synchronizeDrafts(); await b.synchronizeDrafts()
    #expect(b.composer == "Phone draft")
    a.composer = "Phone offline"; b.composer = "Tablet offline"
    a.cloudConsent = true
    await a.synchronizeDrafts(); await b.synchronizeDrafts(); await a.synchronizeDrafts()
    #expect(a.composer == "Phone offline")
    #expect(b.composer == "Tablet offline")
    #expect(a.otherDrafts == ["Tablet offline"])
    #expect(b.otherDrafts == ["Phone offline"])
    #expect(a.messages.isEmpty && b.messages.isEmpty)
    #expect(a.cloudConsent)
    #expect(await server.count() == 0)
    await a.selectDraftVersion("Tablet offline")
    a.composer = "Continued tablet draft"
    await a.synchronizeDrafts(); await b.synchronizeDrafts()
    #expect(a.otherDrafts == ["Phone offline"])
    #expect(Set(b.snapshot?.drafts?.first?.versions.map(\.text) ?? []) == Set(["Phone offline", "Continued tablet draft"]))
    // Recovery starts with an unopened vault, but may reuse this device's old replica ID.
    let restored = HabibiSession(store: HabibiStore(persistence: MemoryPersistence()), syncAccount: try await connect(server), draftDeviceID: a.draftDeviceID)
    #expect(await restored.recover(backup, key: recovery["recoveryKey"] as! String))
    restored.openConversation(id); restored.composer = "Edited restored backup"
    restored.draftSyncActive = true
    await restored.synchronizeDrafts(); await b.synchronizeDrafts()
    #expect(restored.otherDrafts.contains("Continued tablet draft"))
    #expect(restored.otherDrafts.contains("Phone offline"))
    #expect(b.otherDrafts.contains("Edited restored backup"))
    a.setDraftSyncActive(false); b.setDraftSyncActive(false); restored.setDraftSyncActive(false)
}

@Test func nativeSignInUsesPKCEAndRejectsConfusedOrReplayedCallbacks() async throws {
    let origin = try HabibiSyncOrigin("https://sync.example")
    let now = Date()
    let transaction = try HabibiSyncAuthorization(origin: origin, clientID: "client", now: now)
    let parameters = URLComponents(url: transaction.url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(parameters.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
    #expect(parameters.first(where: { $0.name == "code_challenge" })?.value == Data(SHA256.hash(data: Data(transaction.verifier.utf8))).habibiBase64URL)
    #expect(transaction.state != (try HabibiSyncAuthorization(origin: origin, clientID: "client")).state)
    let valid = HabibiSyncAuthorization.redirect + "?state=\(transaction.state)&iss=https%3A%2F%2Fsync.example&code=valid-code"
    #expect(try transaction.code(from: URL(string: valid)!) == "valid-code")
    for invalid in [valid + "&state=duplicate", valid + "#fragment", valid.replacingOccurrences(of: "sync.example", with: "other.example"),
                    valid.replacingOccurrences(of: "fyi.habibi.ios:/", with: "fyi.habibi.ios://attacker/"), valid.replacingOccurrences(of: "code=valid-code", with: "error=denied")] {
        #expect(throws: (any Error).self) { try transaction.code(from: URL(string: invalid)!) }
    }
    #expect(throws: (any Error).self) { try transaction.code(from: URL(string: valid)!, now: now.addingTimeInterval(900)) }
    #expect(throws: (any Error).self) { try HabibiSyncOrigin("http://sync.example", development: true) }
    #expect(throws: (any Error).self) { try HabibiSyncOrigin("https://sync.example/other") }
    let server = SyncServer()
    let account = try await connect(server)
    await #expect(throws: (any Error).self) { try await account.finish(transaction, callback: URL(string: valid)!) }
    let unsafe = SyncServer(); await unsafe.corruptIssuer()
    await #expect(throws: (any Error).self) { _ = try await HabibiSyncAccount(origin: origin, storage: SyncSecrets(), http: unsafe).begin() }
}

@Test func lostRefreshResponseCannotReplayAfterRestartAndDisconnectKeepsVaultSeparate() async throws {
    let server = SyncServer()
    let secrets = SyncSecrets()
    let account = try await connect(server, secrets: secrets)
    var stored = try JSONSerialization.jsonObject(with: secrets.data!) as! [String: Any]
    stored["expiresAt"] = Date().addingTimeInterval(-100).timeIntervalSinceReferenceDate
    secrets.data = try JSONSerialization.data(withJSONObject: stored)
    await server.loseRefresh()
    await #expect(throws: (any Error).self) { try await account.verifyAccount() }
    #expect(try await account.connected() == false)
    let restarted = HabibiSyncAccount(origin: server.origin, storage: secrets, http: server)
    await #expect(throws: (any Error).self) { try await restarted.verifyAccount() }
    #expect(!String(decoding: secrets.data!, as: UTF8.self).contains("fictional-refresh-token"))
    try await restarted.disconnect()
    #expect(secrets.data == nil)
}

@Test func nativeSyncRestoresAcrossDevicesAndRequiresAnExplicitConflictChoice() async throws {
    let server = SyncServer()
    let account = try await connect(server)
    let first = HabibiStore(persistence: MemoryPersistence())
    _ = try await first.create(profile: .init(name: "Noor", goals: ["health"], style: "warm"))
    let firstSync = HabibiSynchronizer(store: first, account: account)
    #expect(try await firstSync.run().conflict == false)
    let recovery = try await first.call("export_recovery")
    let second = HabibiStore(persistence: MemoryPersistence())
    _ = try await second.recover(backup: JSONSerialization.data(withJSONObject: recovery["backup"]!), key: recovery["recoveryKey"] as! String)
    let secondSync = HabibiSynchronizer(store: second, account: account)
    _ = try await secondSync.run()
    _ = try await first.call("profile", arguments: ["profile": ["name": "First device edit", "goals": ["learning"], "style": "direct"]], persist: true)
    let archive: [[String: Any]] = [["id": "534819a2-0903-492a-bbaa-58dd4a9cabdc", "createdAt": "2026-10-26T10:00:00Z", "composer": "Second device draft 🌿", "messages": []]]
    _ = try await second.call("save_conversations", arguments: ["conversations": archive], persist: true)
    _ = try await firstSync.run()
    let conflict = try await secondSync.run()
    #expect(conflict.conflict)
    #expect(try await second.restore()?.profile.name == "Noor")
    #expect(try await second.restore()?.conversations?.first?.composer == "Second device draft 🌿")
    let stale = HabibiSyncResolution(remoteID: nil, expectedHeads: [])
    await #expect(throws: (any Error).self) { _ = try await secondSync.run(resolution: stale) }
    let resolved = try await secondSync.run(resolution: .init(remoteID: nil, expectedHeads: conflict.heads.map(\.id)))
    #expect(!resolved.conflict)
    _ = try await firstSync.run()
    #expect(try await first.restore()?.profile.name == "Noor")
    #expect(try await first.restore()?.conversations?.first?.composer == "Second device draft 🌿")
    #expect(await server.count() == 3)
}

@Test func lostUploadResponseRetriesExactCiphertextWithoutLosingLaterEdits() async throws {
    let server = SyncServer()
    let account = try await connect(server)
    let storage = MemoryPersistence()
    let first = HabibiStore(persistence: storage)
    _ = try await first.create(profile: .init(name: "Before response loss", goals: ["health"], style: "warm"))
    await server.loseNextUpload()
    await #expect(throws: (any Error).self) { _ = try await HabibiSynchronizer(store: first, account: account).run() }
    #expect(await server.count() == 1)
    #expect(try await HabibiSynchronizer(store: first, account: account).status().pending != nil)
    let reopened = HabibiStore(persistence: storage)
    _ = try await reopened.restore()
    _ = try await reopened.call("profile", arguments: ["profile": ["name": "Edit after lost response", "goals": ["learning"], "style": "direct"]], persist: true)
    let status = try await HabibiSynchronizer(store: reopened, account: account).run()
    #expect(!status.dirty && !status.conflict && status.pending == nil)
    #expect(await server.count() == 2)
    #expect(try await reopened.restore()?.profile.name == "Edit after lost response")
    #expect(!String(decoding: storage.document!, as: UTF8.self).contains("Edit after lost response"))
}

@Test func failedLocalOutboxCommitNeverUploadsAndInvalidRemoteHistoryNeverReplacesData() async throws {
    let server = SyncServer()
    let account = try await connect(server)
    let storage = MemoryPersistence()
    let store = HabibiStore(persistence: storage)
    _ = try await store.create(profile: .init(name: "Keep this safe", goals: ["health"], style: "warm"))
    let before = storage.document
    storage.rejectWrites = true
    await #expect(throws: (any Error).self) { _ = try await HabibiSynchronizer(store: store, account: account).run() }
    #expect(await server.count() == 0)
    #expect(storage.document == before)
    storage.rejectWrites = false
    _ = try await HabibiSynchronizer(store: store, account: account).run()
    let recovery = try await store.call("export_recovery")
    let secondStorage = MemoryPersistence()
    let second = HabibiStore(persistence: secondStorage)
    _ = try await second.recover(backup: JSONSerialization.data(withJSONObject: recovery["backup"]!), key: recovery["recoveryKey"] as! String)
    _ = try await store.call("profile", arguments: ["profile": ["name": "Remote change", "goals": ["learning"], "style": "direct"]], persist: true)
    _ = try await HabibiSynchronizer(store: store, account: account).run()
    let oldDocument = secondStorage.document
    await server.corruptDigest()
    await #expect(throws: (any Error).self) { _ = try await HabibiSynchronizer(store: second, account: account).run() }
    #expect(secondStorage.document == oldDocument)
    #expect(try await second.restore()?.profile.name == "Keep this safe")
}
