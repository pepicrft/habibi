import Foundation
import Speech
import Testing

@MainActor
private final class VoiceCapture: HabibiVoiceCapturing {
    var updates: [(@MainActor (HabibiVoiceCaptureUpdate) -> Void)] = []
    func start(update: @escaping @MainActor (HabibiVoiceCaptureUpdate) -> Void) throws { updates.append(update) }
    func stop() {}
}

@MainActor
@Test func dictationAppendsOnlyOnExplicitFinishAndRejectsLateCallbacks() async {
    let capture = VoiceCapture()
    let voice = HabibiVoiceInput(capture: capture, speechPermission: { .authorized }, microphonePermission: { true })
    var draft = "Already typed."
    await voice.start()
    capture.updates[0](.transcript("take a walk", final: false))
    #expect(draft == "Already typed.")
    voice.finish { draft = HabibiVoiceInput.appending($0, to: draft) }
    #expect(draft == "Already typed. take a walk")
    capture.updates[0](.transcript("late replacement", final: true))
    #expect(draft == "Already typed. take a walk")
    #expect(voice.phase == .idle)
    await voice.start()
    capture.updates[0](.failed)
    #expect(voice.phase == .recording)
    capture.updates[1](.transcript("discard me", final: false))
    voice.cancel()
    voice.finish { draft = $0 }
    #expect(draft == "Already typed. take a walk")
    #expect(HabibiVoiceInput.appending(" words ", to: "Ends in space ") == "Ends in space words")
}

@MainActor
@Test func finalRecognitionDoesNotSendOrAcceptTextWithoutStop() async {
    let capture = VoiceCapture()
    let voice = HabibiVoiceInput(capture: capture, speechPermission: { .authorized }, microphonePermission: { true })
    await voice.start()
    capture.updates[0](.transcript("Keep this hypothesis", final: true))
    capture.updates[0](.failed)
    #expect(voice.phase == .recording)
    #expect(voice.transcript == "Keep this hypothesis")
    var accepted = ""
    voice.finish { accepted = $0 }
    #expect(accepted == "Keep this hypothesis")
    voice.finish { _ in accepted = "incorrect second completion" }
    #expect(accepted == "Keep this hypothesis")
}

@MainActor
@Test func permissionCancellationCannotStartCaptureLater() async {
    let capture = VoiceCapture()
    var permission: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
    let voice = HabibiVoiceInput(capture: capture, speechPermission: {
        await withCheckedContinuation { permission = $0 }
    }, microphonePermission: { true })
    let start = Task { await voice.start() }
    while permission == nil { await Task.yield() }
    voice.cancel()
    permission?.resume(returning: .authorized)
    await start.value
    #expect(capture.updates.isEmpty)
    #expect(voice.phase == .idle)
    #expect(voice.errorMessage != nil)
}

@MainActor
@Test func deniedAndEmptyDictationPreserveTypedText() async {
    let capture = VoiceCapture()
    let denied = HabibiVoiceInput(capture: capture, speechPermission: { .denied }, microphonePermission: { true })
    await denied.start()
    #expect(denied.phase == .idle)
    #expect(denied.errorMessage != nil)
    #expect(capture.updates.isEmpty)
    let voice = HabibiVoiceInput(capture: capture, speechPermission: { .authorized }, microphonePermission: { true })
    await voice.start()
    var draft = "Keep my edits"
    voice.finish { draft = $0 }
    #expect(draft == "Keep my edits")
    #expect(voice.phase == .idle)
    #expect(voice.errorMessage != nil)
    #if targetEnvironment(simulator)
    let simulator = HabibiVoiceInput(speechPermission: { .authorized }, microphonePermission: { true })
    await simulator.start()
    simulator.finish { draft = $0 }
    #expect(simulator.phase == .idle)
    #expect(simulator.errorMessage?.contains("physical iPhone") == true)
    #expect(draft == "Keep my edits")
    #endif
}

@MainActor
@Test func conversationsKeepIndependentDraftsMessagesAndComponents() throws {
    let session = HabibiSession()
    session.newConversation(prompt: "First draft")
    let first = try #require(session.activeConversationID)
    session.messages.append(HabibiMessage(kind: "user", text: "First prompt"))
    let card = HabibiComponent(type: "result_table", version: 1,
                              data: .init(title: "Workout plan", columns: ["Day", "Minutes"], rows: [["Tuesday", "25"]]),
                              actions: [.init(id: "show_source", label: "View data")], fallback: "Tuesday: 25 minutes")
    let message = HabibiMessage(kind: "assistant", text: card.fallback, component: card)
    session.messages.append(message)
    #expect(session.componentSource(messageID: message.id, action: "show_source") == card)
    #expect(session.componentSource(messageID: message.id, action: "delete") == nil)
    session.newConversation(prompt: "Second draft")
    let second = try #require(session.activeConversationID)
    #expect(second != first)
    #expect(session.messages.isEmpty)
    #expect(session.componentSource(messageID: message.id, action: "show_source") == nil)
    session.composer = "Second draft edited"
    session.openConversation(first)
    #expect(session.composer == "First draft")
    #expect(session.messages.count == 2)
    #expect(session.conversationPath == [first])
    session.openConversation(second)
    #expect(session.composer == "Second draft edited")
    session.chatRunning = true
    session.openConversation(first)
    session.newConversation()
    #expect(session.activeConversationID == second)
    #expect(session.conversations.count == 2)
}

