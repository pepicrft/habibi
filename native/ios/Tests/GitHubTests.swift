import Foundation
import Testing

private struct GitHubReply: Sendable {
    let data: Data
    var status = 200
    var url: URL?
    var contentType = "application/json"

    init(_ value: [String: Any], status: Int = 200) throws {
        data = try JSONSerialization.data(withJSONObject: value)
        self.status = status
    }
    init(_ value: [[String: Any]]) throws { data = try JSONSerialization.data(withJSONObject: value) }
    init(data: Data) { self.data = data }
}

// Only transport and time are fake. Session tests use the real encrypted store
// and Rust host bridge, never credentials supplied to a model or guest Kit.
private actor GitHubHTTP: HabibiSyncHTTP {
    private var replies: [GitHubReply]
    private var requests: [URLRequest] = []
    private let heldPath: String?
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ replies: [GitHubReply], heldPath: String? = nil) { self.replies = replies; self.heldPath = heldPath }
    func captured() -> [URLRequest] { requests }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }

    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        #expect(limit == (request.url?.path == "/user/repos" ? 256 : 32) * 1024)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.timeoutInterval == 20)
        let reply = try #require(replies.first)
        replies.removeFirst()
        if request.url?.path == heldPath {
            // Intentionally ignore cancellation to model a late completion.
            await withCheckedContinuation { continuation = $0 }
        }
        return (reply.data, HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": reply.contentType])!)
    }
}

@MainActor
private final class GitHubClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var waits: [Int] = []
    func sleep(_ seconds: Int) async throws { try Task.checkCancellation(); waits.append(seconds); date.addTimeInterval(Double(seconds)) }
    func client(_ http: GitHubHTTP) -> HabibiGitHub { HabibiGitHub(http: http, now: { self.date }, sleep: { try await self.sleep($0) }) }
}

private var githubDevice: [String: Any] {
    ["device_code": String(repeating: "a", count: 40), "user_code": "ABCD-EFGH",
     "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5]
}
private var githubToken: [String: Any] {
    ["access_token": "gho_fictional-private-token", "token_type": "bearer", "scope": "read:user",
     "expires_in": 3600, "refresh_token": "ghr_must-never-be-stored", "refresh_token_expires_in": 15897600]
}
private var githubUser: [String: Any] { ["login": "noor-dev", "id": 42, "name": "Read-only profile name"] }
private var githubDescriptor: [String: Any] {
    ["url": "https://api.github.com/user", "method": "GET", "headers": ["Authorization": "Bearer gho_fictional-private-token",
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]]
}

private func githubCatalog(_ clientID: String = "publisher-client") -> [HabibiBundledKit] {
    [HabibiBundledKit(id: "github", name: "GitHub", description: "Read-only GitHub tools",
                     permissions: ["read:user"], authentication: "device_code", clientId: clientID)]
}

private let githubRepositoriesURL = "https://api.github.com/user/repos?visibility=public&affiliation=owner&sort=updated&per_page=10"
private var githubToolProfile: [String: Any] {
    var profile = githubUser
    profile["bio"] = "I build things"
    profile["public_repos"] = 7
    profile["followers"] = 19
    profile["email"] = "PRIVATE-EMAIL"
    profile["access_token"] = "RAW-BODY-SECRET"
    return profile
}
private var githubRepositories: [[String: Any]] {
    [["name": "garden", "full_name": "noor-dev/garden", "private": false, "description": "Plants",
      "language": "Swift", "stargazers_count": 7, "permissions": ["admin": true], "token": "RAW-BODY-SECRET"]]
}

@MainActor
private func saveGitHubFixture(_ session: HabibiSession) async throws {
    _ = try await session.persist("connect_kit", arguments: ["connection": [
        "kitId": "github", "clientId": "legacy-client", "account": "noor-dev",
        "accessToken": "gho_fictional-private-token", "scope": "read:user"]])
}

@MainActor
@Test func githubDeviceFlowWaitsBacksOffAndRevalidatesBeforeReturningMinimalCredentials() async throws {
    let clock = GitHubClock()
    let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(["error": "authorization_pending"]),
        GitHubReply(["error": "slow_down"]), GitHubReply(["error": "slow_down", "interval": 22], status: 400),
        GitHubReply(["error": "authorization_pending", "interval": 1]), GitHubReply(githubToken), GitHubReply(githubUser)])
    var codes: [String] = []
    let connection = try await clock.client(http).authorize(clientID: "Ov23.public-client") { code, deadline in
        codes.append(code)
        #expect(deadline == Date(timeIntervalSince1970: 1_800_000_900))
    }
    #expect(codes == ["ABCD-EFGH"])
    #expect(clock.waits == [5, 5, 10, 22, 22])
    #expect(connection.account == "noor-dev")
    #expect(connection.vaultValue["expiresAt"] as? Int64 == 1_800_003_664)
    #expect(Set(connection.vaultValue.keys) == Set(["kitId", "clientId", "account", "accessToken", "scope", "expiresAt"]))
    let requests = await http.captured()
    #expect(requests.count == 7)
    #expect(requests[0].url?.absoluteString == "https://github.com/login/device/code")
    #expect(String(decoding: requests[0].httpBody!, as: UTF8.self) == "client_id=Ov23.public-client&scope=read%3Auser")
    for request in requests.dropLast() {
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!body.contains("client_secret") && !body.contains("refresh_token") && !body.contains("offline_access"))
    }
    for request in requests.dropFirst().dropLast() {
        #expect(request.url?.absoluteString == "https://github.com/login/oauth/access_token")
        #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }
    #expect(requests.last?.url?.absoluteString == "https://api.github.com/user")
    #expect(requests.last?.httpMethod == "GET")
    #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer gho_fictional-private-token")
    #expect(requests.last?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

@MainActor
@Test func githubDenialExpiryAndDisabledFlowStopWithoutAnIdentityRequest() async throws {
    for error in ["access_denied", "expired_token", "token_expired", "device_flow_disabled", "incorrect_client_credentials"] {
        let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(["error": error, "error_description": "secret-response-must-not-be-displayed"], status: 400)])
        let clock = GitHubClock()
        do {
            _ = try await clock.client(http).authorize(clientID: "public-client") { _, _ in }
            Issue.record("Authorization unexpectedly succeeded")
        } catch { #expect(!error.localizedDescription.contains("secret-response-must-not-be-displayed")) }
        #expect(await http.captured().count == 2)
    }
    var device = githubDevice; device["expires_in"] = 5
    let http = GitHubHTTP(try [GitHubReply(device)])
    let clock = GitHubClock()
    await #expect(throws: (any Error).self) { _ = try await clock.client(http).authorize(clientID: "public-client") { _, _ in } }
    #expect(await http.captured().count == 1)
    #expect(clock.waits == [5])
}

