import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct HabibiSyncOrigin: Equatable {
    let value: String

    init(_ value: String, development: Bool = false) throws {
        guard let url = URLComponents(string: value), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (development && url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)),
              host == host.lowercased(), !host.isEmpty else {
            throw HabibiFailure(message: "Sync requires an HTTPS server origin. Local HTTP is available only in simulator development builds.")
        }
        var origin = url
        origin.path = ""
        guard let canonical = origin.string else { throw HabibiFailure(message: "Invalid sync server.") }
        self.value = canonical
    }

    static var current: HabibiSyncOrigin {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--sync-url"), arguments.count > index + 1,
           let origin = try? HabibiSyncOrigin(arguments[index + 1], development: true),
           origin.value == "http://localhost:4000" || origin.value == "http://127.0.0.1:4000" { return origin }
        #endif
        return try! HabibiSyncOrigin("https://habibi.fyi")
    }

    func url(_ path: String) -> URL { URL(string: value + path)! }
}

protocol HabibiSyncSecretStorage {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

struct HabibiSyncKeychain: HabibiSyncSecretStorage {
    var service = "fyi.habibi.sync"
    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "oauth", kSecAttrSynchronizable: false]
    }
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw failure }
        return data
    }
    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = query
            query[kSecValueData] = data
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw failure }
        } else if status != errSecSuccess { throw failure }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure }
    }
    private var failure: HabibiFailure { HabibiFailure(message: "Could not access the private sync credentials. Unlock your device and retry.") }
}

protocol HabibiSyncHTTP {
    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse)
}

private final class HabibiSyncRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class HabibiSyncURLSession: HabibiSyncHTTP {
    private let session: URLSession
    init(resourceTimeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: config, delegate: HabibiSyncRedirectPolicy(), delegateQueue: nil)
    }
    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        do {
            let (stream, response) = try await session.bytes(for: request)
            defer { stream.task.cancel() }
            guard let response = response as? HTTPURLResponse, !(300..<400).contains(response.statusCode),
                  response.expectedContentLength <= limit else { throw HabibiFailure(message: "The sync server returned an unsafe response.") }
            var data = Data()
            for try await byte in stream {
                guard data.count < limit else { throw HabibiFailure(message: "The sync response exceeded its size limit.") }
                data.append(byte)
            }
            return (data, response)
        } catch let failure as HabibiFailure { throw failure }
        catch { throw HabibiFailure(message: "Could not reach the sync server. Your local vault is unchanged; retry when online.") }
    }
}

struct HabibiSyncAuthorization {
    static let redirect = "fyi.habibi.ios:/oauth/callback"
    let origin: HabibiSyncOrigin
    let clientID: String
    let verifier: String
    let state: String
    let createdAt: Date

    init(origin: HabibiSyncOrigin, clientID: String, now: Date = Date()) throws {
        func random(_ count: Int) throws -> String {
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw HabibiFailure(message: "Secure randomness is unavailable.")
            }
            return Data(bytes).habibiBase64URL
        }
        self.origin = origin; self.clientID = clientID; createdAt = now
        verifier = try random(48); state = try random(32)
    }

    var url: URL {
        var url = URLComponents(url: origin.url("/oauth/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = ["response_type": "code", "client_id": clientID, "redirect_uri": Self.redirect,
                          "scope": "vaults:sync", "state": state, "code_challenge_method": "S256",
                          "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).habibiBase64URL]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    func code(from callback: URL, now: Date = Date()) throws -> String {
        guard var url = URLComponents(url: callback, resolvingAgainstBaseURL: false), url.fragment == nil,
              now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) < 900 else { throw invalid }
        let parameters = url.queryItems ?? []
        url.query = nil
        guard url.string == Self.redirect, Set(parameters.map(\.name)).count == parameters.count,
              parameters.allSatisfy({ ["state", "iss", "code", "error", "error_description", "error_uri"].contains($0.name) }),
              parameters.first(where: { $0.name == "state" })?.value == state,
              parameters.first(where: { $0.name == "iss" })?.value == origin.value else { throw invalid }
        guard !parameters.contains(where: { $0.name == "error" }),
              let code = parameters.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              code.utf8.count <= 2048, !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid }
        return code
    }
    private var invalid: HabibiFailure { HabibiFailure(message: "Sign-in was canceled, expired or returned an invalid callback. Start again.") }
}