@MainActor
@Test func encryptedConversationsRestoreCardsDraftsAndTextContextWithoutReplayingTools() async throws {
    let storage = MemoryPersistence()
    let session = HabibiSession(store: HabibiStore(persistence: storage))
    #expect(await session.create(.init(name: "Noor", goals: ["health"], style: "warm")))
    session.newConversation(prompt: "Unsent: caminata 🏃🏽‍♀️")
    let first = try #require(session.activeConversationID)
    let card = HabibiComponent(type: "result_table", version: 1,
                              data: .init(title: "Walking plan", columns: ["Day", "Minutes"], rows: [["Tuesday", "25"]]),
                              actions: [.init(id: "show_source", label: "View data")], fallback: "Tuesday: 25 minutes")
    let reply = HabibiMessage(kind: "assistant", text: card.fallback, component: card)
    session.messages = [HabibiMessage(kind: "user", text: "Private walking journal"),
                        HabibiMessage(kind: "tool", text: "evaluate_kit finished", detail: "{\"synthetic\":true}"), reply]
    session.newConversation(prompt: "Second private draft")
    let second = try #require(session.activeConversationID)
    await session.flushConversations()
    #expect(session.conversationsSaved)
    #expect(session.conversationSaveError == nil)
    let ciphertext = String(decoding: try #require(storage.document), as: UTF8.self)
    #expect(!ciphertext.contains("Private walking journal"))
    #expect(!ciphertext.contains("caminata"))
    let restored = HabibiSession(store: HabibiStore(persistence: storage))
    await restored.start()
    #expect(restored.conversations.map(\.id) == [first, second])
    #expect(!restored.cloudConsent)
    #expect(!restored.chatRunning)
    #expect(restored.review == nil)
    restored.openConversation(first)
    #expect(restored.composer == "Unsent: caminata 🏃🏽‍♀️")
    #expect(restored.messages.map(\.id) == session.conversations[0].messages.map(\.id))
    #expect(restored.componentSource(messageID: reply.id, action: "show_source") == card)
    #expect(restored.conversations[0].history.count == 2)
    #expect(restored.conversations[0].history[0]["role"] as? String == "user")
    #expect(restored.conversations[0].history[1]["content"] as? String == card.fallback)
    let durable = storage.document
    storage.rejectWrites = true
    restored.composer = "Latest edit, not yet durable"
    await restored.flushConversations()
    #expect(!restored.conversationsSaved)
    #expect(restored.conversationSaveError?.contains("Disk full") == true)
    #expect(storage.document == durable)
    #expect(restored.composer == "Latest edit, not yet durable")
    storage.rejectWrites = false
    await restored.flushConversations()
    #expect(restored.conversationsSaved)
    #expect(restored.conversationSaveError == nil)
    restored.composer = "Included in backup before debounce"
    let exported = try await restored.exportRecovery()
    let recovered = HabibiSession(store: HabibiStore(persistence: MemoryPersistence()))
    #expect(await recovered.recover(try JSONSerialization.data(withJSONObject: exported["backup"]!), key: exported["recoveryKey"] as! String))
    recovered.openConversation(first)
    #expect(recovered.composer == "Included in backup before debounce")
    #expect(recovered.componentSource(messageID: reply.id, action: "show_source") == card)
    recovered.openConversation(second)
    #expect(recovered.composer == "Second private draft")
}

@MainActor
@Test func conversationAutosaveDoesNotInvalidateOrResurrectKitApproval() async throws {
    let storage = MemoryPersistence()
    let session = HabibiSession(store: HabibiStore(persistence: storage))
    #expect(await session.create(.init(name: "Noor", goals: ["health"], style: "warm")))
    session.newConversation(prompt: "Before review")
    await session.flushConversations()
    let durable = storage.document
    let definition: [String: Any] = ["apiVersion": 1, "name": "Walking", "description": "Track walks.",
        "fields": [["key": "minutes", "label": "Minutes", "type": "number", "unit": "min", "min": 0, "max": 600]],
        "source": "function summarize(s){return JSON.stringify({metrics:[]})}"]
    let tool = Task { try await session.executeTool("save_kit", arguments: ["definition": definition]) }
    for _ in 0..<200 {
        if session.review != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.review != nil)
    session.composer = "Edited while reviewing"
    await session.flushConversations()
    #expect(storage.document == durable)
    let interrupted = HabibiSession(store: HabibiStore(persistence: storage))
    await interrupted.start()
    #expect(interrupted.review == nil)
    #expect(interrupted.snapshot?.kits.isEmpty == true)
    session.resolveReview(true)
    let result = try await tool.value as? [String: Any]
    #expect(result?["approved"] as? Bool == true)
    await session.flushConversations()
    let restored = HabibiSession(store: HabibiStore(persistence: storage))
    await restored.start()
    #expect(restored.snapshot?.kits.count == 1)
    restored.openConversation(try #require(session.activeConversationID))
    #expect(restored.composer == "Edited while reviewing")
}

@MainActor
@Test func inlineKitEntriesSavePrivatelyOnceAndRestoreTheirReceipt() async throws {
    let storage = MemoryPersistence()
    let session = HabibiSession(store: HabibiStore(persistence: storage))
    #expect(await session.create(.init(name: "Noor", goals: ["health"], style: "warm")))
    let definition: [String: Any] = ["apiVersion": 1, "name": "Sets", "description": "Workout sets.",
        "fields": [["key": "exercise", "label": "Exercise", "type": "text", "unit": "", "min": NSNull(), "max": NSNull()],
                   ["key": "reps", "label": "Repetitions", "type": "number", "unit": "reps", "min": 0, "max": 100]],
        "source": "function summarize(s){return JSON.stringify({metrics:[]})}"]
    let install = Task { try await session.executeTool("save_kit", arguments: ["definition": definition]) }
    for _ in 0..<200 {
        if session.review != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.review != nil)
    session.resolveReview(true)
    _ = try await install.value
    let kitID = try #require(session.snapshot?.kits.first?.id)
    session.newConversation()
    let conversationID = try #require(session.activeConversationID)
    let card = HabibiComponent(type: "kit_entry", version: 1,
        data: .init(title: "How many reps?", kitId: kitID, prefill: [.init(key: "exercise", value: .text("Squat"))]),
        actions: [.init(id: "save_entry", label: "Save set")], fallback: "Log a set.")
    let message = HabibiMessage(kind: "assistant", text: card.fallback, component: card)
    session.messages.append(message)
    await session.flushConversations()
    let before = storage.document
    let entry: [String: Any] = ["exercise": "PRIVATE LOCAL SET", "reps": 7]
    storage.rejectWrites = true
    await #expect(throws: (any Error).self) {
        try await session.submitKitEntry(conversationID: conversationID, messageID: message.id, values: entry)
    }
    #expect(storage.document == before)
    #expect(session.snapshot?.kits.first?.entries.isEmpty == true)
    #expect(session.messages.first?.entryId == nil)
    storage.rejectWrites = false
    try await session.submitKitEntry(conversationID: conversationID, messageID: message.id, values: entry)
    let receipt = try #require(session.messages.first?.entryId)
    #expect(session.snapshot?.kits.first?.entries.count == 1)
    try await session.submitKitEntry(conversationID: conversationID, messageID: message.id, values: ["exercise": "Changed retry", "reps": 11])
    #expect(session.snapshot?.kits.first?.entries.count == 1)
    session.composer = "Keep this draft after saving"
    await session.flushConversations()
    let restored = HabibiSession(store: HabibiStore(persistence: storage))
    await restored.start()
    restored.openConversation(conversationID)
    #expect(restored.messages.first?.entryId == receipt)
    #expect(restored.composer == "Keep this draft after saving")
    #expect(restored.snapshot?.kits.first?.entries.first?.values["reps"] == .number(7))
    #expect(!String(describing: restored.conversations[0].history).contains("PRIVATE LOCAL SET"))
    #expect(!String(decoding: storage.document!, as: UTF8.self).contains("PRIVATE LOCAL SET"))
    #expect(!restored.cloudConsent)
}

@Test func followingSurvivesLayoutChangesButNotReadingEarlierMessages() {
    let state = HabibiConversationScrollState()
    state.userScrolling = false
    #expect(!state.update(.init(height: 1400, bottom: 600, viewport: 600)))
    #expect(state.update(.init(height: 1700, bottom: 900, viewport: 600)))
    #expect(state.following)
    #expect(!state.update(.init(height: 1700, bottom: 600, viewport: 600)))
    state.userScrolling = true
    #expect(!state.update(.init(height: 1700, bottom: 850, viewport: 600)))
    #expect(!state.following)
    state.userScrolling = false
    #expect(!state.update(.init(height: 2050, bottom: 1200, viewport: 600)))
    #expect(!state.following)
    state.userScrolling = true
    #expect(!state.update(.init(height: 2050, bottom: 600, viewport: 600)))
    #expect(state.following)
    #expect(!HabibiScrollMetrics(height: 2050, bottom: 200, viewport: 600).atBottom)
    state.userScrolling = false
    #expect(state.update(.init(height: 2050, bottom: 600, viewport: 350)))
    #expect(state.following)
    state.editingEntry = true
    #expect(!state.following)
    #expect(!state.update(.init(height: 2050, bottom: 350, viewport: 350)))
    #expect(!state.update(.init(height: 2200, bottom: 500, viewport: 350)))
    #expect(!state.following)
    state.editingEntry = false
    #expect(!state.update(.init(height: 2200, bottom: 850, viewport: 600)))
    #expect(!state.following)
    #expect(!state.update(.init(height: 2200, bottom: 600, viewport: 600)))
    #expect(state.following)
}
