import Foundation
import Testing

private final class ChatGPTSecrets: HabibiSyncSecretStorage, @unchecked Sendable {
    var data: Data?
    var rejectReplacement = false
    func load() throws -> Data? { data }
    func save(_ value: Data) throws {
        if rejectReplacement, String(decoding: value, as: UTF8.self).contains("access_token") { throw HabibiFailure(message: "Disk full") }
        data = value
    }
    func delete() throws { data = nil }
}

private actor ChatGPTServer: HabibiSyncHTTP {
    var requests: [URLRequest] = []
    var polls = 0
    var failRefresh = false
    var failExchange = false
    var exchangeStarted = false
    let codeKey: String
    let pollFailures: Int
    let receiveGrant: @MainActor () -> Void
    private var holdExchange = false
    private var exchange: CheckedContinuation<Void, Never>?
    init(codeKey: String = "user_code", pollFailures: Int = 0, receiveGrant: @escaping @MainActor () -> Void = {}) {
        self.codeKey = codeKey; self.pollFailures = pollFailures; self.receiveGrant = receiveGrant
    }
    func pauseExchange() { holdExchange = true }
    func releaseExchange() { exchange?.resume(); exchange = nil }
    func exchanging() -> Bool { exchangeStarted }
    func loseRefresh() { failRefresh = true }
    func loseExchange() { failExchange = true }
    func captured() -> [URLRequest] { requests }
    nonisolated static func access(_ number: Int) -> String {
        let claims = Data("{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"account-\(number)\"}}".utf8).habibiBase64URL
        return "header.\(claims).signature"
    }
    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        func result(_ value: [String: Any], code: Int = 200) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        switch url.path {
        case "/api/accounts/deviceauth/usercode":
            #expect(url.host == "auth.openai.com")
            return try result(["device_auth_id": "device-id", codeKey: "ABCD-1234", "interval": "5"])
        case "/api/accounts/deviceauth/token":
            polls += 1
            if polls <= pollFailures { throw URLError(.networkConnectionLost) }
            if polls == 1 { return try result(["error": "slow_down"], code: 400) }
            if polls == 2 { return try result(["error": "deviceauth_authorization_pending"], code: 400) }
            await receiveGrant()
            return try result(["authorization_code": "authorization-code", "code_verifier": "device-verifier"])
        case "/oauth/token":
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            let refresh = body.contains("grant_type=refresh_token")
            if refresh && failRefresh { throw HabibiFailure(message: "Lost response") }
            if !refresh && failExchange { throw URLError(.networkConnectionLost) }
            #expect(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
            if !refresh { #expect(body.contains("code_verifier=device-verifier")) }
            if holdExchange { exchangeStarted = true; await withCheckedContinuation { exchange = $0 } }
            return try result(["access_token": Self.access(refresh ? 2 : 1), "refresh_token": refresh ? "replacement-refresh" : "first-refresh", "expires_in": 3600])
        case "/backend-api/codex/responses":
            #expect(url.host == "chatgpt.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.access(2))")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-2")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect(body["store"] as? Bool == false)
            #expect(body["stream"] as? Bool == true)
            #expect(body["max_output_tokens"] == nil)
            let event: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": [
                ["type": "message", "content": [["type": "output_text", "text": "Hello from ChatGPT."]]]
            ]]]
            let data = try JSONSerialization.data(withJSONObject: event)
            return (Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        default: throw HabibiFailure(message: "Unexpected test endpoint")
        }
    }
}