extension Data {
    var habibiBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init(habibiBase64URL value: String) throws {
        let encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)),
              bytes.habibiBase64URL == value else { throw HabibiFailure(message: "Invalid encrypted sync record.") }
        self = bytes
    }
}

actor HabibiSyncAccount {
    private struct Credentials: Codable {
        var origin: String
        var clientID: String
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
    }
    let origin: HabibiSyncOrigin
    private let storage: any HabibiSyncSecretStorage
    private let http: any HabibiSyncHTTP
    private var refreshing = false
    private var authorizing = false
    private var authorizationState: String?

    init(origin: HabibiSyncOrigin = .current, storage: any HabibiSyncSecretStorage = HabibiSyncKeychain(), http: any HabibiSyncHTTP = HabibiSyncURLSession()) {
        self.origin = origin; self.storage = storage; self.http = http
    }
    private func credentials() throws -> Credentials? {
        guard let data = try storage.load() else { return nil }
        let credentials = try JSONDecoder().decode(Credentials.self, from: data)
        guard credentials.origin == origin.value else { throw HabibiFailure(message: "Disconnect the previous sync server before connecting another.") }
        return credentials
    }
    func connected() throws -> Bool { try credentials()?.refreshToken != nil }

    func begin() async throws -> HabibiSyncAuthorization {
        guard !authorizing, authorizationState == nil else { throw HabibiFailure(message: "A sign-in is already open.") }
        authorizing = true
        defer { authorizing = false }
        let (data, response) = try await request("/.well-known/oauth-authorization-server")
        let metadata = try object(data, status: response.statusCode, expected: [200])
        guard metadata["issuer"] as? String == origin.value,
              metadata["authorization_endpoint"] as? String == origin.value + "/oauth/authorize",
              metadata["token_endpoint"] as? String == origin.value + "/oauth/token",
              metadata["registration_endpoint"] as? String == origin.value + "/oauth/register",
              metadata["revocation_endpoint"] as? String == origin.value + "/oauth/revoke",
              (metadata["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
              metadata["authorization_response_iss_parameter_supported"] as? Bool == true else {
            throw HabibiFailure(message: "This server does not support Habibi’s native sign-in contract.")
        }
        var clientID = try credentials()?.clientID
        if clientID == nil {
            let body = try JSONSerialization.data(withJSONObject: ["client_name": "Habibi for iPhone", "application_type": "native",
                "redirect_uris": [HabibiSyncAuthorization.redirect], "token_endpoint_auth_method": "none",
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "scope": "vaults:sync"])
            let (data, response) = try await request("/oauth/register", method: "POST", body: body, contentType: "application/json")
            let registration = try object(data, status: response.statusCode, expected: [201])
            guard let id = registration["client_id"] as? String, UUID(uuidString: id) != nil,
                  registration["redirect_uris"] as? [String] == [HabibiSyncAuthorization.redirect],
                  registration["token_endpoint_auth_method"] as? String == "none" else {
                throw HabibiFailure(message: "Invalid native client registration.")
            }
            clientID = id
            try storage.save(JSONEncoder().encode(Credentials(origin: origin.value, clientID: id)))
        }
        let authorization = try HabibiSyncAuthorization(origin: origin, clientID: clientID!)
        authorizationState = authorization.state
        return authorization
    }

    func cancelAuthorization() { authorizationState = nil }

    func finish(_ authorization: HabibiSyncAuthorization, callback: URL) async throws {
        guard authorization.origin == origin, authorizationState == authorization.state else { throw HabibiFailure(message: "There is no matching pending sign-in. Start again.") }
        authorizationState = nil
        let code = try authorization.code(from: callback)
        let values = ["grant_type": "authorization_code", "client_id": authorization.clientID, "code": code,
                      "redirect_uri": HabibiSyncAuthorization.redirect, "code_verifier": authorization.verifier]
        let credentials = try await exchange(values, clientID: authorization.clientID)
        try storage.save(JSONEncoder().encode(credentials))
    }

    private func exchange(_ values: [String: String], clientID: String) async throws -> Credentials {
        let (data, response) = try await request("/oauth/token", method: "POST", body: Self.form(values), contentType: "application/x-www-form-urlencoded")
        let result = try object(data, status: response.statusCode, expected: [200])
        guard let access = result["access_token"] as? String, let refresh = result["refresh_token"] as? String,
              [access, refresh].allSatisfy({ (8...4096).contains($0.utf8.count) && !$0.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) }),
              (result["token_type"] as? String)?.lowercased() == "bearer",
              let seconds = result["expires_in"] as? Int, (1...3600).contains(seconds),
              (result["scope"] as? String)?.split(separator: " ").contains("vaults:sync") == true else {
            throw HabibiFailure(message: "The server returned invalid sync credentials. Sign in again.")
        }
        return Credentials(origin: origin.value, clientID: clientID, accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(Double(seconds)))
    }

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard var credentials = try credentials(), let refresh = credentials.refreshToken else { throw signedOut }
        if !forceRefresh, let expires = credentials.expiresAt, expires.timeIntervalSinceNow > 60, let token = credentials.accessToken { return token }
        guard !refreshing else { throw HabibiFailure(message: "Sync credentials are being refreshed. Retry shortly.") }
        refreshing = true
        defer { refreshing = false }
        // A refresh is single-use, even if its response is lost. Commit the
        // unusable marker before the request so process death cannot replay it.
        credentials.accessToken = nil; credentials.refreshToken = nil; credentials.expiresAt = nil
        try storage.save(JSONEncoder().encode(credentials))
        let next = try await exchange(["grant_type": "refresh_token", "client_id": credentials.clientID, "refresh_token": refresh], clientID: credentials.clientID)
        try storage.save(JSONEncoder().encode(next))
        return next.accessToken!
    }

    @discardableResult
    func verifyAccount() async throws -> UUID {
        var (data, response) = try await authorized("/v1/me")
        if response.statusCode == 401 {
            let token = try await accessToken(forceRefresh: true)
            (data, response) = try await request("/v1/me", headers: ["Authorization": "Bearer \(token)"])
        }
        let value = try object(data, status: response.statusCode, expected: [200])
        guard let sub = value["sub"] as? String, let subject = UUID(uuidString: sub) else { throw signedOut }
        return subject
    }

    func authorized(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil,
                    vaultToken: String? = nil, limit: Int = 32 * 1024,
                    headers additional: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let token = try await accessToken()
        var headers = additional
        headers["Authorization"] = "Bearer \(token)"
        if let vaultToken { headers["X-Habibi-Vault-Token"] = vaultToken }
        return try await request(path, method: method, body: body, contentType: contentType, headers: headers, limit: limit)
    }

    func disconnect() async throws {
        let saved = try credentials()
        // Stop local access first. A network failure must not reconnect us.
        try storage.delete()
        guard let saved, let token = saved.refreshToken else { return }
        let (_, response) = try await request("/oauth/revoke", method: "POST", body: Self.form([
            "client_id": saved.clientID, "token": token, "token_type_hint": "refresh_token"]), contentType: "application/x-www-form-urlencoded")
        guard response.statusCode == 200 else { throw HabibiFailure(message: "Disconnected on this device, but server revocation failed. The old grant may remain active until expiry.") }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil,
                         headers: [String: String] = [:], limit: Int = 32 * 1024) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#") else { throw signedOut }
        var request = URLRequest(url: origin.url(path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await http.send(request, limit: limit)
    }

    private func object(_ data: Data, status: Int, expected: Set<Int>) throws -> [String: Any] {
        guard expected.contains(status), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HabibiFailure(message: status == 401 ? "Sync authorization expired or was revoked. Sign in again." : "The sync server rejected the request (HTTP \(status)). Your local vault is safe.")
        }
        return result
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    private var signedOut: HabibiFailure { HabibiFailure(message: "Sign in to connect encrypted sync. A lost refresh response requires a new sign-in, not a retry of the old token.") }
}

@MainActor
final class HabibiSyncBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func open(_ url: URL) async throws -> URL {
        guard session == nil else { throw HabibiFailure(message: "A sign-in is already open.") }
        return try await withCheckedThrowingContinuation { continuation in
            let authentication = ASWebAuthenticationSession(url: url, callbackURLScheme: "fyi.habibi.ios") { [weak self] callback, _ in
                Task { @MainActor in
                    self?.session = nil
                    if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: HabibiFailure(message: "Sign-in was canceled. Your vault is unchanged.")) }
                }
            }
            authentication.presentationContextProvider = self
            session = authentication
            if !authentication.start() {
                session = nil
                continuation.resume(throwing: HabibiFailure(message: "Could not open system sign-in. Retry from the app."))
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
