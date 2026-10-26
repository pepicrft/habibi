import Foundation
import SwiftUI

struct HabibiReview: Identifiable {
    let id = UUID()
    let payload: [String: Any]
    var name: String { (payload["definition"] as? [String: Any])?["name"] as? String ?? "Kit" }
    var removal: Bool { payload["operation"] as? String == "remove_kit" }
}

struct HabibiMessage: Identifiable {
    var id = UUID()
    var createdAt = Date()
    let kind: String
    let text: String
    var component: HabibiComponent?
    var detail: String?
    var entryId: String?
}

struct HabibiConversation: Identifiable {
    var id = UUID()
    var createdAt = Date()
    var messages: [HabibiMessage] = []
    var composer = ""
    var history: [[String: Any]] = []
    var draft: [String: Any]?
    var title: String { messages.first(where: { $0.kind == "user" })?.text ?? "New conversation" }
}

private func conversationDate(_ value: String) throws -> Date {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = format.date(from: value) { return date }
    format.formatOptions = [.withInternetDateTime]
    guard let date = format.date(from: value) else { throw HabibiFailure(message: "Invalid conversation timestamp.") }
    return date
}

extension HabibiMessage: Codable {
    private enum CodingKeys: String, CodingKey { case id, createdAt, kind, text, component, detail, entryId }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try conversationDate(values.decode(String.self, forKey: .createdAt))
        kind = try values.decode(String.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        component = try values.decodeIfPresent(HabibiComponent.self, forKey: .component)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        entryId = try values.decodeIfPresent(String.self, forKey: .entryId)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(createdAt.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)), forKey: .createdAt)
        try values.encode(kind, forKey: .kind)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(component, forKey: .component)
        try values.encodeIfPresent(detail, forKey: .detail)
        try values.encodeIfPresent(entryId, forKey: .entryId)
    }
}

extension HabibiConversation: Codable {
    private enum CodingKeys: String, CodingKey { case id, createdAt, messages, composer, draft }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try conversationDate(values.decode(String.self, forKey: .createdAt))
        messages = try values.decode([HabibiMessage].self, forKey: .messages)
        composer = try values.decode(String.self, forKey: .composer)
        if let definition = try values.decodeIfPresent(HabibiDefinition.self, forKey: .draft) {
            draft = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any]
        }
        // Restore context, never raw provider tool calls, consent or approvals.
        history = messages.filter { $0.kind == "user" || $0.kind == "assistant" }
            .map { ["role": $0.kind, "content": $0.text] }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(createdAt.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)), forKey: .createdAt)
        try values.encode(messages, forKey: .messages)
        try values.encode(composer, forKey: .composer)
        if let draft {
            let definition = try JSONDecoder().decode(HabibiDefinition.self, from: JSONSerialization.data(withJSONObject: draft))
            try values.encode(definition, forKey: .draft)
        }
    }
}

@MainActor
final class HabibiSession: ObservableObject {
    @Published var snapshot: HabibiSnapshot?
    @Published var ready = false
    @Published var busy = false
    @Published var error: String?
    @Published var canRestartSetup = false
    @Published var selectedTab = 0
    @Published var review: HabibiReview?
    @Published var syncing = false
    @Published var syncConnected = false
    @Published var syncStatus: HabibiSyncStatus?
    @Published var syncError: String?
    @Published var lastSynced: Date?
    @Published private(set) var conversations: [HabibiConversation] = []
    @Published private(set) var conversationsSaved = true
    @Published private(set) var conversationSaveError: String?
    @Published private(set) var activeConversationID: UUID?
    @Published var conversationPath: [UUID] = []
    @Published var chatRunning = false
    var composer: String {
        get { activeConversation?.composer ?? "" }
        set { updateConversation { $0.composer = newValue } }
    }
    var messages: [HabibiMessage] {
        get { activeConversation?.messages ?? [] }
        set { updateConversation { $0.messages = newValue } }
    }
    var draft: [String: Any]? {
        get { activeConversation?.draft }
        set { updateConversation { $0.draft = newValue } }
    }
    private var history: [[String: Any]] {
        get { activeConversation?.history ?? [] }
        set { updateConversation(persist: false) { $0.history = newValue } }
    }
    private var activeConversation: HabibiConversation? { conversations.first { $0.id == activeConversationID } }
    var cloudConsent = false
    let store: HabibiStore
    let syncAccount: HabibiSyncAccount
    let syncBrowser = HabibiSyncBrowser()
    var syncMutationsLocked = false
    let inferenceURL: URL?
    private let inferenceToken: String?
    private var conversation: Task<Void, Never>?
    private var approval: CheckedContinuation<Bool, Never>?
    private var saveDebounce: Task<Void, Never>?
    private var saveWriter: Task<Void, Never>?
    private var conversationRevision: UInt64 = 0
    private var savedConversationRevision: UInt64 = 0
    private var preparingTool = false

