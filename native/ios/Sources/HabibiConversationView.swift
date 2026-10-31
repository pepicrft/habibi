// Conversation navigation and scrolling adapted from Tuist Atlas (9af36c01be).
// Copyright (c) from 2018 Tuist GmbH. MIT license: native/ATLAS_LICENSE.
import AVFoundation
import SwiftUI

struct HabibiConversationsView: View {
    @ObservedObject var session: HabibiSession

    var body: some View {
        NavigationStack(path: $session.conversationPath) {
            List {
                if session.conversations.isEmpty {
                    ContentUnavailableView("Your conversations with Habibi", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Start a conversation using the compose button above."))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    Section("Saved conversations") {
                        ForEach(session.conversations.reversed()) { conversation in
                            Button { session.openConversation(conversation.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(conversation.title).font(.headline).lineLimit(1)
                                    Text(conversation.messages.last?.text ?? (conversation.composer.isEmpty ? "A private space to begin." : conversation.composer))
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    Text(conversation.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(session.chatRunning && session.activeConversationID != conversation.id)
                        }
                    }
                }
                Section {
                    HabibiConversationSaveStatus(session: session)
                    Text("Messages, cards and drafts are encrypted in your local vault and included in encrypted recovery backups.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain).navigationTitle("Conversations")
            .navigationDestination(for: UUID.self) { _ in HabibiConversationView(session: session) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New conversation", systemImage: "square.and.pencil") { session.newConversation() }
                        .disabled(session.chatRunning || session.review != nil)
                        .accessibilityIdentifier("habibi.conversation.new")
                }
            }
        }
        .toolbar(session.conversationPath.isEmpty ? .visible : .hidden, for: .tabBar)
    }
}

struct HabibiConversationView: View {
    @ObservedObject var session: HabibiSession
    @StateObject private var voice: HabibiVoiceInput
    @StateObject private var scrolling = HabibiConversationScrollState()
    @State private var latestRequest = 0
    @State private var visibleMessageID: UUID?
    @State private var jumping = false
    @State private var consent = false
    @State private var details = false
    @State private var choosingCostume = false
    @State private var startingVoice: Task<Void, Never>?
    @State private var evidence: HabibiComponent?
    @State private var showingIdeas = false
    @State private var ideasPull: CGFloat = 0
    @State private var draggingConversation = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.habibiPalette) private var palette

    init(session: HabibiSession, voice: HabibiVoiceInput? = nil) {
        self.session = session
        _voice = StateObject(wrappedValue: voice ?? HabibiVoiceInput())
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 20) {
                        Label("Private · You and Habibi", systemImage: "lock")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                        if session.messages.isEmpty { welcome }
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(session.messages) { message in
                                messageRow(message).id(message.id)
                            }
                        }.scrollTargetLayout()
                        if session.chatRunning {
                            HStack(spacing: 10) {
                                HabibiHeartling(interactive: false, working: true, avatar: session.costume?.avatar).frame(width: 40, height: 40)
                                Text("Habibi is working…").font(.footnote).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine).accessibilityIdentifier("habibi.working")
                        }
                        Color.clear.frame(height: session.messages.isEmpty ? 1 : 56).id("latest")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: session.messages.isEmpty ? .top : .bottom)
                    .background {
                        if #unavailable(iOS 18.0) {
                            GeometryReader { content in
                                Color.clear.preference(key: HabibiScrollPreference.self, value: HabibiScrollMetrics(
                                    height: content.size.height,
                                    bottom: content.frame(in: .global).maxY - geometry.frame(in: .global).minY,
                                    viewport: geometry.size.height))
                            }
                        }
                    }
                }
                .scrollPosition(id: Binding(get: { scrolling.following || scrolling.editingEntry ? nil : visibleMessageID }, set: {
                    if !scrolling.following { visibleMessageID = $0 }
                }))
                .modifier(HabibiScrollObserver(update: { metrics in
                    if scrolling.userScrolling == true, metrics.bottom < metrics.viewport {
                        if draggingConversation, !showingIdeas, voice.phase == .idle, !scrolling.editingEntry {
                            ideasPull = metrics.viewport - metrics.bottom
                        }
                        // Rubber-banding past the end must not trigger an automatic scroll correction.
                        return
                    }
                    if scrolling.userScrolling == true { ideasPull = 0 }
                    if !jumping, scrolling.update(metrics), !session.messages.isEmpty { latestRequest += 1 }
                }, interaction: { userScrolling, dragging in
                    scrolling.userScrolling = userScrolling
                    draggingConversation = dragging
                    if !dragging { ideasPull = 0 }
                }, released: finishIdeasPull))
                .accessibilityIdentifier("habibi.conversation.messages")
                .task(id: latestRequest) {
                    await Task.yield()
                    guard !Task.isCancelled, scrolling.following, !scrolling.editingEntry, !jumping, !session.messages.isEmpty else { return }
                    reader.scrollTo("latest", anchor: .bottom)
                }
                .defaultScrollAnchor(session.messages.isEmpty ? .top : .bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.messages.last?.id, initial: true) { _, _ in
                    if scrolling.following { latestRequest += 1 }
                }
                .onChange(of: session.chatRunning) { _, _ in if scrolling.following { latestRequest += 1 } }
                .onChange(of: geometry.size.height) { _, _ in if scrolling.following { latestRequest += 1 } }
                .onChange(of: scrolling.following) { _, following in if following { visibleMessageID = nil } }
                .overlay(alignment: .bottom) {
                    if ideasPull > 0, !showingIdeas {
                        Label(ideasPull >= 72 ? "Release for ideas" : "Pull up for ideas", systemImage: "chevron.up")
                            .font(.caption.weight(.medium)).foregroundStyle(palette.muted)
                            .padding(.vertical, 12)
                            .offset(y: reduceMotion ? 0 : -min(ideasPull * 0.15, 12))
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("habibi.ideas.pull")
                    }
                }
                .accessibilityAction(named: "Show ideas", openIdeas)
                .overlay(alignment: .bottomTrailing) {
                    HabibiPromptNavigation(messages: session.messages, showsLatest: !scrolling.following) { target in
                        jumping = true
                        scrolling.following = target == nil
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                            if let target { reader.scrollTo(target, anchor: .top) }
                            else { reader.scrollTo("latest", anchor: .bottom) }
                        } completion: {
                            scrolling.following = target == nil
                            jumping = false
                            if scrolling.following { latestRequest += 1 }
                        }
                    }.padding()
                }
            }
        }
        .blur(radius: showingIdeas && !reduceTransparency ? 12 : 0)
        .allowsHitTesting(!showingIdeas)
        .accessibilityHidden(showingIdeas)
        .overlay {
            if showingIdeas {
                HabibiConversationIdeas(ideas: HabibiConversationIdea.suggestions(costume: session.costume, hasMessages: !session.messages.isEmpty),
                                        dismiss: closeIdeas) { prompt in
                    session.composer += (session.composer.isEmpty ? "" : "\n\n") + prompt
                    closeIdeas()
                }
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .background(palette.canvas)
        .navigationTitle("Habibi").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    if session.showsModelPicker {
                        Menu {
                            Picker("Model", selection: Binding(get: { session.modelOverride ?? "" }, set: { session.setConversationModel($0.isEmpty ? nil : $0) })) {
                                Text("Use default · \(session.modelName(session.defaultModel))").tag("")
                                if let model = session.modelOverride, !session.models.contains(where: { $0.id == model }) {
                                    Text(session.modelName(model)).tag(model)
                                }
                                ForEach(session.models) { model in
                                    Text(model.name).tag(model.id)
                                        .disabled(model.id == HabibiFoundationModels.id && session.onDeviceUnavailableReason != nil)
                                }
                            }
                        } label: {
                            Label("Model · \(session.modelName(session.conversationModel))", systemImage: "cpu")
                        }.disabled(!session.canChangeModel)
                    }
                    Button { choosingCostume = true } label: {
                        Label(session.costume.map { "Wearing \($0.name)" } ?? "Wear a skin", systemImage: "tshirt")
                    }.disabled(!session.canChangeCostume)
                        .accessibilityIdentifier("habibi.costume.conversation")
                    Button("Conversation details", systemImage: "info.circle") { details = true }
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 5) {
                            Text("Habibi").font(.headline)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        Text(session.showsModelPicker ? session.modelName(session.conversationModel) : session.inferenceName)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(minHeight: 44)
                }
                .foregroundStyle(palette.ink)
                .accessibilityLabel("Conversation options")
                .accessibilityValue("\(session.modelName(session.conversationModel)), \(session.modelOverride == nil ? "using default" : "this conversation only"), \(session.costume.map { "wearing \($0.name)" } ?? "no skin")")
                .accessibilityHint("Choose a model or skin, or view conversation details")
                .accessibilityIdentifier("habibi.model.conversation")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }.accessibilityIdentifier("habibi.keyboard.done")
            }
        }
        .sheet(isPresented: $choosingCostume) {
            NavigationStack {
                List {
                    Section {
                        Button("Just Habibi · No skin") { session.setConversationCostume(nil); choosingCostume = false }
                            .accessibilityIdentifier("habibi.costumes.take-off")
                        ForEach(session.wardrobe) { costume in
                            Button {
                                session.setConversationCostume(costume.definition); choosingCostume = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(costume.definition.name)
                                    Text(costume.definition.description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.disabled(!session.canChangeCostume)
                    Section {
                        NavigationLink("Open wardrobe") { HabibiCostumesView(session: session) }
                        Text("Applies to future replies in this conversation. Skins change the approach, not permissions. The selected name and instructions go to your chosen model when you send a message.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Wear a skin").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingCostume = false } } }
            }
        }
        .sheet(isPresented: $details) {
            NavigationStack {
                List {
                    Label(session.usesOnDeviceModel ? "On-device inference" : "What the inference provider receives", systemImage: "lock")
                    Text(session.usesOnDeviceModel
                         ? "Apple’s model processes messages and requested tool results on this device. No inference requests go to OpenAI or Habibi’s server. Connected service tools still contact their service when you ask to use them."
                         : "Messages, requested Kit definitions and synthetic tests go to the selected inference provider only after approval. When you ask to use connected GitHub tools, their sanitized read-only profile and public repository results are also shared with that provider. Saved Kit entries, vault keys and connection credentials are never included by tools.")
                    Text("Dictation runs on this device. Audio is never uploaded, and transcription never sends a message automatically.")
                    Text("The selected skin’s name and instructions also go to your chosen model. The rest of your wardrobe is not included.")
                    Text("Messages, tool results, cards and drafts are saved encrypted on this device and included in encrypted recovery backups. Continuing a restored conversation uses its text context with the selected model; tools and pending approvals are never replayed. Cloud inference requires approval.")
                    LabeledContent("Inference", value: session.inferenceName)
                    LabeledContent("Draft sync", value: session.draftSyncMessage)
                        .accessibilityIdentifier("habibi.drafts.status")
                }
                .navigationTitle("Conversation details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { details = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { evidence != nil }, set: { if !$0 { evidence = nil } })) {
            NavigationStack {
                ScrollView {
                    if let evidence, let data = try? JSONEncoder().encode(evidence) {
                        Text(String(decoding: data, as: UTF8.self)).font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled).padding()
                    }
                }
                .navigationTitle("Component data").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { evidence = nil } } }
            }
        }
        .alert(session.chatGPTConnected ? "Use your ChatGPT plan?" : "Use host inference?", isPresented: $consent) {
            Button("Allow for this session") { session.cloudConsent = true; send() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(session.chatGPTConnected ? "Habibi sends requests directly to OpenAI using your ChatGPT plan." : "The development proxy uses the host’s configured harness and inference provider.") Messages, the selected skin’s name and instructions, requested Kit definitions and synthetic tests are sent. When you ask to use connected GitHub tools, their sanitized read-only profile and public repository results are shared with that provider and saved in encrypted conversation history. Saved Kit entries, vault keys and connection credentials are never included by tools. Provider retention, terms and usage limits apply.")
        }
        .onDisappear { closeIdeas(); cancelVoice(); Task { await session.flushConversations() } }
        .onChange(of: session.activeConversationID) { _, _ in choosingCostume = false; closeIdeas() }
        .onChange(of: session.composer) { _, _ in if showingIdeas { closeIdeas() } }
        .onChange(of: voice.phase) { _, phase in if phase != .idle { closeIdeas() } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in closeIdeas() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.refreshOnDeviceAvailability() }
            if phase == .background || (phase == .inactive && voice.phase != .requesting) { closeIdeas(); cancelVoice() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in cancelVoice() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            HabibiHeartling(avatar: session.costume?.avatar).frame(width: 144, height: 144)
            Text("What’s on your mind?").font(.title2.weight(.semibold))
            Text(session.costume?.description ?? "A little tool, a new rhythm, or an idea you want to explore. Let’s make it yours.").foregroundStyle(.secondary)
            ForEach(session.costume.map { [$0.examplePrompt] } ?? ["Help me build a workout tracker.", "Make a gentle daily energy journal.", "I have an idea for my own Kit."], id: \.self) { prompt in
                Button {
                    session.composer += (session.composer.isEmpty ? "" : "\n\n") + prompt
                } label: {
                    HStack { Text(prompt).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.left") }
                        .font(.subheadline).padding(14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
            }
            if !session.inferenceConnected {
                Label(session.usesOnDeviceModel ? session.onDeviceUnavailableReason ?? "On-device model unavailable" : "Inference is not connected", systemImage: "network.slash")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("AI settings") { HabibiChatGPTView(session: session) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
    }

    @ViewBuilder private func messageRow(_ message: HabibiMessage) -> some View {
        if let component = message.component {
            if component.type == "kit_entry", let conversationID = session.activeConversationID {
                HabibiKitEntryCard(session: session, conversationID: conversationID, message: message, card: component,
                                   editingChanged: { scrolling.editingEntry = $0 })
                    .accessibilityIdentifier("habibi.message.\(message.id)")
            } else {
                HabibiComponentView(card: component) { action in evidence = session.componentSource(messageID: message.id, action: action) }
                    .accessibilityIdentifier("habibi.message.\(message.id)")
            }
        } else if message.kind == "tool" {
            DisclosureGroup {
                Text(message.detail ?? message.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            } label: {
                Label(message.text, systemImage: "wrench.and.screwdriver").font(.footnote).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                if message.kind == "user" { Spacer(minLength: 40) }
                VStack(alignment: message.kind == "user" ? .trailing : .leading, spacing: 5) {
                    if message.kind != "user" { Text("Habibi").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12) }
                    Text(message.text).textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 12)
                        .foregroundStyle(message.kind == "user" ? palette.onPrimary : palette.ink)
                        .background(message.kind == "user" ? palette.accent : palette.surface,
                                    in: RoundedRectangle(cornerRadius: 20))
                    if let reaction = message.reaction {
                        Text(reaction).font(.title3).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(palette.surface, in: Capsule())
                            .overlay { Capsule().strokeBorder(palette.accent.opacity(0.25)) }
                            .accessibilityLabel("Habibi reacted \(reaction)")
                            .accessibilityIdentifier("habibi.reaction.\(message.id)")
                    }
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
                }
                if message.kind != "user" { Spacer(minLength: 40) }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("habibi.message.\(message.id)")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !showingIdeas {
                if session.conversationSaveError != nil {
                    HabibiConversationSaveStatus(session: session)
                        .frame(maxWidth: .infinity, alignment: .leading).background(palette.canvas)
                }
                if !session.otherDrafts.isEmpty {
                    Menu("Other draft versions (\(session.otherDrafts.count))") {
                        ForEach(session.otherDrafts, id: \.self) { text in
                            Button(String(text.prefix(80))) { Task { await session.selectDraftVersion(text) } }
                        }
                    }
                    .accessibilityHint("Switch drafts without sending. Both versions stay saved.")
                    .accessibilityIdentifier("habibi.drafts.versions")
                }
                if session.usesOnDeviceModel, let reason = session.onDeviceUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("habibi.model.unavailable")
                }
                if let error = voice.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("habibi.voice.error") }
            }
            if session.composer.count > 4000 { Text("Keep your message under 4,000 characters.").font(.caption).foregroundStyle(.red) }
            HabibiComposer(draft: $session.composer, connected: session.inferenceConnected && !session.connectingChatGPT, running: session.chatRunning,
                           phase: voice.phase, levels: voice.levels, start: {
                startingVoice = Task { await voice.start() }
            }, stop: {
                startingVoice?.cancel()
                voice.finish { session.composer = HabibiVoiceInput.appending($0, to: session.composer) }
            }, cancel: cancelVoice, send: {
                if !session.requiresCloudConsent || session.cloudConsent { send() } else { consent = true }
            }, stopReply: session.stop)
        }
        .frame(maxWidth: 688).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10).frame(maxWidth: .infinity)
        .background(palette.canvas)
    }

    private func finishIdeasPull() {
        let shouldOpen = ideasPull >= 72
        withAnimation(reduceMotion ? nil : .snappy) { ideasPull = 0 }
        if shouldOpen { openIdeas() }
    }

    private func openIdeas() {
        guard voice.phase == .idle, !scrolling.editingEntry else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { showingIdeas = true }
    }

    private func closeIdeas() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { showingIdeas = false; ideasPull = 0 }
    }

    private func send() { scrolling.following = true; latestRequest += 1; session.send() }
    private func cancelVoice() { startingVoice?.cancel(); voice.cancel() }
}

private struct HabibiConversationSaveStatus: View {
    @ObservedObject var session: HabibiSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = session.conversationSaveError {
                Text(error).foregroundStyle(.red)
                Button("Retry saving") { Task { await session.flushConversations() } }
                    .accessibilityIdentifier("habibi.conversations.retry")
            } else {
                Label(session.conversationsSaved ? "Saved encrypted on this device" : "Saving conversations…",
                      systemImage: session.conversationsSaved ? "lock" : "clock")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(session.conversationsSaved ? "habibi.conversations.saved" : "habibi.conversations.saving")
            }
        }.font(.caption)
    }
}

private struct HabibiPromptNavigation: View {
    let messages: [HabibiMessage]
    let showsLatest: Bool
    let jump: (UUID?) -> Void
    @State private var showing = false
    @State private var pending: UUID?
    private var prompts: [HabibiMessage] { messages.filter { $0.kind == "user" } }

    var body: some View {
        if !prompts.isEmpty {
            HStack(spacing: 0) {
                Button { showing = true } label: {
                    Image(systemName: "list.bullet").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Conversation prompts").accessibilityIdentifier("habibi.prompts")
                if showsLatest {
                    Divider().frame(height: 20)
                    Button { jump(nil) } label: {
                        Image(systemName: "arrow.down").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Latest messages").accessibilityIdentifier("habibi.latest")
                }
            }
            .buttonStyle(.plain).background(.regularMaterial, in: Capsule()).overlay { Capsule().strokeBorder(.primary.opacity(0.12)) }
            .sheet(isPresented: $showing, onDismiss: {
                if let pending { self.pending = nil; jump(pending) }
            }) {
                NavigationStack {
                    List(prompts) { prompt in
                        Button { pending = prompt.id; showing = false } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(prompt.text).lineLimit(2).multilineTextAlignment(.leading)
                                Text(prompt.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityHint("Jump to this message")
                        .accessibilityIdentifier("habibi.prompt.\(prompt.id)")
                    }
                    .navigationTitle("Prompts").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showing = false } } }
                }.presentationDetents([.medium, .large])
            }
        }
    }
}

private struct HabibiScrollPreference: PreferenceKey {
    static var defaultValue: HabibiScrollMetrics? { nil }
    static func reduce(value: inout HabibiScrollMetrics?, nextValue: () -> HabibiScrollMetrics?) { value = nextValue() }
}

private struct HabibiScrollObserver: ViewModifier {
    let update: (HabibiScrollMetrics) -> Void
    let interaction: (Bool?, Bool) -> Void
    let released: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: HabibiScrollMetrics.self) { geometry in
                let inset = geometry.contentInsets.top + geometry.contentInsets.bottom
                return HabibiScrollMetrics(height: geometry.contentSize.height,
                                           bottom: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.contentOffset.y,
                                           viewport: geometry.containerSize.height + inset, inset: inset)
            } action: { _, metrics in update(metrics) }
                .onScrollPhaseChange { previous, phase in
                    if previous == .interacting && phase != .interacting { released() }
                    interaction(phase == .interacting || phase == .decelerating, phase == .interacting)
                }
                .onAppear { interaction(false, false) }
        } else {
            content.onPreferenceChange(HabibiScrollPreference.self) { if let metrics = $0 { update(metrics) } }
                .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in interaction(true, true) }.onEnded { _ in
                    released(); interaction(nil, false)
                })
        }
    }
}