@MainActor
@Test func githubDeviceResponseMustHaveFixedURIValidCodesAndStrictIntegerLifetimes() async throws {
    let changes: [(String, Any)] = [
        ("verification_uri", "https://evil.example/login/device"), ("verification_uri", "https://github.com/login/device?code=x"),
        ("device_code", String(repeating: "z", count: 40)), ("device_code", "short"), ("user_code", "abcd-efgh"),
        ("user_code", "ABCD\nEFGH"), ("expires_in", 0), ("expires_in", 901), ("expires_in", true),
        ("interval", 0), ("interval", 2.5), ("interval", "5"), ("interval", true)
    ]
    for (key, value) in changes {
        var device = githubDevice; device[key] = value
        let http = GitHubHTTP(try [GitHubReply(device)])
        let clock = GitHubClock()
        await #expect(throws: (any Error).self) {
            _ = try await clock.client(http).authorize(clientID: "public-client") { _, _ in Issue.record("Unsafe code shown") }
        }
        #expect(await http.captured().count == 1)
    }
}

@MainActor
@Test func githubRejectsBroadScopesMalformedBearerExpiryAndUnvalidatedIdentity() async throws {
    let changes: [(String, Any)] = [("scope", "repo"), ("scope", "user"), ("scope", "read:user,repo"),
        ("scope", "read:user "), ("token_type", "basic"), ("access_token", "token\r\ninjected: header"),
        ("expires_in", true), ("expires_in", 0), ("expires_in", 3.5)]
    for (key, value) in changes {
        var token = githubToken; token[key] = value
        let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(token)])
        let clock = GitHubClock()
        await #expect(throws: (any Error).self) { _ = try await clock.client(http).authorize(clientID: "public-client") { _, _ in } }
        #expect(await http.captured().count == 2)
    }
    for user in [["login": "injected\naccount", "id": 42] as [String: Any], ["login": "noor-dev", "id": true]] {
        let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(githubToken), GitHubReply(user)])
        let clock = GitHubClock()
        await #expect(throws: (any Error).self) { _ = try await clock.client(http).authorize(clientID: "public-client") { _, _ in } }
    }
    var minimal = githubToken; minimal["scope"] = ""; minimal.removeValue(forKey: "expires_in")
    let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(minimal), GitHubReply(githubUser)])
    let clock = GitHubClock()
    let connection = try await clock.client(http).authorize(clientID: "public-client") { _, _ in }
    #expect(connection.vaultValue["scope"] as? String == "")
    #expect(connection.vaultValue["expiresAt"] == nil)
    #expect(connection.vaultValue["refreshToken"] == nil && connection.vaultValue["refresh_token"] == nil)
}

