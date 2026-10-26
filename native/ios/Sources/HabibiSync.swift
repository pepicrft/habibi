import Foundation
import SwiftUI

struct HabibiSyncStatus: Decodable {
    struct Record: Codable, Identifiable, Equatable {
        let id: String
        let sha256: String
        let bytes: Int
    }
    struct Pending: Decodable {
        let id: String
        let envelope: String
        let sha256: String
        let bytes: Int
    }
    let vaultId: String
    let token: String
    let cursor: Int64
    let heads: [Record]
    let dirty: Bool
    let conflict: Bool
    let pending: Pending?

    init(_ result: [String: Any]) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: result))
    }
}

struct HabibiSyncResolution {
    let remoteID: String?
    let expectedHeads: [String]
}

// One manual synchronization owns the UI's mutation gate. Disk commits happen
// inside HabibiStore, before uploads, cursor advancement or state publication.
struct HabibiSynchronizer {
    let store: HabibiStore
    let account: HabibiSyncAccount

    private struct Page: Decodable {
        struct Entry: Decodable {
            let id: String
            let sequence: Int64
            let sha256: String
            let bytes: Int
        }
        let records: [Entry]
        let cursor: Int64
    }

    func status() async throws -> HabibiSyncStatus {
        try await HabibiSyncStatus(store.call("sync_status", arguments: ["origin": account.origin.value]))
    }

    func run(resolution: HabibiSyncResolution? = nil) async throws -> HabibiSyncStatus {
        try await account.verifyAccount()
        var current = try await status()
        var resolution = resolution
        for _ in 0..<3 {
            if let pending = current.pending {
                try await upload(pending, status: current)
                current = try await status()
            }
            current = try await scan(current)
            if let choice = resolution {
                guard current.conflict, current.heads.map(\.id).sorted() == choice.expectedHeads.sorted() else {
                    throw HabibiFailure(message: "The available versions changed. Review the conflict again before choosing.")
                }
                var arguments: [String: Any] = ["origin": account.origin.value, "choice": choice.remoteID == nil ? "local" : "remote"]
                if let id = choice.remoteID {
                    guard current.heads.contains(where: { $0.id == id }) else { throw invalidHistory }
                    arguments["recordId"] = id
                    arguments["envelope"] = try await download(id, status: current).habibiBase64URL
                }
                _ = try await store.call("sync_resolve", arguments: arguments, persist: true)
                resolution = nil
                current = try await status()
                continue
            }
            if current.conflict { return current }
            if current.dirty {
                _ = try await store.call("sync_prepare", arguments: ["origin": account.origin.value], persist: true)
                current = try await status()
                continue
            }
            if let head = current.heads.first {
                let bytes = try await download(head.id, status: current)
                _ = try await store.call("sync_adopt", arguments: ["origin": account.origin.value, "recordId": head.id, "envelope": bytes.habibiBase64URL], persist: true)
            }
            return try await status()
        }
        throw HabibiFailure(message: "More changes arrived while syncing. Your progress is saved; tap Sync now again.")
    }

