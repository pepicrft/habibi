import SwiftUI
import UniformTypeIdentifiers

struct HabibiWelcomeView: View {
    @ObservedObject var session: HabibiSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.habibiPalette) private var palette
    @State private var creating = false
    @State private var restoring = false
    @State private var restarting = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    HabibiHeartling().frame(width: 160, height: 160).padding(.bottom, 16)
                    Text("Welcome to Habibi")
                        .font(.title.weight(.medium)).accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 12)
                    Text("A little help with life.\nA space that’s entirely yours.")
                        .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(palette.muted)
                        .padding(.horizontal, 24).padding(.bottom, 32)
                    Spacer(minLength: 32)
                    VStack(spacing: 16) {
                        Label("Private by design", systemImage: "lock.shield")
                            .font(.footnote).foregroundStyle(palette.muted)
                        Button { creating = true } label: {
                            Text("Create my Habibi").frame(maxWidth: .infinity, minHeight: 36)
                                .foregroundStyle(palette.onPrimary)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("habibi.create")
                        Button { restoring = true } label: {
                            Text("Restore a backup").frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("habibi.restore")
                        Text("No email. No password. Your private key stays on your device.")
                            .font(.footnote).multilineTextAlignment(.center).foregroundStyle(palette.muted)
                        if let error = session.error {
                            Text(error).font(.footnote).foregroundStyle(.red)
                            Button("Try again") { Task { await session.start() } }
                            if session.canRestartSetup {
                                Button("Discard orphaned key", role: .destructive) { restarting = true }
                            }
                        }
                    }
                    .frame(maxWidth: 512).padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                    .background {
                        UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32)
                            .fill(scheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.65))
                            .overlay {
                                UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32)
                                    .stroke(Color.white.opacity(scheme == .dark ? 0.1 : 0.9), lineWidth: 1)
                            }
                            .padding(.bottom, -geometry.safeAreaInsets.bottom)
                    }
                }.frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize).scrollIndicators(.hidden)
        }
        .foregroundStyle(palette.ink)
        .background { HabibiAtmosphere() }
        .sheet(isPresented: $creating) { HabibiOnboardingView(session: session) }
        .sheet(isPresented: $restoring) { HabibiRestoreView(session: session) }
        .confirmationDialog("Discard this device’s orphaned key?", isPresented: $restarting, titleVisibility: .visible) {
            Button("Discard key & restart setup", role: .destructive) {
                Task {
                    do { try await session.store.discardIncompleteSetup(); session.canRestartSetup = false; session.error = nil }
                    catch { session.error = error.localizedDescription }
                }
            }
        } message: {
            Text("There is a private key but no local vault file. This deletes that key permanently. Restore a backup instead if you have one. Any previous vault still requires its own backup and recovery key.")
        }
    }
}

