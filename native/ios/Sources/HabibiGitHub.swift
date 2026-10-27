import Combine
import CoreFoundation
import Foundation

struct HabibiGitHubConnection {
    let clientID: String
    let account: String
    fileprivate let accessToken: String
    fileprivate let scope: String
    fileprivate let expiresAt: Int64?

    // Only the host's encrypted connect_kit commit receives this object.
    var vaultValue: [String: Any] {
        var value: [String: Any] = ["kitId": "github", "clientId": clientID, "account": account,
                                    "accessToken": accessToken, "scope": scope]
        if let expiresAt { value["expiresAt"] = expiresAt }
        return value
    }
}

/// Fixed-endpoint, host-only OAuth. Never passed to an agent or a guest Kit.
/// The shared sync transport refuses redirects, cookies and oversized bodies.
@MainActor
struct HabibiGitHub {
    static let verificationURL = URL(string: "https://github.com/login/device")!
    private static let deviceURL = URL(string: "https://github.com/login/device/code")!
    private static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private static let userURL = URL(string: "https://api.github.com/user")!
    private static let repositoriesURL = URL(string: "https://api.github.com/user/repos?visibility=public&affiliation=owner&sort=updated&per_page=10")!
    private static let limit = 32 * 1024

    private let http: any HabibiSyncHTTP
    private let now: () -> Date
    private let sleep: (Int) async throws -> Void