    private func upload(_ pending: HabibiSyncStatus.Pending, status: HabibiSyncStatus) async throws {
        let path = "/v1/vaults/\(status.vaultId)/records/\(pending.id)"
        let (data, response) = try await account.authorized(path, method: "PUT", body: Data(habibiBase64URL: pending.envelope),
            contentType: "application/octet-stream", vaultToken: status.token)
        try check(response, expected: [200, 201])
        guard var metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any], metadata.removeValue(forKey: "id") as? String == pending.id else { throw invalidHistory }
        metadata["origin"] = account.origin.value
        metadata["recordId"] = pending.id
        _ = try await store.call("sync_complete", arguments: metadata, persist: true)
    }

    private func scan(_ initial: HabibiSyncStatus) async throws -> HabibiSyncStatus {
        var status = initial
        var registered = false
        var downloaded = 0
        while downloaded <= 10_000 {
            let (data, response) = try await account.authorized("/v1/vaults/\(status.vaultId)/records?after=\(status.cursor)", vaultToken: status.token)
            if response.statusCode == 401 && !registered {
                // /v1/me was already authenticated. A first sync may need to
                // register this random vault; a different capability must fail.
                registered = true
                let body = try JSONSerialization.data(withJSONObject: ["id": status.vaultId, "token": status.token])
                let (_, response) = try await account.authorized("/v1/vaults", method: "POST", body: body, contentType: "application/json")
                try check(response, expected: [201, 409])
                continue
            }
            try check(response, expected: [200])
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard page.records.count <= 100, page.cursor == (page.records.last?.sequence ?? status.cursor),
                  page.cursor >= status.cursor else { throw invalidHistory }
            for entry in page.records {
                guard downloaded < 10_000, entry.sequence == status.cursor + 1, UUID(uuidString: entry.id)?.uuidString.lowercased() == entry.id,
                      (64...1024 * 1024).contains(entry.bytes), entry.sha256.count == 64 else { throw invalidHistory }
                let bytes = try await download(entry.id, status: status)
                let result = try await store.call("sync_ingest", arguments: ["origin": account.origin.value, "recordId": entry.id,
                    "envelope": bytes.habibiBase64URL, "sequence": entry.sequence, "sha256": entry.sha256, "bytes": entry.bytes], persist: true)
                status = try HabibiSyncStatus(result)
                downloaded += 1
            }
            if page.records.count < 100 { return status }
        }
        throw invalidHistory
    }

    private func download(_ id: String, status: HabibiSyncStatus) async throws -> Data {
        let (data, response) = try await account.authorized("/v1/vaults/\(status.vaultId)/records/\(id)", vaultToken: status.token, limit: 1024 * 1024)
        try check(response, expected: [200])
        guard response.mimeType == "application/octet-stream", data.count >= 64 else { throw invalidHistory }
        return data
    }
    private func check(_ response: HTTPURLResponse, expected: Set<Int>) throws {
        guard expected.contains(response.statusCode) else {
            throw HabibiFailure(message: "Sync stopped (HTTP \(response.statusCode)). Local edits and any pending encrypted upload are kept. Reconnect if authorization expired.")
        }
    }
    private var invalidHistory: HabibiFailure { HabibiFailure(message: "The sync history is incomplete or invalid. Your local data has not been replaced.") }
}

extension HabibiSession {
    func refreshSyncStatus() async {
        do {
            syncConnected = try await syncAccount.connected()
            if snapshot != nil { syncStatus = try await HabibiSynchronizer(store: store, account: syncAccount).status() }
        } catch { syncError = error.localizedDescription }
    }

    func connectSync() async {
        guard !syncing, !chatRunning, review == nil, !busy else { return }
        syncing = true; syncError = nil
        defer { syncing = false }
        do {
            let authorization = try await syncAccount.begin()
            let callback = try await syncBrowser.open(authorization.url)
            try await syncAccount.finish(authorization, callback: callback)
            syncConnected = true
        } catch {
            await syncAccount.cancelAuthorization()
            syncError = error.localizedDescription
        }
    }

    func synchronize(resolution: HabibiSyncResolution? = nil) async {
        guard snapshot != nil, !syncing, !chatRunning, review == nil, !busy else { return }
        syncing = true; syncError = nil
        defer { syncMutationsLocked = false; syncing = false }
        await flushConversations()
        guard conversationsSaved else { syncError = conversationSaveError ?? "Save your conversations before syncing."; return }
        syncMutationsLocked = true
        do {
            syncStatus = try await HabibiSynchronizer(store: store, account: syncAccount).run(resolution: resolution)
            try await reloadSyncedVault()
            if syncStatus?.conflict == false { lastSynced = Date() }
        } catch {
            // Earlier cursor/adoption/outbox writes may already be durable.
            // Reload those commits even if a later request lost its response.
            try? await reloadSyncedVault()
            syncError = error.localizedDescription
        }
        syncConnected = (try? await syncAccount.connected()) == true
        syncStatus = try? await HabibiSynchronizer(store: store, account: syncAccount).status()
    }