@MainActor
@Test func githubTransportRejectsRedirectsChangedURLsWrongMIMEOversizedAndMalformedResponses() async throws {
    var redirect = try GitHubReply(githubDevice); redirect.status = 302
    var changedURL = try GitHubReply(githubDevice); changedURL.url = URL(string: "https://evil.example/code")
    var wrongMIME = try GitHubReply(githubDevice); wrongMIME.contentType = "text/html"
    let huge = GitHubReply(data: Data(repeating: 32, count: 32 * 1024 + 1))
    let malformed = GitHubReply(data: Data("not JSON secret-response".utf8))
    for reply in [redirect, changedURL, wrongMIME, huge, malformed] {
        let http = GitHubHTTP([reply]); let clock = GitHubClock()
        await #expect(throws: (any Error).self) {
            _ = try await clock.client(http).authorize(clientID: "public-client") { _, _ in Issue.record("Unsafe response shown") }
        }
        #expect(await http.captured().count == 1)
    }
}

@MainActor
@Test func githubNativeCheckCannotBeRedirectedIntoArbitraryAuthenticatedHTTP() async throws {
    let http = GitHubHTTP(try [GitHubReply(githubUser)])
    let github = GitHubClock().client(http)
    for (key, value) in [("url", "https://evil.example/user"), ("url", "https://api.github.com/user?extra=1"),
                         ("url", "http://api.github.com/user"), ("method", "POST")] {
        var descriptor = githubDescriptor; descriptor[key] = value
        await #expect(throws: (any Error).self) { _ = try await github.checkConnection(descriptor) }
    }
    var descriptor = githubDescriptor
    var headers = descriptor["headers"] as! [String: String]; headers["X-Extra"] = "forbidden"; descriptor["headers"] = headers
    await #expect(throws: (any Error).self) { _ = try await github.checkConnection(descriptor) }
    #expect(await http.captured().isEmpty)
    #expect(try await github.checkConnection(githubDescriptor) == "noor-dev")
    #expect(await http.captured().count == 1)
}

private func waitForGitHubResponse(_ http: GitHubHTTP) async throws {
    for _ in 0..<500 {
        if await http.waiting() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await http.waiting(), "Expected a held HTTP response within five seconds")
}

@MainActor
@Test func githubCanceledTokenOrIdentityCompletionCannotReturnCredentials() async throws {
    for path in ["/login/oauth/access_token", "/user"] {
        let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(githubToken), GitHubReply(githubUser)], heldPath: path)
        let github = GitHubClock().client(http)
        let task = Task { try await github.authorize(clientID: "public-client") { _, _ in } }
        try await waitForGitHubResponse(http)
        task.cancel()
        await http.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await http.captured().count == (path == "/user" ? 3 : 2))
    }
}

@MainActor
@Test func githubScreenCancellationDiscardsLateIdentityAndLocksChatReviewAndSyncMutations() async throws {
    let storage = MemoryPersistence()
    let session = HabibiSession(store: HabibiStore(persistence: storage), bundledKits: { githubCatalog() })
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    let original = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(githubToken), GitHubReply(githubUser)])
    try await session.connectGitHub(using: GitHubClock().client(original)) { _, _ in }
    let before = storage.document
    var replacement = githubToken; replacement["access_token"] = "gho_canceled-replacement-token"
    let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(replacement), GitHubReply(["login": "other-account", "id": 43])], heldPath: "/user")
    let connector = HabibiGitHubConnector(github: GitHubClock().client(http))
    connector.perform(.connect, session: session)
    try await waitForGitHubResponse(http)
    #expect(session.busy)
    let conversation = session.activeConversationID
    session.newConversation(prompt: "Must not start during OAuth")
    #expect(session.activeConversationID == conversation)
    await #expect(throws: (any Error).self) { _ = try await session.executeTool("list_kits", arguments: [:]) }
    await #expect(throws: (any Error).self) { _ = try await session.persist("profile", arguments: [:]) }
    await session.synchronize()
    #expect(!session.syncing && session.lastSynced == nil)
    connector.cancel()
    #expect(connector.userCode == nil && connector.activity == nil)
    await http.release()
    for _ in 0..<500 {
        if !session.busy { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.busy)
    #expect(storage.document == before)
    #expect(session.snapshot?.connections?.first?.account == "noor-dev")
    let saved = try await session.store.call("connection_request", arguments: ["id": "github"])
    #expect((saved["headers"] as? [String: String])?["Authorization"] == "Bearer gho_fictional-private-token")
    #expect(connector.checkedLogin == nil && connector.error == nil)
    session.review = HabibiReview(payload: ["operation": "remove_kit"])
    await #expect(throws: (any Error).self) { try await session.connectGitHub(using: GitHubClock().client(http)) { _, _ in } }
    session.review = nil
}

