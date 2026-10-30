import SwiftUI

struct HabibiChatGPTFields: View {
    @ObservedObject var session: HabibiSession
    @Environment(\.habibiPalette) private var palette
    @State private var code: String?
    @State private var authorization: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        Group {
            Section {
                if session.chatGPTConnected {
                    Label("Connected to ChatGPT", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("habibi.chatgpt.connected")
                } else if session.connectingChatGPT {
                    if let code {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your sign-in code").font(.subheadline)
                            Text(code).font(.title2.monospaced().weight(.semibold))
                                .textSelection(.enabled).privacySensitive()
                                .accessibilityLabel("Sign-in code: \(code.map(String.init).joined(separator: " "))")
                                .accessibilityIdentifier("habibi.chatgpt.code")
                        }
                        Button("Copy code and open ChatGPT", systemImage: "arrow.up.right.square") {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: code]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(900)])
                            UIApplication.shared.open(HabibiChatGPT.verificationURL, options: [:]) { opened in
                                if !opened { error = "Open auth.openai.com/codex/device in your browser and enter the code above." }
                            }
                        }
                        .foregroundStyle(palette.accent)
                        .accessibilityIdentifier("habibi.chatgpt.open")
                    }
                    ProgressView(code == nil ? "Preparing sign-in…" : "Waiting for ChatGPT…")
                    Button("Cancel sign-in", role: .cancel) { authorization?.cancel(); error = nil }
                        .foregroundStyle(palette.accent)
                        .accessibilityIdentifier("habibi.chatgpt.cancel")
                } else {
                    Button(error == nil ? "Connect with ChatGPT" : "Try again", systemImage: "person.crop.circle.badge.plus") {
                        error = nil; code = nil
                        authorization = Task {
                            defer { authorization = nil; code = nil }
                            do { try await session.connectChatGPT { code = $0 } }
                            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        }
                    }
                    .foregroundStyle(palette.accent)
                    .disabled(session.chatRunning).accessibilityIdentifier("habibi.chatgpt.connect")
                }
                if let error {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Sign-in needs attention", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                        Text(error).font(.subheadline).foregroundStyle(palette.muted)
                    }.accessibilityIdentifier("habibi.chatgpt.error")
                }
                DisclosureGroup("Connection privacy") {
                    Text("After your approval, messages, requested Kit code and tool results are sent to OpenAI. Tools don’t send saved Kit entries, vault keys or credentials. Anything you type in chat is still shared. ChatGPT credentials stay on this device and are not included in sync or recovery backups.")
                        .font(.footnote).foregroundStyle(palette.muted)
                }
            } header: {
                Text("ChatGPT")
            } footer: {
                if session.connectingChatGPT, code != nil {
                    Text("Enter the code at auth.openai.com/codex/device, approve sign-in, then return here. The code expires after 15 minutes.")
                        .foregroundStyle(palette.muted)
                } else {
                    Text("Experimental Codex connection. Account and model access can vary. Connecting doesn’t send messages or enable encrypted sync.")
                        .foregroundStyle(palette.muted)
                }
            }
            if session.snapshot != nil && session.chatGPTConnected {
                Section {
                    Link("Manage ChatGPT usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                        .foregroundStyle(palette.accent)
                    Button("Disconnect ChatGPT", role: .destructive) {
                        Task {
                            do { try await session.disconnectChatGPT() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(session.chatRunning || session.connectingChatGPT)
                } footer: {
                    Text("Disconnects this device only. Your vault and other ChatGPT sessions stay unchanged.")
                }
            }
        }
        .onDisappear { authorization?.cancel() }
        .onChange(of: error) { _, message in
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
        .onChange(of: session.chatGPTConnected) { _, connected in
            if connected { UIAccessibility.post(notification: .announcement, argument: "ChatGPT connected") }
        }
    }
}

struct HabibiChatGPTView: View {
    @ObservedObject var session: HabibiSession
    @Environment(\.habibiPalette) private var palette
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Apple Intelligence", systemImage: "iphone")
                    Text(session.onDeviceUnavailableReason ?? "Available. No account needed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("habibi.model.availability")
                }
                if session.onDeviceUnavailableReason != nil {
                    Button("Check availability", systemImage: "arrow.clockwise") { session.refreshOnDeviceAvailability() }
                        .foregroundStyle(palette.accent)
                        .accessibilityIdentifier("habibi.model.check")
                    Link("Apple Intelligence setup", destination: URL(string: "https://support.apple.com/en-us/121115")!)
                        .foregroundStyle(palette.accent)
                }
            } header: {
                Text("On-device AI")
            } footer: {
                Text("Runs on this device. Best for short conversations, not Kit code generation. Connected service tools still use the network.")
                    .foregroundStyle(palette.muted)
            }
            HabibiChatGPTFields(session: session)
            if session.snapshot != nil {
                Section {
                    Picker("Default model", selection: Binding(get: { session.defaultModel }, set: { model in
                        Task {
                            do { try await session.setDefaultModel(model) }
                            catch { self.error = error.localizedDescription }
                        }
                    })) {
                        if !session.models.contains(where: { $0.id == session.defaultModel }) {
                            Text(session.defaultModel).tag(session.defaultModel)
                        }
                        ForEach(session.models) { model in
                            Text(model.name).tag(model.id)
                                .disabled(model.id == HabibiFoundationModels.id && session.onDeviceUnavailableReason != nil)
                        }
                    }
                    .disabled(!session.canChangeModel)
                    .accessibilityIdentifier("habibi.model.default")
                } footer: {
                    Text("You can choose a different model in each conversation. ChatGPT model access depends on your account. Unavailable models never switch to a cloud provider automatically.")
                        .foregroundStyle(palette.muted)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
        }
        .background(palette.canvas)
        .navigationTitle("AI provider").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { session.refreshOnDeviceAvailability() }
    }
}
