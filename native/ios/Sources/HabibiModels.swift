import Foundation

struct HabibiFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct HabibiProfile: Codable, Equatable {
    var name: String
    var goals: [String]
    var style: String
    var theme: String? = nil
    var appearance: String? = nil

    static let interests = [
        ("health", "Health & fitness", "figure.strengthtraining.traditional"),
        ("learning", "Learning", "book"),
        ("planning", "Everyday planning", "calendar"),
        ("creativity", "Creativity", "paintbrush"),
        ("wellbeing", "Wellbeing", "leaf")
    ]
}

struct HabibiSnapshot: Decodable {
    let version: Int
    let profile: HabibiProfile
    let kits: [HabibiKit]
    let conversations: [HabibiConversation]?
    let connections: [HabibiConnectionSummary]?
    let drafts: [HabibiSyncedDraft]?
}

struct HabibiSyncedDraft: Decodable, Equatable {
    struct Version: Decodable, Equatable {
        let text: String
        let clock: [String: UInt64]
    }
    let id: UUID
    let versions: [Version]
}

// Display-only projection. Credentials are deliberately not decoded into the
// snapshot used by views, conversation history or model-facing Kit tools.
struct HabibiConnectionSummary: Decodable {
    let kitId: String
    let clientId: String
    let account: String
    let expiresAt: Int64?

    var expired: Bool { expired(at: Date()) }

    func expired(at date: Date) -> Bool {
        expiresAt.map { Double($0) <= date.timeIntervalSince1970 } ?? false
    }
}

struct HabibiBundledKit: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let permissions: [String]
    let authentication: String
    let clientId: String

    @MainActor var githubConfigured: Bool {
        id == "github" && permissions == ["read:user"] && authentication == "device_code"
            && HabibiGitHub.validClientID(clientId)
    }

    static let githubUnavailable = "The publisher hasn’t configured GitHub for this build. Connect is unavailable."

    static func catalog() throws -> [HabibiBundledKit] {
        let result = try HabibiCore.execute(["operation": "bundled_kits"])
        return try JSONDecoder().decode([Self].self, from: JSONSerialization.data(withJSONObject: result["kits"] ?? []))
    }
}

struct HabibiKit: Decodable, Identifiable {
    let id: String
    let definition: HabibiDefinition
    let entries: [HabibiEntry]
}

struct HabibiDefinition: Codable {
    let apiVersion: Int
    let name: String
    let description: String
    let fields: [HabibiField]
    let source: String
}

struct HabibiField: Codable, Identifiable {
    let key: String
    let label: String
    let type: String
    let unit: String
    let min: Double?
    let max: Double?
    var id: String { key }
}

struct HabibiEntry: Decodable, Identifiable {
    let id: String
    let createdAt: String
    let values: [String: HabibiValue]
}

enum HabibiValue: Codable, Equatable {
    case text(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self = .text(text) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        }
    }

    var display: String {
        switch self {
        case .text(let text): return text
        case .number(let number): return number.formatted()
        }
    }
}

struct HabibiMetric: Decodable, Identifiable {
    let label: String
    let value: String
    let unit: String
    var id: String { label }
}

func habibiDay(_ date: Date = Date()) -> String {
    let format = DateFormatter()
    format.calendar = Calendar(identifier: .gregorian)
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = .current
    format.dateFormat = "yyyy-MM-dd"
    return format.string(from: date)
}