@MainActor
@Test func githubFailedReconnectSavePreservesExistingUnexpiredConnectionOnDiskAndInMemory() async throws {
    let storage = MemoryPersistence()
    let store = HabibiStore(persistence: storage)
    let session = HabibiSession(store: store, bundledKits: { githubCatalog() })
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    var permanentToken = githubToken; permanentToken.removeValue(forKey: "expires_in")
    let original = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(permanentToken), GitHubReply(githubUser)])
    try await session.connectGitHub(using: GitHubClock().client(original)) { _, _ in }
    #expect(session.snapshot?.connections?.first?.expired == false)
    let before = storage.document
    var replacement = githubToken; replacement["access_token"] = "gho_unsaved-replacement-token"
    let reconnect = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(replacement), GitHubReply(["login": "other-account", "id": 43])])
    storage.rejectWrites = true
    await #expect(throws: (any Error).self) {
        try await session.connectGitHub(using: GitHubClock().client(reconnect)) { _, _ in }
    }
    #expect(await reconnect.captured().count == 3)
    #expect(storage.document == before)
    #expect(!session.busy)
    #expect(session.snapshot?.connections?.first?.account == "noor-dev")
    let saved = try await store.call("connection_request", arguments: ["id": "github"])
    #expect((saved["headers"] as? [String: String])?["Authorization"] == "Bearer gho_fictional-private-token")
    storage.rejectWrites = false
    #expect(try await HabibiStore(persistence: storage).restore()?.connections?.first?.account == "noor-dev")
}

@MainActor
@Test func githubAutomaticIdentityAndManualCheckStayPrivateUntilAnExplicitToolCall() async throws {
    let storage = MemoryPersistence()
    let store = HabibiStore(persistence: storage)
    let session = HabibiSession(store: store, bundledKits: { githubCatalog() })
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    session.newConversation(prompt: "Keep this draft")
    let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(githubToken), GitHubReply(githubUser), GitHubReply(githubUser)])
    let github = GitHubClock().client(http)
    try await session.connectGitHub(using: github) { _, _ in }
    #expect(session.snapshot?.connections?.first?.account == "noor-dev")
    #expect(try await session.checkGitHub(using: github) == "noor-dev")
    let archive = String(decoding: try JSONEncoder().encode(session.conversations), as: UTF8.self)
    let encrypted = String(decoding: try #require(storage.document), as: UTF8.self)
    for sensitive in ["gho_fictional-private-token", "ghr_must-never-be-stored", "noor-dev", "Read-only profile name"] {
        #expect(!archive.contains(sensitive))
        #expect(!encrypted.contains(sensitive))
    }
    let restarted = HabibiStore(persistence: storage)
    #expect(try await restarted.restore()?.connections?.first?.account == "noor-dev")
    let descriptor = try await restarted.call("connection_request", arguments: ["id": "github"])
    #expect((descriptor["headers"] as? [String: String])?["Authorization"] == "Bearer gho_fictional-private-token")
    try await session.disconnectGitHub()
    #expect(session.snapshot?.connections?.isEmpty != false)
    await #expect(throws: (any Error).self) { _ = try await store.call("connection_request", arguments: ["id": "github"]) }
}

private final class GitHubStoreActorGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func block() { entered.signal(); _ = resume.wait(timeout: .now() + 5) }
}

private extension HabibiStore {
    // Occupy the real store actor, so cancellation happens after the caller's
    // checks but before its queued connect_kit call enters the durable gate.
    func holdForGitHubCancellationTest(_ gate: GitHubStoreActorGate) { gate.block() }
}

@Test func githubCanceledQueuedStoreCommitPreservesConnectionButOtherDurableWritesRemainNoncancellable() async throws {
    let storage = MemoryPersistence()
    let store = HabibiStore(persistence: storage)
    _ = try await store.create(profile: .init(name: "Noor", goals: ["learning"], style: "warm"))
    let original = ["kitId": "github", "clientId": "public-client", "account": "noor-dev",
                    "accessToken": "gho_fictional-private-token", "scope": "read:user"]
    _ = try await store.call("connect_kit", arguments: ["connection": original], persist: true)
    let before = storage.document
    let gate = GitHubStoreActorGate()
    let holder = Task.detached { await store.holdForGitHubCancellationTest(gate) }
    defer { gate.resume.signal() }
    let entered = await Task.detached { gate.entered.wait(timeout: .now() + 5) == .success }.value
    try #require(entered)
    let attempting = DispatchSemaphore(value: 0)
    let commit = Task.detached {
        attempting.signal()
        var replacement = original; replacement["account"] = "other-account"; replacement["accessToken"] = "gho_canceled-queued-token"
        _ = try await store.call("connect_kit", arguments: ["connection": replacement], persist: true)
    }
    let started = await Task.detached { attempting.wait(timeout: .now() + 5) == .success }.value
    try #require(started)
    commit.cancel()
    gate.resume.signal()
    await holder.value
    await #expect(throws: CancellationError.self) { try await commit.value }
    #expect(storage.document == before)
    let saved = try await store.call("connection_request", arguments: ["id": "github"])
    #expect((saved["headers"] as? [String: String])?["Authorization"] == "Bearer gho_fictional-private-token")
    #expect(try await HabibiStore(persistence: storage).restore()?.connections?.first?.account == "noor-dev")

    let ordinaryWrite = Task {
        _ = try await store.call("profile", arguments: ["profile": ["name": "Still saved", "goals": ["learning"], "style": "warm"]], persist: true)
    }
    ordinaryWrite.cancel()
    try await ordinaryWrite.value
    #expect(try await store.restore()?.profile.name == "Still saved")
}