@MainActor
@Test func modelDefaultOverrideAndResetSurviveRestartAndReachChatGPT() async throws {
    let storage = MemoryPersistence()
    let secrets = ChatGPTSecrets()
    secrets.data = try JSONSerialization.data(withJSONObject: ["access_token": ChatGPTServer.access(2),
        "refresh_token": "fixture-refresh", "accountId": "account-2", "expiresAt": Date().timeIntervalSince1970 + 3600])
    let server = ChatGPTServer()
    let provider = HabibiChatGPT(secrets: secrets, http: server)
    let session = HabibiSession(store: HabibiStore(persistence: storage), chatGPT: provider)
    #expect(await session.create(.init(name: "Noor", goals: ["learning"], style: "warm")))
    session.newConversation()
    let first = try #require(session.activeConversationID)
    #expect(session.conversationModel == "gpt-6.1-sol")
    #expect(session.modelOverride == nil)
    try await session.setDefaultModel("gpt-6.1-terra")
    #expect(session.conversationModel == "gpt-6.1-terra")
    session.setConversationModel("gpt-6-luna")
    try await session.setDefaultModel("gpt-6.1-sol")
    #expect(session.conversationModel == "gpt-6-luna")
    session.newConversation()
    #expect(session.conversationModel == "gpt-6.1-sol")
    #expect(session.modelOverride == nil)
    await session.flushConversations()
    let restarted = HabibiSession(store: HabibiStore(persistence: storage), chatGPT: provider)
    await restarted.start()
    restarted.openConversation(first)
    #expect(restarted.modelOverride == "gpt-6-luna")
    #expect(restarted.defaultModel == "gpt-6.1-sol")
    restarted.cloudConsent = true
    for expected in ["gpt-6-luna", "gpt-6.1-sol"] {
        restarted.composer = "Hello"
        restarted.send()
        // A running turn cannot change models, even before HTTP begins.
        restarted.setConversationModel("gpt-6.1-terra")
        try await restarted.setDefaultModel("gpt-6.1-terra")
        for _ in 0..<500 {
            if !restarted.chatRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!restarted.chatRunning)
        #expect(restarted.messages.last?.text == "Hello from ChatGPT.")
        let requests = await server.captured()
        let body = try #require(requests.last?.httpBody)
        #expect((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String == expected)
        #expect(restarted.defaultModel == "gpt-6.1-sol")
        restarted.setConversationModel(nil)
    }
    await restarted.flushConversations()
    let final = try await HabibiStore(persistence: storage).restore()
    #expect(final?.conversations?.first?.modelOverride == nil)
    #expect(final?.profile.defaultModel == "gpt-6.1-sol")
    storage.rejectWrites = true
    await #expect(throws: (any Error).self) { try await restarted.setDefaultModel("gpt-6.1-terra") }
    #expect(restarted.defaultModel == "gpt-6.1-sol")
}

@MainActor
@Test(arguments: ["user_code", "usercode"])
func chatGPTConnectsRefreshesAndChatsWithoutPuttingCredentialsInTheVault(_ codeKey: String) async throws {
    let secrets = ChatGPTSecrets()
    let server = ChatGPTServer(codeKey: codeKey)
    let provider = HabibiChatGPT(secrets: secrets, http: server, sleep: { _ in })
    let session = HabibiSession(store: HabibiStore(persistence: MemoryPersistence()), chatGPT: provider)
    var displayed = ""
    try await session.connectChatGPT { displayed = $0 }
    #expect(displayed == "ABCD-1234")
    #expect(session.chatGPTConnected)
    #expect(!session.cloudConsent)
    var record = try JSONSerialization.jsonObject(with: secrets.data!) as! [String: Any]
    record["expiresAt"] = 0
    secrets.data = try JSONSerialization.data(withJSONObject: record)
    #expect(await session.create(.init(name: "PRIVATE-PROFILE", goals: ["learning"], style: "warm")))
    session.newConversation(prompt: "Hello")
    session.cloudConsent = true
    session.send()
    for _ in 0..<500 {
        if !session.chatRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.messages.last?.text == "Hello from ChatGPT.")
    let requests = await server.captured()
    let inference = try #require(requests.last?.httpBody)
    #expect(!String(decoding: inference, as: UTF8.self).contains("PRIVATE-PROFILE"))
    #expect(!String(decoding: inference, as: UTF8.self).contains("refresh"))
    let backup = try await session.exportRecovery()
    #expect(!String(describing: backup).contains("replacement-refresh"))
    #expect(String(decoding: secrets.data!, as: UTF8.self).contains("replacement-refresh"))
    try await session.disconnectChatGPT()
    #expect(!session.inferenceConnected)
    #expect(secrets.data == nil)
    #expect(session.snapshot?.profile.name == "PRIVATE-PROFILE")
}

@Test func chatGPTSignInSurvivesInterruptedPollingWithoutRestartingBrowserApproval() async throws {
    let secrets = ChatGPTSecrets()
    let server = ChatGPTServer(pollFailures: 2)
    let provider = HabibiChatGPT(secrets: secrets, http: server, sleep: { _ in })
    var codes: [String] = []
    try await provider.authorize { codes.append($0) }
    #expect(codes == ["ABCD-1234"])
    #expect(try await provider.connected())
    let requests = await server.captured()
    #expect(requests.filter { $0.url?.path == "/api/accounts/deviceauth/usercode" }.count == 1)
    #expect(requests.filter { $0.url?.path == "/api/accounts/deviceauth/token" }.count == 3)
    #expect(requests.filter { $0.url?.path == "/oauth/token" }.count == 1)
}

