import Foundation
import UIKit

struct HabibiChatGPTCatalog: Decodable {
    struct Model: Decodable, Identifiable {
        let id: String
        let name: String
    }
    let defaultModel: String
    let models: [Model]
    static let shared: Self = {
        do {
            let value = try HabibiCore.execute(["operation": "chatgpt_models"])
            return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        } catch { preconditionFailure("The app must include the ChatGPT model catalog") }
    }()
    func name(_ id: String) -> String { models.first { $0.id == id }?.name ?? id }
}

// The public Codex OAuth client used by Pi. This is not a client secret.
// Device authorization avoids the CLI's localhost:1455 browser callback on phones.
actor HabibiChatGPT {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    enum SignInError: LocalizedError {
        case network, exchangeNetwork, invalidResponse, deviceLoginUnavailable, httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .network:
                return "Couldn’t reach OpenAI. Check your connection and try again."
            case .exchangeNetwork:
                return "Browser approval succeeded, but Habibi couldn’t finish connecting to OpenAI. Check your connection, then connect again for a new code."
            case .invalidResponse:
                return "OpenAI returned an unexpected sign-in response. Try again later."
            case .deviceLoginUnavailable:
                return "OpenAI’s device-code sign-in is unavailable. Check ChatGPT’s Security settings or try again later."
            case .httpStatus(429):
                return "Too many sign-in attempts. Wait a few minutes and try again."
            case .httpStatus(let status) where status >= 500:
                return "OpenAI sign-in is temporarily unavailable (HTTP \(status)). Try again later."
            case .httpStatus(let status):
                return "OpenAI declined sign-in (HTTP \(status)). This experimental connection may not be available for your account."
            }
        }
    }
    private static let inferenceURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private let secrets: any HabibiSyncSecretStorage
    private let http: any HabibiSyncHTTP
    private let sleep: (TimeInterval) async throws -> Void
    private let isForeground: @MainActor () -> Bool
    private var occupied = false

    init(secrets: any HabibiSyncSecretStorage = HabibiSyncKeychain(service: "fyi.habibi.chatgpt"),
         http: any HabibiSyncHTTP = HabibiSyncURLSession(resourceTimeout: 110),
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         isForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState != .background }) {
        self.secrets = secrets; self.http = http; self.sleep = sleep; self.isForeground = isForeground
    }

    func connected() throws -> Bool {
        guard let data = try secrets.load(), let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return record["refreshing"] as? Bool != true && record["access_token"] is String
    }

    func disconnect() throws {
        guard !occupied else { throw HabibiFailure(message: "Finish or cancel the ChatGPT request first.") }
        try secrets.delete()
    }

    func authorize(showCode: @MainActor (String) -> Void) async throws {
        guard !occupied else { throw HabibiFailure(message: "A ChatGPT request is already running.") }
        occupied = true
        defer { occupied = false }
        let device = try await json("/api/accounts/deviceauth/usercode", values: ["client_id": Self.clientID])
        guard let id = device["device_auth_id"] as? String, !id.isEmpty,
              let code = device["user_code"] as? String ?? device["usercode"] as? String, (4...32).contains(code.count),
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw signInFailure }
        var interval = (device["interval"] as? NSNumber)?.doubleValue ?? Double(device["interval"] as? String ?? "") ?? 5
        guard interval.isFinite, interval >= 0, interval <= 900 else { throw signInFailure }
        interval = max(5, interval)
        try Task.checkCancellation()
        await showCode(code)
        let deadline = Date().addingTimeInterval(15 * 60)
        var retryDelay: TimeInterval = 0
        while Date() < deadline {
            try await sleep(max(interval, retryDelay))
            guard try await waitForForeground(until: deadline) else { break }
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await post("/api/accounts/deviceauth/token", values: ["device_auth_id": id, "user_code": code])
                retryDelay = 0
            } catch SignInError.network {
                // Safari can suspend the app or interrupt an in-flight poll.
                // Keep the same device code and retry only this polling step.
                retryDelay = min(60, max(interval, retryDelay) * 2)
                continue
            }
            if [403, 404].contains(response.statusCode) { continue }
            if let failure = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let code = failure["error"] as? String ?? (failure["error"] as? [String: Any])?["code"] as? String
                if code == "deviceauth_authorization_pending" { continue }
                if code == "slow_down" { interval += 5; continue }
            }
            guard response.statusCode == 200 else { throw SignInError.httpStatus(response.statusCode) }
            guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let code = result["authorization_code"] as? String,
                  let verifier = result["code_verifier"] as? String else { throw signInFailure }
            guard try await waitForForeground(until: deadline) else { break }
            // Authorization codes are single-use. Unlike polling, an ambiguous
            // exchange failure must not automatically replay the request.
            let tokens: [String: Any]
            do {
                tokens = try await json("/oauth/token", values: ["grant_type": "authorization_code", "client_id": Self.clientID,
                    "code": code, "code_verifier": verifier, "redirect_uri": "https://auth.openai.com/deviceauth/callback"], form: true)
            } catch SignInError.network { throw SignInError.exchangeNetwork }
            let record = try credentials(tokens)
            try Task.checkCancellation()
            try secrets.save(JSONSerialization.data(withJSONObject: record))
            return
        }
        throw HabibiFailure(message: "The ChatGPT code expired. Connect again to get a new code.")
    }

    private func waitForForeground(until deadline: Date) async throws -> Bool {
        while Date() < deadline {
            try Task.checkCancellation()
            if await isForeground() { return true }
            try await sleep(1)
        }
        try Task.checkCancellation()
        return false
    }

    func send(_ body: [String: Any], model: String? = nil) async throws -> Any {
        guard !occupied else { throw HabibiFailure(message: "A ChatGPT request is already running.") }
        occupied = true
        defer { occupied = false }
        guard let data = try secrets.load(), var record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["refreshing"] as? Bool != true else { throw reconnect }
        if (record["expiresAt"] as? Double ?? 0) <= Date().timeIntervalSince1970 + 60 {
            guard let refresh = record["refresh_token"] as? String else { throw reconnect }
            // Never retry an ambiguously consumed rotating refresh token after a
            // crash, cancellation or failed persistence. Reconnect instead.
            try Task.checkCancellation()
            try secrets.save(JSONSerialization.data(withJSONObject: ["refreshing": true]))
            do {
                record = try credentials(await json("/oauth/token", values: ["grant_type": "refresh_token",
                    "client_id": Self.clientID, "refresh_token": refresh], form: true))
                try secrets.save(JSONSerialization.data(withJSONObject: record))
            } catch { throw reconnect }
        }
        guard let token = record["access_token"] as? String, let account = record["accountId"] as? String else { throw reconnect }
        var command: [String: Any] = ["operation": "chatgpt_request", "body": body]
        command["model"] = model
        let prepared = try HabibiCore.execute(command)
        var request = URLRequest(url: Self.inferenceURL)
        request.httpMethod = "POST"; request.timeoutInterval = 100
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("habibi", forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: prepared["body"] ?? [:])
        let result: Data
        let response: HTTPURLResponse
        do { (result, response) = try await http.send(request, limit: 2 * 1024 * 1024) }
        catch {
            try Task.checkCancellation()
            throw HabibiFailure(message: "Could not reach ChatGPT safely. Check your connection and try again.")
        }
        try Task.checkCancellation()
        guard response.url == Self.inferenceURL else { throw reconnect }
        if response.statusCode == 401 { throw reconnect }
        if response.statusCode == 429 { throw HabibiFailure(message: "ChatGPT usage limit reached. Review your plan at chatgpt.com/settings/usage and try again later.") }
        guard response.statusCode == 200, let stream = String(data: result, encoding: .utf8) else {
            throw HabibiFailure(message: "ChatGPT could not complete the request. Try another model or check your plan and connection.")
        }
        return try HabibiCore.execute(["operation": "chatgpt_response", "stream": stream])["response"] ?? [:]
    }

    private func post(_ path: String, values: [String: String], form: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "https://auth.openai.com" + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(form ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = form ? HabibiSyncAccount.form(values) : try JSONSerialization.data(withJSONObject: values)
        let result: (Data, HTTPURLResponse)
        do { result = try await http.send(request, limit: 64 * 1024) }
        catch { try Task.checkCancellation(); throw SignInError.network }
        try Task.checkCancellation()
        guard result.1.url == url else { throw signInFailure }
        return result
    }

    private func json(_ path: String, values: [String: String], form: Bool = false) async throws -> [String: Any] {
        let (data, response) = try await post(path, values: values, form: form)
        if response.statusCode == 404 && path == "/api/accounts/deviceauth/usercode" { throw SignInError.deviceLoginUnavailable }
        guard response.statusCode == 200 else { throw SignInError.httpStatus(response.statusCode) }
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw signInFailure }
        return value
    }

    private func credentials(_ tokens: [String: Any]) throws -> [String: Any] {
        func safe(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 32 * 1024 && text.utf8.allSatisfy { (33...126).contains($0) } }
        guard let access = tokens["access_token"] as? String, safe(access),
              let refresh = tokens["refresh_token"] as? String, safe(refresh),
              let lifetime = tokens["expires_in"] as? Double, lifetime.isFinite, lifetime > 0, lifetime <= 86400,
              let payload = access.split(separator: ".").dropFirst().first else { throw signInFailure }
        var base64 = String(payload).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        // This claim routes inference only; it is not a verified identity or a
        // Habibi login. The credential itself came from OpenAI over HTTPS.
        guard let data = Data(base64Encoded: base64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let account = auth["chatgpt_account_id"] as? String, safe(account), account.count <= 256 else { throw signInFailure }
        return ["access_token": access, "refresh_token": refresh, "accountId": account,
                "expiresAt": Date().timeIntervalSince1970 + lifetime]
    }

    private var signInFailure: SignInError { .invalidResponse }
    private var reconnect: HabibiFailure { HabibiFailure(message: "Reconnect ChatGPT in Profile → AI provider. Your vault is unchanged.") }
}