@MainActor
@Test func githubPublisherCatalogControlsConnectWithoutUserConfigurationOrLegacyClientFallback() async throws {
    let bundled = try HabibiBundledKit.catalog()
    #expect(bundled.contains { $0.id == "github" })
    for clientID in ["", "invalid client", "https://evil.example"] {
        let kit = try #require(githubCatalog(clientID).first)
        #expect(!kit.githubConfigured)
        let session = HabibiSession(store: HabibiStore(persistence: MemoryPersistence()), bundledKits: { githubCatalog(clientID) })
        #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
        try await saveGitHubFixture(session)
        let http = GitHubHTTP([])
        do {
            try await session.connectGitHub(using: GitHubClock().client(http)) { _, _ in Issue.record("Unconfigured build showed a code") }
            Issue.record("Unconfigured build connected GitHub")
        } catch { #expect(error.localizedDescription == HabibiBundledKit.githubUnavailable) }
        #expect(await http.captured().isEmpty)
        #expect(!session.busy)
        #expect(session.snapshot?.connections?.first?.clientId == "legacy-client")
    }
    #expect(try #require(githubCatalog().first).githubConfigured)
    let session = HabibiSession(store: HabibiStore(persistence: MemoryPersistence()), bundledKits: { githubCatalog("publisher-app") })
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    try await saveGitHubFixture(session)
    let http = GitHubHTTP(try [GitHubReply(githubDevice), GitHubReply(githubToken), GitHubReply(githubUser)])
    try await session.connectGitHub(using: GitHubClock().client(http)) { _, _ in }
    let requests = await http.captured()
    #expect(requests.count == 3)
    for request in requests.prefix(2) {
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("client_id=publisher-app"))
        #expect(!body.contains("legacy-client") && !body.contains("client_secret"))
    }
    #expect(session.snapshot?.connections?.first?.clientId == "publisher-app")
}

@MainActor
@Test func githubToolDescriptorsAllowOnlyTheTwoExactGETsAndHeaders() async throws {
    let http = GitHubHTTP(try [GitHubReply(githubToolProfile), GitHubReply(githubRepositories)])
    let github = GitHubClock().client(http)
    for (name, url) in [("github_get_profile", "https://api.github.com/user"), ("github_list_repositories", githubRepositoriesURL)] {
        var descriptor = githubDescriptor; descriptor["url"] = url
        for (key, value) in [("url", "https://evil.example/user"), ("url", url + "&extra=1"),
                             ("method", "POST"), ("body", "injected")] {
            var changed = descriptor; changed[key] = value
            await #expect(throws: (any Error).self) { _ = try await github.fetchTool(name, descriptor: changed) }
        }
        for (key, value) in [("Accept", "application/json"), ("X-GitHub-Api-Version", "2020-01-01"),
                             ("Authorization", "Bearer secret\r\nInjected: header"), ("Extra", "forbidden")] {
            var changed = descriptor
            var headers = descriptor["headers"] as! [String: String]; headers[key] = value; changed["headers"] = headers
            await #expect(throws: (any Error).self) { _ = try await github.fetchTool(name, descriptor: changed) }
        }
    }
    var repositories = githubDescriptor; repositories["url"] = githubRepositoriesURL
    await #expect(throws: (any Error).self) { _ = try await github.fetchTool("github_get_profile", descriptor: repositories) }
    await #expect(throws: (any Error).self) { _ = try await github.fetchTool("github_list_repositories", descriptor: githubDescriptor) }
    await #expect(throws: (any Error).self) { _ = try await github.fetchTool("connect_kit", descriptor: githubDescriptor) }
    #expect(await http.captured().isEmpty)
    _ = try await github.fetchTool("github_get_profile", descriptor: githubDescriptor)
    _ = try await github.fetchTool("github_list_repositories", descriptor: repositories)
    let requests = await http.captured()
    #expect(requests.map { $0.url!.absoluteString } == ["https://api.github.com/user", githubRepositoriesURL])
    for request in requests {
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gho_fictional-private-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }
}