    init(http: any HabibiSyncHTTP = HabibiSyncURLSession(), now: @escaping () -> Date = { Date() },
         sleep: @escaping (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.http = http; self.now = now; self.sleep = sleep
    }

    func authorize(clientID: String, showCode: (String, Date) -> Void) async throws -> HabibiGitHubConnection {
        guard Self.validClientID(clientID) else {
            throw HabibiFailure(message: HabibiBundledKit.githubUnavailable)
        }
        try Task.checkCancellation()
        // Start deadlines before sending so a delayed response cannot extend
        // the lifetime of either a device code or an access token.
        let started = now()
        let device = try await post(Self.deviceURL, values: ["client_id": clientID, "scope": "read:user"])
        guard device["error"] == nil,
              device["verification_uri"] as? String == Self.verificationURL.absoluteString,
              let deviceCode = device["device_code"] as? String,
              deviceCode.utf8.count == 40, deviceCode.utf8.allSatisfy({ Self.hex.contains($0) }),
              let userCode = device["user_code"] as? String, Self.validUserCode(userCode),
              let lifetime = Self.integer(device["expires_in"], in: 1...900),
              let initialInterval = Self.integer(device["interval"], in: 1...900) else { throw Self.invalid }
        let deadline = started.addingTimeInterval(Double(lifetime))
        guard now() < deadline else { throw Self.expired }
        showCode(userCode, deadline)
        var interval = initialInterval
        while true {
            try Task.checkCancellation()
            guard now() < deadline else { throw Self.expired }
            // Sleep after every response, including the first code response.
            // This never polls faster than GitHub's minimum interval.
            let remaining = max(1, Int(ceil(deadline.timeIntervalSince(now()))))
            try await sleep(min(interval, remaining))
            try Task.checkCancellation()
            guard now() < deadline else { throw Self.expired }
            let issued = now()
            let token = try await post(Self.tokenURL, values: ["client_id": clientID, "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            guard now() < deadline else { throw Self.expired }
            if let error = token["error"] as? String {
                guard token["access_token"] == nil else { throw Self.invalid }
                var returnedInterval: Int?
                if let value = token["interval"] {
                    guard let seconds = Self.integer(value, in: 1...3600) else { throw Self.invalid }
                    returnedInterval = seconds
                }
                switch error {
                case "authorization_pending": interval = max(interval, returnedInterval ?? interval)
                case "slow_down": interval = max(interval + 5, returnedInterval ?? 0)
                case "access_denied": throw HabibiFailure(message: "GitHub authorization was denied. Nothing was connected.")
                case "expired_token", "token_expired": throw Self.expired
                case "device_flow_disabled": throw HabibiFailure(message: "The publisher hasn’t enabled GitHub authorization for this build. Contact the publisher.")
                default: throw HabibiFailure(message: "GitHub could not authorize this build. Try again later or contact the publisher.")
                }
                continue
            }
            guard token["error"] == nil,
                  (token["token_type"] as? String)?.lowercased() == "bearer",
                  let access = token["access_token"] as? String, Self.validBearer(access),
                  let scope = token["scope"] as? String, scope == "" || scope == "read:user" else {
                throw HabibiFailure(message: "GitHub returned invalid credentials or broader permissions than read:user. Nothing was saved. Review or revoke the app in GitHub Settings → Applications.")
            }
            var expiresAt: Int64?
            if let value = token["expires_in"] {
                guard let seconds = Self.integer(value, in: 1...31_536_000) else { throw Self.invalid }
                expiresAt = Int64(issued.addingTimeInterval(Double(seconds)).timeIntervalSince1970.rounded(.down))
            }
            // Deliberately ignore refresh_token and refresh_token_expires_in.
            // Rotating refresh tokens cannot be safely owned by multiple
            // devices sharing an encrypted snapshot without coordination.
            let account = try await identity(token: access)
            try Task.checkCancellation()
            guard expiresAt.map({ Double($0) > now().timeIntervalSince1970 }) ?? true else { throw Self.expired }
            return HabibiGitHubConnection(clientID: clientID, account: account, accessToken: access, scope: scope, expiresAt: expiresAt)
        }
    }

    func checkConnection(_ descriptor: [String: Any]) async throws -> String {
        let request = try validatedRequest(descriptor, url: Self.userURL)
        let response = try await send(request, limit: Self.limit)
        guard let value = response as? [String: Any],
              let login = value["login"] as? String, (1...39).contains(login.utf8.count),
              login.utf8.allSatisfy({ Self.asciiAlphaNumeric.contains($0) || $0 == 45 }),
              !login.hasPrefix("-"), !login.hasSuffix("-"), !login.contains("--"),
              Self.integer(value["id"], in: 1...Int.max) != nil else { throw Self.invalid }
        return login
    }

    /// The raw body is host-only input to connection_result, never a tool result.
    func fetchTool(_ name: String, descriptor: [String: Any]) async throws -> Any {
        let url: URL
        let limit: Int
        switch name {
        case "github_get_profile": url = Self.userURL; limit = Self.limit
        case "github_list_repositories": url = Self.repositoriesURL; limit = 256 * 1024
        default: throw Self.invalid
        }
        let request = try validatedRequest(descriptor, url: url)
        let response = try await send(request, limit: limit)
        guard (name == "github_get_profile" && response is [String: Any])
                || (name == "github_list_repositories" && response is [[String: Any]]) else { throw Self.invalid }
        return response
    }

    private func validatedRequest(_ descriptor: [String: Any], url: URL) throws -> URLRequest {
        // Validate the Rust host request too. Neither a model nor a mutable
        // vault may turn this capability into arbitrary authenticated HTTP.
        guard Set(descriptor.keys) == Set(["url", "method", "headers"]),
              descriptor["url"] as? String == url.absoluteString, descriptor["method"] as? String == "GET",
              let headers = descriptor["headers"] as? [String: String],
              Set(headers.keys) == Set(["Authorization", "Accept", "X-GitHub-Api-Version"]),
              headers["Accept"] == "application/vnd.github+json", headers["X-GitHub-Api-Version"] == "2022-11-28",
              let authorization = headers["Authorization"], authorization.hasPrefix("Bearer "),
              Self.validBearer(String(authorization.dropFirst(7))) else { throw Self.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Habibi", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func validClientID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { asciiAlphaNumeric.contains($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    private func identity(token: String) async throws -> String {
        try await checkConnection(["url": Self.userURL.absoluteString, "method": "GET", "headers": [
            "Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]])
    }

    private func post(_ url: URL, values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        guard let value = try await send(request, limit: Self.limit) as? [String: Any] else { throw Self.invalid }
        return value
    }

    private func send(_ original: URLRequest, limit: Int) async throws -> Any {
        try Task.checkCancellation()
        var request = original
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 20
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await http.send(request, limit: limit) }
        catch {
            try Task.checkCancellation()
            // Never show raw transport errors or response bodies. They can
            // contain device codes, tokens or real account data.
            throw HabibiFailure(message: "Could not reach GitHub securely. Check your connection and start again.")
        }
        try Task.checkCancellation()
        guard response.url == request.url, data.count <= limit, response.expectedContentLength <= limit,
              response.mimeType == "application/json", !(300..<400).contains(response.statusCode) else { throw Self.invalid }
        guard response.statusCode == 200 || (request.url == Self.tokenURL && response.statusCode == 400) else {
            throw HabibiFailure(message: response.statusCode == 401 ? "GitHub authorization expired or was revoked. Reconnect to continue." : "GitHub rejected the request. Retry later or reconnect.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw Self.invalid }
        if response.statusCode == 400 {
            guard let error = object as? [String: Any], error["error"] is String, error["access_token"] == nil else { throw Self.invalid }
        }
        return object
    }

    private static let asciiAlphaNumeric = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
    private static let hex = Set("0123456789abcdefABCDEF".utf8)
    private static func validBearer(_ value: String) -> Bool {
        let allowed = asciiAlphaNumeric.union(Set("-._~+/=".utf8))
        return (8...4096).contains(value.utf8.count) && value.utf8.allSatisfy { allowed.contains($0) }
    }
    private static func validUserCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 9 && bytes[4] == 45 && bytes.enumerated().allSatisfy {
            $0.offset == 4 || Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8).contains($0.element)
        }
    }
    private static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        // NSNumber bridging otherwise accepts JSON booleans and fractional
        // values as integers, which is not the OAuth response contract.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), range.contains(integer) else { return nil }
        return integer
    }
    private static var invalid: HabibiFailure { HabibiFailure(message: "GitHub returned an unsafe or invalid response. Nothing new was connected. Start again.") }
    private static var expired: HabibiFailure { HabibiFailure(message: "GitHub authorization expired. Reconnect and use the new code.") }
}

@MainActor
final class HabibiGitHubConnector: ObservableObject {
    enum Activity { case connect, check, disconnect }
    @Published private(set) var activity: Activity?
    @Published private(set) var userCode: String?
    @Published private(set) var codeExpiresAt: Date?
    @Published private(set) var checkedLogin: String?
    @Published private(set) var error: String?
    private let github: HabibiGitHub
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(github: HabibiGitHub? = nil) { self.github = github ?? HabibiGitHub() }

    func perform(_ action: Activity, session: HabibiSession) {
        guard task == nil else { return }
        generation = UUID()
        let attempt = generation
        activity = action; error = nil; checkedLogin = nil
        task = Task {
            defer {
                if generation == attempt { activity = nil; userCode = nil; codeExpiresAt = nil; task = nil }
            }
            do {
                switch action {
                case .connect:
                    try await session.connectGitHub(using: github) { code, expiry in
                        guard self.generation == attempt, !Task.isCancelled else { return }
                        self.userCode = code; self.codeExpiresAt = expiry
                    }
                case .check:
                    let login = try await session.checkGitHub(using: github)
                    try Task.checkCancellation()
                    if generation == attempt { checkedLogin = login }
                case .disconnect: try await session.disconnectGitHub()
                }
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                self.error = (error as? HabibiFailure)?.message ?? "Could not finish the GitHub connection. Try again."
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        activity = nil; userCode = nil; codeExpiresAt = nil; checkedLogin = nil; error = nil
    }
}