struct HabibiOnboardingView: View {
    @ObservedObject var session: HabibiSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.habibiPalette) private var palette
    @State private var step = 0
    @State private var profile = HabibiProfile(name: "", goals: [], style: "warm")
    @State private var understood = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EmptyView()
                } header: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(step + 1) of 4").font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(["What should I call you?", "What matters to you?", "Connect ChatGPT", "Yours. And only yours."][step])
                            .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            .foregroundStyle(palette.ink)
                        Text(["A first name or nickname is perfect. This stays in your encrypted space.",
                              "Pick a few interests. You can change these any time in your profile.",
                              "Optional. You can connect later in Profile.",
                              "Habibi creates your private encryption key here, on this device."][step])
                            .font(.body).foregroundStyle(.secondary)
                    }.textCase(nil).padding(.vertical, 8)
                }
                if step == 0 {
                    Section("Your name") {
                        TextField("Name or nickname", text: $profile.name)
                            .textContentType(.nickname).submitLabel(.continue)
                            .accessibilityIdentifier("habibi.name")
                            .onSubmit { if !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { step = 1 } }
                    }
                } else if step == 1 {
                    HabibiInterestFields(profile: $profile)
                } else if step == 2 {
                    HabibiChatGPTFields(session: session)
                } else {
                    Section {
                        Label("Your key is protected by this device’s Keychain", systemImage: "key")
                        Label("Your personal details and Kits are encrypted", systemImage: "lock.shield")
                    } footer: {
                        Text("Encrypted sync is optional and separate. Habibi’s server receives encrypted content and account metadata, never your vault key.")
                    }
                    Section {
                        Text("Save a recovery backup from Profile and keep its recovery key separately. You need both to recover your data if you lose this device.")
                        Toggle("I understand how recovery works", isOn: $understood)
                            .accessibilityIdentifier("habibi.understood")
                    } footer: {
                        Text("Habibi cannot reset a lost key. This prototype is not independently audited; use fictional data for now.")
                    }
                }
                if let error = session.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("A little introduction").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == 0 ? "Cancel" : "Back") { if step == 0 { dismiss() } else { step -= 1 } }.disabled(session.busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Group {
                    if step == 2 && !session.chatGPTConnected {
                        Button("Skip for now") { step += 1 }
                            .buttonStyle(.borderless).foregroundStyle(palette.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Button {
                            if step < 3 { step += 1 }
                            else { Task { if await session.create(profile) { dismiss() } } }
                        } label: {
                            HStack {
                                if session.busy { ProgressView().tint(palette.onPrimary) }
                                Text(step < 3 ? "Continue" : "Create my private space")
                            }.frame(maxWidth: .infinity).foregroundStyle(palette.onPrimary)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
                .disabled(session.busy || (step != 2 && session.connectingChatGPT) || (step == 0 && profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                          || (step == 1 && profile.goals.isEmpty) || (step == 3 && !understood))
                .accessibilityIdentifier("habibi.continue")
                .padding().background(.bar)
            }
            .interactiveDismissDisabled(session.busy)
        }
    }
}

struct HabibiInterestFields: View {
    @Binding var profile: HabibiProfile

    var body: some View {
        Section("I’d like help with") {
            ForEach(HabibiProfile.interests, id: \.0) { interest in
                Toggle(isOn: Binding(get: { profile.goals.contains(interest.0) }, set: { enabled in
                    if enabled { profile.goals.append(interest.0) } else { profile.goals.removeAll { $0 == interest.0 } }
                })) { Label(interest.1, systemImage: interest.2) }
                    .accessibilityIdentifier("habibi.interest.\(interest.0)")
            }
        }
        Section("How should Habibi sound?") {
            Picker("Conversation style", selection: $profile.style) {
                Text("Warm & encouraging").tag("warm")
                Text("Clear & direct").tag("direct")
            }
        }
    }
}

struct HabibiRestoreView: View {
    @ObservedObject var session: HabibiSession
    @Environment(\.dismiss) private var dismiss
    @State private var backup = ""
    @State private var key = ""
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("You need your encrypted backup and its separate recovery key. Neither one is enough by itself.")
                    Text("Restoring replaces any inaccessible local vault with this backup’s contents. Changes made after the backup will not be recovered.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Choose backup file", systemImage: "doc") { importing = true }
                }
                Section("Encrypted backup JSON") {
                    TextEditor(text: $backup).frame(minHeight: 120).font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("habibi.backup")
                }
                Section("Separate recovery key") {
                    SecureField("Recovery key", text: $key).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("habibi.recovery-key")
                }
                if let error = session.error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Restore my private space") {
                        Task { if await session.recover(Data(backup.utf8), key: key) { key = ""; backup = ""; dismiss() } }
                    }.disabled(backup.isEmpty || key.isEmpty || session.busy)
                }
            }
            .navigationTitle("Restore a backup").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { key = ""; dismiss() }.disabled(session.busy) } }
            .interactiveDismissDisabled(session.busy)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 4 * 1024 * 1024 else { throw HabibiFailure(message: "This backup is too large.") }
                    backup = try String(contentsOf: url, encoding: .utf8)
                } catch { session.error = error.localizedDescription }
            }
        }
    }
}