@MainActor
@Test func githubToolsRejectOversizedWrongShapeAndUnsafeTransportWithoutRawErrors() async throws {
    for (name, limit) in [("github_get_profile", 32 * 1024), ("github_list_repositories", 256 * 1024)] {
        var descriptor = githubDescriptor
        if name == "github_list_repositories" { descriptor["url"] = githubRepositoriesURL }
        var redirect = try GitHubReply(githubToolProfile); redirect.status = 302
        var changedURL = try GitHubReply(githubToolProfile); changedURL.url = URL(string: "https://evil.example/user")
        var wrongMIME = try GitHubReply(githubToolProfile); wrongMIME.contentType = "text/html"
        let wrongShape = name == "github_get_profile" ? try GitHubReply([] as [[String: Any]]) : try GitHubReply(githubToolProfile)
        for reply in [GitHubReply(data: Data(repeating: 32, count: limit + 1)), wrongShape, redirect, changedURL, wrongMIME,
                      try GitHubReply(["message": "RAW-BODY-SECRET"], status: 401), GitHubReply(data: Data("RAW-BODY-SECRET".utf8))] {
            let http = GitHubHTTP([reply]); let github = GitHubClock().client(http)
            do {
                _ = try await github.fetchTool(name, descriptor: descriptor)
                Issue.record("Unsafe tool response accepted")
            } catch { #expect(!error.localizedDescription.contains("RAW-BODY-SECRET")) }
            #expect(await http.captured().count == 1)
        }
    }
}

@MainActor
@Test func githubAgentConnectionAdvertisementContainsOnlyUnexpiredSupportedIDs() throws {
    let session = HabibiSession()
    let profile = HabibiProfile(name: "Noor", goals: ["learning"], style: "warm")
    for (connection, expected) in [
        (HabibiConnectionSummary(kitId: "github", clientId: "private-client", account: "PRIVATE-ACCOUNT", expiresAt: nil), ["github"]),
        (.init(kitId: "github", clientId: "private-client", account: "PRIVATE-ACCOUNT", expiresAt: 1), []),
        (.init(kitId: "github", clientId: "private-client", account: "PRIVATE-ACCOUNT", expiresAt: Int64(Date().timeIntervalSince1970) + 3600), ["github"]),
        (.init(kitId: "unsupported", clientId: "private-client", account: "PRIVATE-ACCOUNT", expiresAt: nil), [])
    ] {
        session.snapshot = .init(version: 1, profile: profile, kits: [], conversations: nil, connections: [connection], drafts: nil, costumes: nil)
        #expect(session.agentConnections == expected)
        let prepared = try HabibiCore.execute(["operation": "agent_request", "history": [["role": "user", "content": "Hi"]],
                                               "today": habibiDay(), "connections": session.agentConnections])
        let body = try #require(prepared["body"] as? [String: Any])
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.contains { $0["name"] as? String == "github_get_profile" } == !expected.isEmpty)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE-ACCOUNT") && !encoded.contains("private-client"))
    }
    session.snapshot = nil
    #expect(session.agentConnections.isEmpty)
}

@MainActor
@Test func githubSessionExecutesBothToolsThroughTheCoreSanitizerWithoutChangingTheVault() async throws {
    let storage = MemoryPersistence()
    var privateRepository = githubRepositories[0]; privateRepository["private"] = true
    let http = GitHubHTTP(try [GitHubReply(githubToolProfile), GitHubReply(githubRepositories), GitHubReply([privateRepository])])
    let session = HabibiSession(store: HabibiStore(persistence: storage), github: GitHubClock().client(http))
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    try await saveGitHubFixture(session)
    let before = storage.document
    await #expect(throws: (any Error).self) { _ = try await session.executeTool("github_get_profile", arguments: ["url": "https://evil.example"]) }
    #expect(await http.captured().isEmpty)
    let profile = try #require(try await session.executeTool("github_get_profile", arguments: [:]) as? [String: Any])
    #expect(profile["login"] as? String == "noor-dev")
    #expect(Set(profile.keys) == Set(["login", "name", "bio", "publicRepositories", "followers"]))
    let repositories = try #require(try await session.executeTool("github_list_repositories", arguments: [:]) as? [String: Any])
    let repository = try #require((repositories["repositories"] as? [[String: Any]])?.first)
    #expect(repository["fullName"] as? String == "noor-dev/garden")
    #expect(repository["stars"] as? Int == 7)
    #expect(Set(repository.keys) == Set(["name", "fullName", "description", "language", "stars"]))
    let output = String(decoding: try JSONSerialization.data(withJSONObject: [profile, repositories]), as: UTF8.self)
    for sensitive in ["RAW-BODY-SECRET", "PRIVATE-EMAIL", "gho_fictional-private-token", "Authorization", "permissions", "api.github.com"] {
        #expect(!output.contains(sensitive))
    }
    do {
        _ = try await session.executeTool("github_list_repositories", arguments: [:])
        Issue.record("Private repository response was accepted")
    } catch {
        #expect(error.localizedDescription.contains("Check the connection in Kits"))
        #expect(!error.localizedDescription.contains("RAW-BODY-SECRET") && !error.localizedDescription.contains("garden"))
    }
    #expect(storage.document == before)
    #expect(session.messages.isEmpty && session.conversations.isEmpty)
    try await session.disconnectGitHub()
    await #expect(throws: (any Error).self) { _ = try await session.executeTool("github_get_profile", arguments: [:]) }
    #expect(await http.captured().count == 3)
}