@MainActor
@Test(arguments: [false, true])
func chatGPTSignInWaitsForReturnFromBrowserBeforePollingOrExchanging(_ afterApproval: Bool) async throws {
    let secrets = ChatGPTSecrets()
    var foreground = afterApproval
    var codeShown = false
    var grantReceived = false
    let server = ChatGPTServer(receiveGrant: {
        if afterApproval { foreground = false; grantReceived = true }
    })
    let provider = HabibiChatGPT(secrets: secrets, http: server,
        sleep: { _ in try await Task.sleep(for: .milliseconds(1)) }, isForeground: { foreground })
    let authorization = Task { try await provider.authorize { _ in codeShown = true } }
    defer { authorization.cancel() }
    for _ in 0..<500 {
        if afterApproval ? grantReceived : codeShown { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(afterApproval ? grantReceived : codeShown)
    // Give an incorrect implementation time to issue requests while backgrounded.
    try await Task.sleep(for: .milliseconds(30))
    #expect(try await !provider.connected())
    let backgroundRequests = await server.captured()
    #expect(!backgroundRequests.contains { $0.url?.path == "/oauth/token" })
    if !afterApproval { #expect(!backgroundRequests.contains { $0.url?.path == "/api/accounts/deviceauth/token" }) }
    foreground = true
    try await authorization.value
    #expect(try await provider.connected())
}

@Test func chatGPTLostAuthorizationExchangeRequiresNewApprovalWithoutReplayingTheCode() async throws {
    let secrets = ChatGPTSecrets()
    let server = ChatGPTServer()
    await server.loseExchange()
    let provider = HabibiChatGPT(secrets: secrets, http: server, sleep: { _ in })
    do {
        try await provider.authorize { _ in }
        Issue.record("Lost exchange must require reconnection")
    } catch {
        #expect(error.localizedDescription.contains("Browser approval succeeded"))
    }
    #expect(try await !provider.connected())
    #expect(secrets.data == nil)
    #expect(await server.captured().filter { $0.url?.path == "/oauth/token" }.count == 1)
}

private struct RejectedChatGPTSignIn: HabibiSyncHTTP {
    let status: Int
    let body: String
    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        if status == 0 { throw URLError(.notConnectedToInternet) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func chatGPTSignInErrorsDistinguishTransportProviderAndInvalidResponses() async throws {
    for (status, body, explanation) in [
        (0, "", "connection"),
        (200, "not JSON", "unexpected"),
        (200, "{\"device_auth_id\":\"id\",\"user_code\":\"bad code!\"}", "unexpected"),
        (403, "{\"error\":\"PRIVATE-PROVIDER-DETAIL\"}", "HTTP 403"),
        (404, "{}", "Security settings"),
        (429, "{}", "Too many"),
        (503, "<html>PRIVATE-PROVIDER-DETAIL</html>", "HTTP 503")
    ] {
        let secrets = ChatGPTSecrets()
        let provider = HabibiChatGPT(secrets: secrets, http: RejectedChatGPTSignIn(status: status, body: body))
        do {
            try await provider.authorize { _ in Issue.record("A failed code request must not display a code") }
            Issue.record("Failed sign-in must throw")
        } catch {
            #expect(error.localizedDescription.contains(explanation))
            #expect(!error.localizedDescription.contains("PRIVATE-PROVIDER-DETAIL"))
            if status != 404 { #expect(!error.localizedDescription.contains("Security settings")) }
        }
        #expect(secrets.data == nil)
        #expect(try await !provider.connected())
    }
}

@Test func chatGPTLostOrUnsavedRotationCannotReplayTheOldRefreshToken() async throws {
    for loseResponse in [true, false] {
        let secrets = ChatGPTSecrets()
        let server = ChatGPTServer()
        let provider = HabibiChatGPT(secrets: secrets, http: server, sleep: { _ in })
        try await provider.authorize { _ in }
        var record = try JSONSerialization.jsonObject(with: secrets.data!) as! [String: Any]
        record["expiresAt"] = 0
        secrets.data = try JSONSerialization.data(withJSONObject: record)
        if loseResponse { await server.loseRefresh() } else { secrets.rejectReplacement = true }
        await #expect(throws: (any Error).self) { _ = try await provider.send([:]) }
        let restarted = HabibiChatGPT(secrets: secrets, http: server)
        #expect(try await !restarted.connected())
        await #expect(throws: (any Error).self) { _ = try await restarted.send([:]) }
        let refreshes = await server.captured().filter { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token") }
        #expect(refreshes.count == 1)
    }
}

@Test func chatGPTCancelledSignInNeverInstallsCredentials() async throws {
    let secrets = ChatGPTSecrets()
    let server = ChatGPTServer()
    await server.pauseExchange()
    let provider = HabibiChatGPT(secrets: secrets, http: server, sleep: { _ in })
    let authorization = Task { try await provider.authorize { _ in } }
    while !(await server.exchanging()) { await Task.yield() }
    authorization.cancel()
    await server.releaseExchange()
    _ = try? await authorization.value
    #expect(secrets.data == nil)
    #expect(try await !provider.connected())
}

@MainActor
@Test func onDeviceInferenceKeepsApprovalAndNeverFallsBackToConnectedCloudProviders() async throws {
    let storage = MemoryPersistence()
    let secrets = ChatGPTSecrets()
    secrets.data = try JSONSerialization.data(withJSONObject: ["access_token": ChatGPTServer.access(2),
        "refresh_token": "fixture-refresh", "accountId": "account-2", "expiresAt": Date().timeIntervalSince1970 + 3600])
    let server = ChatGPTServer()
    let definition: [String: Any] = ["apiVersion": 1, "name": "Walking", "description": "Track walks.",
        "fields": [["key": "minutes", "label": "Minutes", "type": "number", "unit": "min", "min": 0, "max": 600]],
        "source": "function summarize(s){return JSON.stringify({metrics:[]})}"]
    let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["definition": definition]), as: UTF8.self)
    var step = 0
    var unavailable: String?
    var fail = false
    let local = HabibiFoundationModels(availability: { unavailable }, generate: { _, prompt, _ in
        #expect(!prompt.contains("PRIVATE-PROFILE"))
        if fail { throw HabibiFailure(message: "Local generation failed.") }
        step += 1
        if step == 1 { return .init(action: "save_kit", content: "Offer a walking Kit for approval.") }
        if step == 2 { return .init(action: "save_kit", content: arguments) }
        return .init(action: "reply", content: "Your Kit was not installed.")
    })
    let session = HabibiSession(store: HabibiStore(persistence: storage),
        inferenceURL: URL(string: "https://inference.example/inference"), inferenceHTTP: server,
        chatGPT: HabibiChatGPT(secrets: secrets, http: server), onDevice: local)
    await session.start()
    #expect(session.chatGPTConnected)
    #expect(await session.create(.init(name: "PRIVATE-PROFILE", goals: ["health"], style: "warm")))
    session.newConversation()
    try await session.setDefaultModel(HabibiFoundationModels.id)
    #expect(session.inferenceConnected)
    #expect(!session.requiresCloudConsent)
    #expect(!session.cloudConsent)
    session.composer = "Make a walking Kit"
    session.send()
    for _ in 0..<500 {
        if session.review != nil || !session.chatRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(session.review != nil)
    #expect(session.snapshot?.kits.isEmpty == true)
    session.setConversationModel("gpt-6.1-sol")
    #expect(session.usesOnDeviceModel) // The whole approval continuation stays local.
    session.resolveReview(false)
    for _ in 0..<500 {
        if !session.chatRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!session.chatRunning)
    #expect(session.messages.last?.text == "Your Kit was not installed.")
    #expect(session.snapshot?.kits.isEmpty == true)
    fail = true
    session.composer = "Try again"
    session.send()
    for _ in 0..<500 {
        if !session.chatRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.messages.last?.text == "Local generation failed.")
    #expect(await server.captured().isEmpty)
    unavailable = "Apple Intelligence is turned off."
    session.refreshOnDeviceAvailability()
    #expect(!session.inferenceConnected)
    session.composer = "Keep this draft"
    session.send()
    #expect(!session.chatRunning)
    #expect(session.composer == "Keep this draft")
    #expect(await server.captured().isEmpty)
    await session.flushConversations()
    let restored = HabibiSession(store: HabibiStore(persistence: storage), onDevice: local)
    await restored.start()
    restored.openConversation(try #require(session.activeConversationID))
    #expect(restored.defaultModel == HabibiFoundationModels.id)
    #expect(restored.usesOnDeviceModel)
    restored.setConversationModel("gpt-6-luna")
    #expect(restored.requiresCloudConsent)
    #expect(!restored.cloudConsent)
}

@MainActor
@Test func onDeviceInvalidAndCancelledOutputCannotRequestTools() async throws {
    let request = try HabibiCore.execute(["operation": "agent_request", "today": "2026-10-27",
        "history": [["role": "user", "content": "List my Kits"]]])["body"] as! [String: Any]
    for output in ["[]", "{broken", "null"] {
        var step = 0
        let local = HabibiFoundationModels(availability: { nil }, generate: { _, _, _ in
            step += 1
            return .init(action: "list_kits", content: step == 1 ? "List installed Kits" : output)
        })
        await #expect(throws: (any Error).self) { _ = try await local.send(request) }
    }
    var finish: CheckedContinuation<HabibiFoundationModels.Decision, Never>?
    let local = HabibiFoundationModels(availability: { nil }, generate: { _, _, _ in
        await withCheckedContinuation { finish = $0 }
    })
    let pending = Task { try await local.send(request) }
    while finish == nil { await Task.yield() }
    pending.cancel()
    finish?.resume(returning: .init(action: "list_kits", content: "{}"))
    await #expect(throws: CancellationError.self) { _ = try await pending.value }
}
