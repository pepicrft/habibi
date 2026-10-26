import CryptoKit
import Foundation
import Security

struct LabField: Codable, Identifiable {
    let key: String
    let label: String
    let type: String
    let min: Double?
    let max: Double?
    let unit: String?
    var id: String { key }
}

struct LabManifest: Codable {
    let apiVersion: Int
    let name: String
    let description: String
    let fields: [LabField]
    let entrypoint: [String]

    func validate() throws {
        guard apiVersion == 1, !name.isEmpty, name.utf8.count <= 120,
              description.utf8.count <= 2000, (1...12).contains(fields.count),
              Set(fields.map(\.key)).count == fields.count,
              (1...8).contains(entrypoint.count), entrypoint.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }) else {
            throw LabFailure(message: "The generated Kit does not match the host contract.")
        }
        for field in fields {
            guard field.key.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) != nil,
                  !field.label.isEmpty, field.label.utf8.count <= 80,
                  ["string", "number", "integer"].contains(field.type),
                  field.min?.isFinite != false, field.max?.isFinite != false,
                  (field.min ?? -1e9) >= -1e9, (field.max ?? 1e9) <= 1e9,
                  (field.min ?? -1e9) <= (field.max ?? 1e9) else {
                throw LabFailure(message: "An installed field is invalid.")
            }
        }
    }

    func entry(_ inputs: [String: String]) throws -> [String: LabValue] {
        var result: [String: LabValue] = [:]
        for field in fields {
            let input = (inputs[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if field.type == "string" {
                guard !input.isEmpty, input.count <= 500 else { throw LabFailure(message: "Enter \(field.label).") }
                result[field.key] = .string(input)
            } else {
                guard let value = Double(input), value.isFinite, abs(value) <= 1e9,
                      value >= (field.min ?? -1e9), value <= (field.max ?? 1e9),
                      field.type != "integer" || value.rounded() == value else {
                    throw LabFailure(message: "\(field.label) must be \(field.type == "integer" ? "a whole number" : "a number") between \(field.min ?? -1e9) and \(field.max ?? 1e9). Nothing was saved.")
                }
                result[field.key] = .number(value)
            }
        }
        return result
    }
}

enum LabValue: Codable {
    case string(String)
    case number(Double)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .string(let text): try value.encode(text); case .number(let number): try value.encode(number) }
    }
}

struct LabSource: Codable { let path: String; let content: String }
struct LabArtifact: Codable {
    let revision: String
    let files: [LabSource]
    var manifest: LabManifest {
        get throws {
            guard revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                  !files.isEmpty, files.count <= 32, Set(files.map(\.path)).count == files.count,
                  files.reduce(0, { $0 + $1.content.utf8.count }) <= 128 * 1024,
                  files.allSatisfy({ file in
                      file.content.utf8.count <= 32 * 1024 && !file.path.hasPrefix("/") &&
                      !file.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) &&
                      file.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !["", ".", "..", ".git"].contains($0.lowercased()) }
                  }), let source = files.first(where: { $0.path == "kit.json" }) else {
                throw LabFailure(message: "The committed source bundle is invalid.")
            }
            let manifest = try JSONDecoder().decode(LabManifest.self, from: Data(source.content.utf8))
            try manifest.validate()
            return manifest
        }
    }
}

struct LabSaved: Codable {
    let artifact: LabArtifact
    var entries: [[String: LabValue]]
}

// Separate bundle, keychain service, and file: this experiment never opens the
// real Habibi vault. Only sealed source/entries survive the disposable VM.
struct LabVault {
    private let service = "fyi.habibi.tinyarmlab.vault"
    private var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    var file: URL { directory.appendingPathComponent("lab-vault.aesgcm") }

    func load() throws -> LabSaved? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= 2 * 1024 * 1024 else { throw LabFailure(message: "The experimental vault is too large.") }
        return try JSONDecoder().decode(LabSaved.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(create: false)))
    }

    func save(_ value: LabSaved) throws {
        _ = try value.artifact.manifest
        let plaintext = try JSONEncoder().encode(value)
        guard plaintext.count <= 1024 * 1024 else { throw LabFailure(message: "The experimental vault is full.") }
        let sealed = try AES.GCM.seal(plaintext, using: key(create: true))
        guard let data = sealed.combined else { throw LabFailure(message: "Could not seal the experimental vault.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try excluded.setResourceValues(properties)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    private func key(create: Bool) throws -> SymmetricKey {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "key", kSecAttrSynchronizable: false]
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, create else { throw LabFailure(message: "The experimental vault key is unavailable.") }
        let key = SymmetricKey(size: .bits256)
        var record = query
        record[kSecValueData] = key.withUnsafeBytes { Data($0) }
        record[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else { throw LabFailure(message: "Could not save the experimental vault key.") }
        return key
    }
}