@MainActor
@Test func githubMinimalToolResponsesUseTheRealFFIProjectionForOptionalFields() async throws {
    let http = GitHubHTTP(try [
        GitHubReply(["login": "noor-dev", "public_repos": 7, "followers": 19]),
        GitHubReply([["name": "garden", "full_name": "noor-dev/garden", "private": false, "stargazers_count": 7]])
    ])
    let session = HabibiSession(store: HabibiStore(persistence: MemoryPersistence()), github: GitHubClock().client(http))
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    try await saveGitHubFixture(session)
    let profile = try #require(try await session.executeTool("github_get_profile", arguments: [:]) as? [String: Any])
    #expect(Set(profile.keys) == Set(["login", "name", "bio", "publicRepositories", "followers"]))
    #expect(profile["login"] as? String == "noor-dev")
    #expect(profile["publicRepositories"] as? Int == 7 && profile["followers"] as? Int == 19)
    #expect(profile["name"] is NSNull && profile["bio"] is NSNull)
    let result = try #require(try await session.executeTool("github_list_repositories", arguments: [:]) as? [String: Any])
    #expect(result["limit"] as? Int == 10)
    let repository = try #require((result["repositories"] as? [[String: Any]])?.first)
    #expect(Set(repository.keys) == Set(["name", "fullName", "description", "language", "stars"]))
    #expect(repository["fullName"] as? String == "noor-dev/garden")
    #expect(repository["stars"] as? Int == 7)
    #expect(repository["description"] is NSNull && repository["language"] is NSNull)
}

@MainActor
@Test func githubDisconnectedAndExpiredToolsAreBlockedBeforeTransportAndRemainRecoverable() async throws {
    let storage = MemoryPersistence()
    let http = GitHubHTTP([])
    let github = GitHubClock().client(http)
    let session = HabibiSession(store: HabibiStore(persistence: storage), github: github)
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    #expect(session.agentConnections.isEmpty)
    for name in ["github_get_profile", "github_list_repositories"] {
        await #expect(throws: (any Error).self) { _ = try await session.executeTool(name, arguments: [:]) }
    }
    #expect(await http.captured().isEmpty)
    // Let an honestly saved, encrypted connection expire. Do not simulate expiry
    // only in the display summary: the Rust host must reject its own credentials.
    let expiry = Int64(Date().timeIntervalSince1970.rounded(.up)) + 3
    _ = try await session.persist("connect_kit", arguments: ["connection": [
        "kitId": "github", "clientId": "legacy-client", "account": "noor-dev", "accessToken": "gho_fictional-private-token",
        "scope": "read:user", "expiresAt": expiry]])
    let before = storage.document
    try await Task.sleep(for: .seconds(max(0, Double(expiry) - Date().timeIntervalSince1970) + 0.05))
    #expect(session.snapshot?.connections?.first?.expired == true)
    #expect(session.agentConnections.isEmpty)
    for name in ["github_get_profile", "github_list_repositories"] {
        await #expect(throws: (any Error).self) { _ = try await session.executeTool(name, arguments: [:]) }
    }
    await #expect(throws: (any Error).self) { _ = try await session.checkGitHub(using: github) }
    #expect(await http.captured().isEmpty)
    #expect(storage.document == before)
    let restored = HabibiSession(store: HabibiStore(persistence: storage), github: github)
    await restored.start()
    #expect(restored.snapshot?.connections?.first?.expired == true)
    #expect(restored.snapshot?.connections?.first?.account == "noor-dev")
    #expect(restored.agentConnections.isEmpty)
    await #expect(throws: (any Error).self) { _ = try await restored.executeTool("github_get_profile", arguments: [:]) }
    try await restored.disconnectGitHub()
    #expect(restored.agentConnections.isEmpty)
    #expect(restored.snapshot?.connections?.isEmpty != false)
    #expect(await http.captured().isEmpty)
}

@MainActor
@Test func githubRevokedResponsesReturnNoDataAndNeverRefreshOrRetry() async throws {
    let storage = MemoryPersistence()
    let rejected = try GitHubReply(["message": "RAW-BODY-SECRET", "access_token": "gho_fictional-private-token"], status: 401)
    let http = GitHubHTTP([rejected, rejected, rejected])
    let github = GitHubClock().client(http)
    let session = HabibiSession(store: HabibiStore(persistence: storage), github: github)
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    try await saveGitHubFixture(session)
    let before = storage.document
    for name in ["github_get_profile", "github_list_repositories"] {
        do {
            _ = try await session.executeTool(name, arguments: [:])
            Issue.record("Revoked credentials returned a tool result")
        } catch {
            #expect(error.localizedDescription.contains("reconnect"))
            #expect(!error.localizedDescription.contains("RAW-BODY-SECRET") && !error.localizedDescription.contains("gho_fictional-private-token"))
        }
    }
    do {
        _ = try await session.checkGitHub(using: github)
        Issue.record("Revoked credentials passed the native connection check")
    } catch {
        #expect(error.localizedDescription.contains("revoked") && error.localizedDescription.contains("Reconnect"))
        #expect(!error.localizedDescription.contains("RAW-BODY-SECRET"))
    }
    #expect(storage.document == before)
    #expect(session.conversations.isEmpty)
    let requests = await http.captured()
    #expect(requests.map { $0.url!.absoluteString } == ["https://api.github.com/user", githubRepositoriesURL, "https://api.github.com/user"])
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
}

