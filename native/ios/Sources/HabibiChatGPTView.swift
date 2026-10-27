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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use your ChatGPT plan with Habibi. No API key needed.")
                    Text("With your approval, messages and tool results go to OpenAI. Vault keys, saved Kit entries and credentials stay private.")
                        .font(.footnote).foregroundStyle(palette.muted)
                }
                if session.chatGPTConnected {
                    Label("Connected to ChatGPT", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("habibi.chatgpt.connected")
                } else if session.connectingChatGPT {
                    if let code {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Enter this code in ChatGPT:").font(.subheadline)
                            Text(code).font(.title.monospaced().weight(.semibold))
                                .textSelection(.enabled).privacySensitive()
                                .accessibilityLabel("Sign-in code: \(code.map(String.init).joined(separator: " "))")
                        }
                        Button {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: code]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(900)])
                            UIApplication.shared.open(HabibiChatGPT.verificationURL)
                        } label: {
                            Text("Copy code & open ChatGPT").frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(palette.onPrimary)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("habibi.chatgpt.open")
                        Text("Return here after approving sign-in. This code expires in 15 minutes.")
                            .font(.footnote).foregroundStyle(palette.muted)
                    }
                    ProgressView(code == nil ? "Preparing sign-in…" : "Waiting for ChatGPT…")
                    Button("Cancel sign-in", role: .cancel) { authorization?.cancel() }
                        .foregroundStyle(palette.accent)
                } else {
                    Button {
                        error = nil; code = nil
                        authorization = Task {
                            defer { authorization = nil; code = nil }
                            do { try await session.connectChatGPT { code = $0 } }
                            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        }
                    } label: {
                        Text("Connect with ChatGPT").frame(maxWidth: .infinity, minHeight: 36)
                            .foregroundStyle(palette.onPrimary)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(session.chatRunning).accessibilityIdentifier("habibi.chatgpt.connect")
                }
            } header: {
                Text("ChatGPT · Experimental")
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).accessibilityIdentifier("habibi.chatgpt.error")
                }
            }
            Section {
                Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    .foregroundStyle(palette.accent)
                if session.chatGPTConnected {
                    Button("Disconnect ChatGPT", role: .destructive) {
                        Task {
                            do { try await session.disconnectChatGPT() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(session.chatRunning || session.connectingChatGPT)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Experimental connection. Your ChatGPT plan’s limits apply. Encrypted sync is separate.")
                    if session.chatGPTConnected {
                        Text("Disconnects this device only. Your vault and other ChatGPT sessions stay unchanged.")
                    }
                }.foregroundStyle(palette.muted)
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
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Label("Apple Foundation Models", systemImage: "iphone")
                Text(session.onDeviceUnavailableReason ?? "Available · Runs on this device. No account needed.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("habibi.model.availability")
            } header: {
                Text("On-device AI")
            } footer: {
                Text("Best for short conversations. Choose ChatGPT for complex Kit creation. Connected service tools still use the network.")
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
                    .frame(minHeight: 44)
                    .disabled(!session.canChangeModel)
                    .accessibilityIdentifier("habibi.model.default")
                } footer: {
                    Text("Used unless you choose another model from a conversation’s title menu. Apple’s model requires Apple Intelligence. ChatGPT models use your plan.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
        }
        .navigationTitle("AI provider").navigationBarTitleDisplayMode(.inline)
        .onAppear { session.refreshOnDeviceAvailability() }
    }
}
