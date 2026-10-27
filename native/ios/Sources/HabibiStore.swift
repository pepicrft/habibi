import Foundation
import HabibiCoreFFI
import Security

enum HabibiCore {
    static func execute(_ command: [String: Any]) throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: command)
        guard input.count <= 8 * 1024 * 1024, let text = String(data: input, encoding: .utf8) else {
            throw HabibiFailure(message: "This request is too large.")
        }
        return try text.withCString { input in
            guard let output = habibi_core_execute(input) else { throw HabibiFailure(message: "The local operation failed.") }
            defer { habibi_core_free(output) }
            let data = Data(String(cString: output).utf8)
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HabibiFailure(message: "Invalid local response.")
            }
            if let error = envelope["error"] as? [String: Any] {
                throw HabibiFailure(message: error["message"] as? String ?? "The operation failed.")
            }
            guard let result = envelope["ok"] as? [String: Any] else { throw HabibiFailure(message: "Invalid local result.") }
            return result
        }
    }
}

protocol HabibiPersistence {
    func loadIdentity() throws -> Data?
    func saveIdentity(_ data: Data) throws
    func deleteIdentity() throws
    func loadDocument() throws -> Data?
    func saveDocument(_ data: Data) throws
}

struct HabibiDevicePersistence: HabibiPersistence {
    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "fyi.habibi.vault", kSecAttrAccount: "identity", kSecAttrSynchronizable: false]
    }

    private var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Habibi", isDirectory: true).appendingPathComponent("vault.habibi")
    }

    func loadIdentity() throws -> Data? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw storageError }
        return data
    }

    func saveIdentity(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData] = data
            request[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw storageError }
        } else if status != errSecSuccess { throw storageError }
    }

    func deleteIdentity() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError }
    }

    func loadDocument() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4 * 1024 * 1024 else {
            throw HabibiFailure(message: "The saved vault is too large. It has not been changed.")
        }
        return try Data(contentsOf: file)
    }

    func saveDocument(_ data: Data) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    private var storageError: HabibiFailure { HabibiFailure(message: "Could not access this device’s private vault key. Unlock your device and try again.") }
}

actor HabibiStore {
    private let persistence: any HabibiPersistence
    private var identity: [String: Any]?
    private var document: [String: Any]?

    init(persistence: any HabibiPersistence = HabibiDevicePersistence()) { self.persistence = persistence }

    func restore() throws -> HabibiSnapshot? {
        let key = try persistence.loadIdentity()
        let encrypted = try persistence.loadDocument()
        if key == nil && encrypted == nil { return nil }
        guard let key, let encrypted else {
            throw HabibiFailure(message: "The private key or encrypted vault is missing. Your remaining data is untouched. Restore your backup to recover.")
        }
        let identity = try object(key)
        let document = try object(encrypted)
        let result = try HabibiCore.execute(["operation": "restore", "identity": identity, "document": document])
        let snapshot = try snapshot(result)
        self.identity = identity
        self.document = document
        return snapshot
    }

    func create(profile: HabibiProfile) throws -> HabibiSnapshot {
        try createOrRecover(["operation": "create", "profile": object(JSONEncoder().encode(profile))])
    }

    func recover(backup: Data, key: String) throws -> HabibiSnapshot {
        guard backup.count <= 4 * 1024 * 1024 else { throw HabibiFailure(message: "This backup is too large.") }
        return try createOrRecover(["operation": "recover", "backup": object(backup), "recoveryKey": key], recovering: true)
    }

    func incompleteSetup() throws -> Bool {
        try persistence.loadIdentity() != nil && persistence.loadDocument() == nil
    }

    // Called only after explicit native confirmation. Never discard a key when
    // an encrypted document exists, even if that document cannot be opened.
    func discardIncompleteSetup() throws {
        guard identity == nil, try incompleteSetup() else { throw HabibiFailure(message: "An existing vault cannot be reset here.") }
        try persistence.deleteIdentity()
    }

    private func createOrRecover(_ command: [String: Any], recovering: Bool = false) throws -> HabibiSnapshot {
        let previousIdentity = try persistence.loadIdentity()
        let previousDocument = try persistence.loadDocument()
        guard identity == nil, recovering || (previousIdentity == nil && previousDocument == nil) else {
            throw HabibiFailure(message: "A vault already exists on this device. It will not be replaced.")
        }
        // Authentication and full state validation happen before either write.
        // Recovery is also available after an interrupted two-store bootstrap.
        let result = try HabibiCore.execute(command)
        let snapshot = try snapshot(result)
        guard let identity = result["identity"] as? [String: Any], let document = result["document"] as? [String: Any] else {
            throw HabibiFailure(message: "Could not create the private vault.")
        }
        try persistence.saveIdentity(JSONSerialization.data(withJSONObject: identity))
        do { try persistence.saveDocument(JSONSerialization.data(withJSONObject: document)) }
        catch {
            if let previousIdentity { try persistence.saveIdentity(previousIdentity) }
            else { try persistence.deleteIdentity() }
            throw error
        }
        self.identity = identity
        self.document = document
        return snapshot
    }

    func call(_ operation: String, arguments: [String: Any] = [:], persist: Bool = false) throws -> [String: Any] {
        // Device authorization must not commit if its screen was dismissed
        // while waiting to enter this actor. Other durable writes retain their
        // existing cancellation behavior (notably conversation autosaves).
        let connecting = operation == "connect_kit"
        if connecting { try Task.checkCancellation() }
        guard let identity, let document else { throw HabibiFailure(message: "Open your vault first.") }
        var command = arguments
        command["operation"] = operation
        command["identity"] = identity
        command["document"] = document
        var result = try HabibiCore.execute(command)
        if persist {
            guard let candidate = result["document"] as? [String: Any] else { throw HabibiFailure(message: "The operation returned no encrypted record.") }
            if result["state"] == nil {
                result["state"] = try HabibiCore.execute(["operation": "restore", "identity": identity, "document": candidate])["state"]
            }
            _ = try snapshot(result)
            let encoded = try JSONSerialization.data(withJSONObject: candidate)
            if connecting { try Task.checkCancellation() }
            try persistence.saveDocument(encoded)
            self.document = candidate
        }
        return result
    }

    func snapshot(_ result: [String: Any]) throws -> HabibiSnapshot {
        guard let value = result["state"] else { throw HabibiFailure(message: "The local state is unavailable.") }
        return try JSONDecoder().decode(HabibiSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HabibiFailure(message: "Invalid saved vault.") }
        return object
    }
}