@MainActor
@Test func githubCanceledToolFetchCannotReturnLateDataAndDoesNotWrite() async throws {
    for (name, path) in [("github_get_profile", "/user"), ("github_list_repositories", "/user/repos")] {
        let storage = MemoryPersistence()
        let reply = name == "github_get_profile" ? try GitHubReply(githubToolProfile) : try GitHubReply(githubRepositories)
        let http = GitHubHTTP([reply], heldPath: path)
        let session = HabibiSession(store: HabibiStore(persistence: storage), github: GitHubClock().client(http))
        #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
        try await saveGitHubFixture(session)
        let before = storage.document
        let task = Task { try await session.executeTool(name, arguments: [:]) }
        try await waitForGitHubResponse(http)
        task.cancel()
        await http.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(storage.document == before)
        let canceledBeforeFetch = Task { try await session.executeTool(name, arguments: [:]) }
        canceledBeforeFetch.cancel()
        await #expect(throws: CancellationError.self) { _ = try await canceledBeforeFetch.value }
        #expect(await http.captured().count == 1)
    }
}

private actor GitHubInferenceHTTP: HabibiSyncHTTP {
    private var replies: [GitHubReply]
    private var requests: [URLRequest] = []
    init(_ replies: [GitHubReply]) { self.replies = replies }
    func captured() -> [URLRequest] { requests }
    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        #expect(limit == 128 * 1024)
        requests.append(request)
        let reply = try #require(replies.first)
        replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                          headerFields: ["Content-Type": "application/json"])!)
    }
}

@MainActor
@Test func githubConversationLoopSharesOnlySanitizedExplicitToolResultsAndArchivesThemEncrypted() async throws {
    let storage = MemoryPersistence()
    let github = GitHubHTTP(try [GitHubReply(githubToolProfile), GitHubReply(githubRepositories)])
    let inference = GitHubInferenceHTTP(try [
        GitHubReply(["status": "completed", "output": [["type": "function_call", "call_id": "profile-call", "name": "github_get_profile", "arguments": "{}"]]]),
        GitHubReply(["status": "completed", "output": [["type": "function_call", "call_id": "repos-call", "name": "github_list_repositories", "arguments": "{}"]]]),
        GitHubReply(["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Finished reading GitHub."]]]]])
    ])
    let session = HabibiSession(store: HabibiStore(persistence: storage), github: GitHubClock().client(github),
                                inferenceURL: URL(string: "https://inference.example/inference")!, inferenceHTTP: inference)
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    try await saveGitHubFixture(session)
    session.newConversation(prompt: "Read my GitHub profile and public repositories.")
    let id = try #require(session.activeConversationID)
    session.send()
    #expect(await inference.captured().isEmpty) // Inference consent is still required.
    session.cloudConsent = true
    session.send()
    for _ in 0..<500 {
        if !session.chatRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!session.chatRunning, "Conversation did not complete within five seconds")
    await session.flushConversations()
    let requests = await inference.captured()
    try #require(requests.count == 3)
    let bodies = try requests.map { try #require($0.httpBody) }
    let first = String(decoding: bodies[0], as: UTF8.self)
    #expect(!first.contains("noor-dev") && !first.contains("Read-only profile name"))
    let last = String(decoding: bodies[2], as: UTF8.self)
    #expect(last.contains("noor-dev") && last.contains("garden") && last.contains("Read-only profile name"))
    let history = String(decoding: try JSONSerialization.data(withJSONObject: session.conversations[0].history), as: UTF8.self)
    let archive = String(decoding: try JSONEncoder().encode(session.conversations), as: UTF8.self)
    for data in bodies + [Data(history.utf8), Data(archive.utf8)] {
        let text = String(decoding: data, as: UTF8.self)
        for sensitive in ["gho_fictional-private-token", "ghr_must-never-be-stored", "RAW-BODY-SECRET", "PRIVATE-EMAIL",
                          "legacy-client", "Authorization", "api.github.com", "permissions"] {
            #expect(!text.contains(sensitive))
        }
    }
    #expect(session.messages.last?.text == "Finished reading GitHub.")
    #expect(session.messages.filter { $0.kind == "tool" }.count == 2)
    #expect(history.contains("noor-dev") && history.contains("garden"))
    #expect(archive.contains("noor-dev") && archive.contains("garden"))
    #expect(!String(decoding: try #require(storage.document), as: UTF8.self).contains("noor-dev"))
    let restored = HabibiSession(store: HabibiStore(persistence: storage))
    await restored.start()
    restored.openConversation(id)
    #expect(!restored.cloudConsent)
    #expect(restored.messages.filter { $0.kind == "tool" }.count == 2)
    #expect(!restored.conversations[0].history.contains { $0["type"] as? String == "function_call" })
    #expect(await github.captured().count == 2)
}