    func disconnectSync() async {
        guard !syncing else { return }
        syncing = true; syncError = nil
        defer { syncing = false }
        do { try await syncAccount.disconnect() }
        catch { syncError = "Disconnected locally, but server revocation could not be confirmed. The old grant may remain active until expiry." }
        syncConnected = (try? await syncAccount.connected()) == true
    }
}

struct HabibiSyncView: View {
    @ObservedObject var session: HabibiSession
    @State private var resolution: HabibiSyncResolution?
    @State private var confirm = false
    @State private var disconnect = false

    var body: some View {
        List {
            Section {
                Label(session.syncConnected ? "Connected" : "Not connected", systemImage: session.syncConnected ? "checkmark.shield" : "lock.icloud")
                    .accessibilityIdentifier("habibi.sync.connection")
                Text(session.syncAccount.origin.value).font(.footnote).foregroundStyle(.secondary)
                Text("Your device encrypts your profile, Kits and conversations before upload. The server receives ciphertext, opaque IDs and storage metadata, never your content key.")
            }
            Section {
                if session.syncConnected {
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { Task { await session.synchronize() } }
                        .accessibilityIdentifier("habibi.sync.now")
                    if let status = session.syncStatus {
                        Text(status.conflict ? "Changes need your review" : status.pending != nil ? "Encrypted upload pending" : status.dirty ? "Local changes not synced" : "This device is up to date")
                            .foregroundStyle(.secondary).accessibilityIdentifier("habibi.sync.status")
                    }
                    if let date = session.lastSynced { LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Button("Disconnect", role: .destructive) { disconnect = true }
                } else {
                    Button("Connect encrypted sync", systemImage: "person.badge.key") { Task { await session.connectSync() } }
                        .accessibilityIdentifier("habibi.sync.connect")
                    Text("Sign in with a passkey in your system browser. Signing in does not recover your encryption key.").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Sync is manual in this version. Tap Sync now after changes or when moving between devices. Keep a separate recovery backup and key.").font(.footnote).foregroundStyle(.secondary)
            }
            if let status = session.syncStatus, status.conflict {
                Section("Choose a version") {
                    Text("Devices changed independently. Nothing will be silently overwritten. Save a recovery backup first; the version you choose replaces this device’s profile, Kits and conversations. Older encrypted branches remain on the server.")
                    Button("Keep this device’s version") { resolution = .init(remoteID: nil, expectedHeads: status.heads.map(\.id)); confirm = true }
                    ForEach(status.heads) { head in
                        Button("Use version \(head.id.prefix(8))") { resolution = .init(remoteID: head.id, expectedHeads: status.heads.map(\.id)); confirm = true }
                    }
                }
            }
            if let error = session.syncError { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("habibi.sync.error") } }
            if session.syncing { Section { ProgressView("Connecting securely…") } }
            Section("Another device") {
                Text("Restore the encrypted recovery backup and its separate key on the other device, connect to the same server, then sync. A passkey account alone cannot decrypt or discover your vault.")
            }
        }
        .navigationTitle("Encrypted sync").navigationBarTitleDisplayMode(.inline)
        .disabled(session.syncing || session.chatRunning || session.review != nil || session.busy)
        .task { await session.refreshSyncStatus() }
        .alert("Choose this version?", isPresented: $confirm) {
            Button("Use this version", role: .destructive) { if let resolution { Task { await session.synchronize(resolution: resolution) } } }
            Button("Cancel", role: .cancel) { resolution = nil }
        } message: { Text("This replaces this device’s current data with the chosen version and publishes an encrypted resolution. It does not merge conflicting edits. Keep your recovery backup.") }
        .confirmationDialog("Disconnect encrypted sync?", isPresented: $disconnect) {
            Button("Disconnect", role: .destructive) { Task { await session.disconnectSync() } }
        } message: { Text("Revoke this sign-in and remove its local credentials. Your vault, recovery key and encrypted server records are not deleted.") }
    }
}