    init(store: HabibiStore = HabibiStore(), syncAccount: HabibiSyncAccount = HabibiSyncAccount()) {
        self.store = store
        self.syncAccount = syncAccount
        var url: URL?
        var token: String?
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--inference-url"), arguments.count > index + 1,
           let candidate = URL(string: arguments[index + 1]), candidate.scheme == "http",
           candidate.host == "127.0.0.1", candidate.port == 8083, candidate.path == "/inference",
           candidate.query == nil, candidate.fragment == nil, candidate.user == nil,
           let keyIndex = arguments.firstIndex(of: "--inference-token"), arguments.count > keyIndex + 1,
           arguments[keyIndex + 1].count >= 32 {
            url = candidate
            token = arguments[keyIndex + 1]
        }
        #endif
        inferenceURL = url
        inferenceToken = token
    }

    func start() async {
        guard !ready, !busy else { return }
        busy = true
        defer { ready = true; busy = false }
        do {
            snapshot = try await store.restore()
            conversations = snapshot?.conversations ?? []
            error = nil
        }
        catch {
            self.error = error.localizedDescription
            canRestartSetup = (try? await store.incompleteSetup()) == true
        }
    }

    func create(_ profile: HabibiProfile) async -> Bool {
        guard !busy, !syncing else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await store.create(profile: profile)
            conversations = snapshot?.conversations ?? []
            return true
        }
        catch { self.error = error.localizedDescription; return false }
    }

    func recover(_ backup: Data, key: String) async -> Bool {
        guard !busy, !syncing, !chatRunning, saveWriter == nil else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await store.recover(backup: backup, key: key)
            saveDebounce?.cancel()
            conversations = snapshot?.conversations ?? []
            activeConversationID = nil
            conversationPath = []
            cloudConsent = false
            conversationRevision = 0
            savedConversationRevision = 0
            conversationsSaved = true
            conversationSaveError = nil
            return true
        }
        catch { self.error = error.localizedDescription; return false }
    }

    func persist(_ operation: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard !syncMutationsLocked else { throw HabibiFailure(message: "Wait for encrypted sync to finish before making changes.") }
        let result = try await store.call(operation, arguments: arguments, persist: true)
        snapshot = try await store.snapshot(result)
        return result
    }

    func executeTool(_ name: String, arguments: [String: Any]) async throws -> Any {
        guard !syncing else { throw HabibiFailure(message: "Wait for encrypted sync to finish before using a Kit tool.") }
        // Saving the archive changes the vault revision. Keep it out of the
        // preparation/approval/commit interval so it cannot stale its own review.
        preparingTool = true
        defer { preparingTool = false; scheduleConversationSave() }
        let result = try await store.call("kit_tool", arguments: ["name": name, "arguments": arguments, "today": habibiDay()])
        try Task.checkCancellation()
        if let draft = result["draft"] as? [String: Any] { self.draft = draft }
        if let payload = result["review"] as? [String: Any] {
            guard approval == nil else { throw HabibiFailure(message: "Finish the current Kit review first.") }
            let approved = await withCheckedContinuation { continuation in
                approval = continuation
                review = HabibiReview(payload: payload)
            }
            try Task.checkCancellation()
            guard approved else { return ["approved": false, "changed": false] }
            let committed = try await persist("commit_kit", arguments: ["review": payload])
            draft = nil
            return committed["result"] ?? [:]
        }
        return result["result"] ?? [:]
    }

    func resolveReview(_ approved: Bool) {
        let continuation = approval
        approval = nil
        review = nil
        continuation?.resume(returning: approved)
    }

    func stop() {
        let running = conversation
        running?.cancel()
        resolveReview(false)
        Task { await running?.value; await flushConversations() }
    }

    private func updateConversation(persist: Bool = true, _ update: (inout HabibiConversation) -> Void) {
        guard !syncMutationsLocked else { return }
        guard let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        update(&conversations[index])
        if persist { conversationChanged() }
    }

    private func conversationChanged() {
        conversationRevision += 1
        conversationsSaved = false
        scheduleConversationSave()
    }

    private func scheduleConversationSave() {
        saveDebounce?.cancel()
        guard snapshot != nil, !conversationsSaved, !preparingTool, review == nil else { return }
        saveDebounce = Task {
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            await flushConversations()
        }
    }

    func flushConversations() async {
        guard snapshot != nil, !preparingTool, review == nil else { return }
        if let saveWriter { await saveWriter.value; return }
        guard conversationRevision != savedConversationRevision else { return }
        // Never cancel a durable write when a newer keystroke cancels debounce.
        let writer = Task {
            defer { saveWriter = nil }
            conversationSaveError = nil
            while conversationRevision != savedConversationRevision, !preparingTool, review == nil {
                let revision = conversationRevision
                do {
                    let archived = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conversations))
                    _ = try await persist("save_conversations", arguments: ["conversations": archived])
                    savedConversationRevision = revision
                    conversationsSaved = conversationRevision == revision
                } catch {
                    conversationSaveError = "Could not save conversations: \(error.localizedDescription) Your unsaved changes are still here."
                    return
                }
            }
        }
        saveWriter = writer
        await writer.value
    }

    func exportRecovery() async throws -> [String: Any] {
        guard !syncing else { throw HabibiFailure(message: "Wait for sync to finish before preparing a recovery backup.") }
        await flushConversations()
        guard conversationsSaved else {
            throw HabibiFailure(message: conversationSaveError ?? "Finish the Kit review and save conversations before exporting a backup.")
        }
        return try await store.call("export_recovery")
    }

    func reloadSyncedVault() async throws {
        let restored = try await store.restore()
        saveDebounce?.cancel()
        snapshot = restored
        conversations = restored?.conversations ?? []
        if !conversations.contains(where: { $0.id == activeConversationID }) {
            activeConversationID = nil
            conversationPath = []
        }
        // A downloaded archive resumes as text, not an executable session.
        cloudConsent = false
        conversationRevision = 0
        savedConversationRevision = 0
        conversationsSaved = true
        conversationSaveError = nil
    }

    func newConversation(prompt: String = "") {
        guard !busy, !chatRunning, !syncing, review == nil else { return }
        var item = HabibiConversation()
        item.composer = prompt
        conversations.append(item)
        conversationChanged()
        activeConversationID = item.id
        selectedTab = 1
        conversationPath = [item.id]
    }

    func openConversation(_ id: UUID) {
        guard !busy, !syncing, conversations.contains(where: { $0.id == id }), !chatRunning || activeConversationID == id,
              review == nil || activeConversationID == id else { return }
        activeConversationID = id
        selectedTab = 1
        conversationPath = [id]
    }

    func submitKitEntry(conversationID: UUID, messageID: UUID, values: [String: Any]) async throws {
        guard !busy, !syncing, !chatRunning, review == nil else {
            throw HabibiFailure(message: "Finish the current operation before saving this entry.")
        }
        busy = true
        defer { preparingTool = false; busy = false; scheduleConversationSave() }
        await flushConversations()
        guard conversationsSaved else {
            throw HabibiFailure(message: conversationSaveError ?? "Save the conversation before using this card.")
        }
        // Keep the receipt and entry in one encrypted commit. Autosave must not
        // race that commit with an older transcript lacking its receipt.
        preparingTool = true
        let result = try await persist("submit_kit_entry", arguments: [
            "conversationId": conversationID.uuidString.lowercased(), "messageId": messageID.uuidString.lowercased(), "values": values
        ])
        guard let entryID = (result["result"] as? [String: Any])?["entryId"] as? String,
              let conversation = conversations.firstIndex(where: { $0.id == conversationID }),
              let message = conversations[conversation].messages.firstIndex(where: { $0.id == messageID }) else {
            throw HabibiFailure(message: "Could not display the saved entry receipt. Reopen this conversation before trying again.")
        }
        conversations[conversation].messages[message].entryId = entryID
        // Preserve keystrokes made during the disk write. Only the receipt is
        // copied back; actual entry values never enter provider history.
    }

    func componentSource(messageID: UUID, action: String) -> HabibiComponent? {
        guard let card = messages.first(where: { $0.id == messageID })?.component,
              action == "show_source", card.actions.contains(where: { $0.id == action }),
              let data = try? JSONEncoder().encode(card),
              let value = try? JSONSerialization.jsonObject(with: data),
              (try? HabibiCore.execute(["operation": "validate_component", "component": value])) != nil else { return nil }
        return card
    }

    func send() {
        let message = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeConversationID != nil, !busy, !syncing, !chatRunning, !message.isEmpty, message.count <= 4000, cloudConsent, let inferenceURL else { return }
        composer = ""
        messages.append(HabibiMessage(kind: "user", text: message))
        history.append(["role": "user", "content": message])
        chatRunning = true
        conversation = Task {
            defer { chatRunning = false; conversation = nil; scheduleConversationSave() }
            do {
                await flushConversations()
                if let conversationSaveError { throw HabibiFailure(message: conversationSaveError) }
                for _ in 0..<8 {
                    try Task.checkCancellation()
                    let requestHistory = history
                    let today = habibiDay()
                    let prepared = try await Task.detached { try HabibiCore.execute(["operation": "agent_request", "history": requestHistory, "today": today]) }.value
                    var request = URLRequest(url: inferenceURL)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 100
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(inferenceToken ?? "")", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONSerialization.data(withJSONObject: prepared["body"] ?? [:])
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          response.url == inferenceURL, data.count <= 128 * 1024 else {
                        throw HabibiFailure(message: "The development inference connection failed. Your saved Kits are unchanged.")
                    }
                    try Task.checkCancellation()
                    let responseObject = try JSONSerialization.jsonObject(with: data)
                    let step = try await Task.detached { try HabibiCore.execute(["operation": "agent_response", "response": responseObject]) }.value
                    history.append(contentsOf: step["output"] as? [[String: Any]] ?? [])
                    if let reply = step["reply"] as? String {
                        messages.append(HabibiMessage(kind: "assistant", text: reply))
                        await flushConversations()
                        return
                    }
                    guard let tool = step["tool"] as? [String: Any], let name = tool["name"] as? String,
                          let arguments = tool["arguments"] as? [String: Any], let callID = tool["callId"] as? String else {
                        throw HabibiFailure(message: "Invalid inference step.")
                    }
                    if name == "present_component" {
                        guard let card = step["component"],
                              let component = try? JSONDecoder().decode(HabibiComponent.self, from: JSONSerialization.data(withJSONObject: card)) else {
                            throw HabibiFailure(message: "The conversation component could not be displayed.")
                        }
                        messages.append(HabibiMessage(kind: "assistant", text: component.fallback, component: component))
                        history.append(["type": "function_call_output", "call_id": callID, "output": "{\"displayed\":true}"])
                        continue
                    }
                    messages.append(HabibiMessage(kind: "tool", text: "Running \(name)…"))
                    let toolMessage = messages.last!
                    var result: Any
                    do {
                        result = try await executeTool(name, arguments: arguments)
                        messages[messages.count - 1] = HabibiMessage(id: toolMessage.id, createdAt: toolMessage.createdAt, kind: "tool", text: "\(name) finished")
                    } catch {
                        try Task.checkCancellation()
                        result = ["error": error.localizedDescription]
                        messages[messages.count - 1] = HabibiMessage(id: toolMessage.id, createdAt: toolMessage.createdAt, kind: "tool", text: "\(name): \(error.localizedDescription)")
                    }
                    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
                    messages[messages.count - 1].detail = String(decoding: encoded, as: UTF8.self)
                    history.append(["type": "function_call_output", "call_id": callID, "output": String(decoding: encoded, as: UTF8.self)])
                }
                throw HabibiFailure(message: "The conversation reached its tool limit. Review your Kits before continuing.")
            } catch {
                let cancelled = Task.isCancelled
                messages.append(HabibiMessage(kind: "assistant", text: cancelled ? "Stopped. Already approved changes are still saved." : error.localizedDescription))
                history = []
            }
            await flushConversations()
        }
    }
}
