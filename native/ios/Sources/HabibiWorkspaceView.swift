import SwiftUI
import UniformTypeIdentifiers

struct HabibiWorkspaceView: View {
    @ObservedObject var session: HabibiSession
    @Environment(\.habibiPalette) private var palette

    var body: some View {
        TabView(selection: $session.selectedTab) {
            NavigationStack { home }.tabItem { Label("Home", systemImage: "house") }.tag(0)
            HabibiConversationsView(session: session)
                .tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }.tag(1)
            NavigationStack { profile }.tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(2)
        }
        .disabled(session.syncing)
    }

    private var home: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HabibiHeartling().frame(width: 112, height: 112)
                    Text("Good to have you here, \(session.snapshot?.profile.name ?? "friend").")
                        .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("A place for the little things that make life feel more like yours.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section("Make something yours") {
                Button {
                    session.newConversation(prompt: "Help me build a simple workout tracker Kit.")
                } label: { Label("Make a workout tracker", systemImage: "figure.strengthtraining.traditional") }
                Button {
                    session.newConversation(prompt: "Help me make a calorie journal Kit.")
                } label: { Label("Create a calorie journal", systemImage: "fork.knife") }
                Button {
                    session.newConversation(prompt: "I have an idea for my own Kit.")
                } label: { Label("Start with your own idea", systemImage: "sparkles") }
            }.disabled(session.chatRunning || session.review != nil)
            if let snapshot = session.snapshot, !snapshot.kits.isEmpty {
                Section("Your Kits") {
                    ForEach(snapshot.kits) { kit in
                        NavigationLink { HabibiKitView(session: session, kitID: kit.id) } label: {
                            Label(kit.definition.name, systemImage: "square.stack.3d.up")
                        }
                    }
                }
            }
            Section {
                Label("Encrypted on this device", systemImage: "lock.shield").foregroundStyle(.secondary)
                Text("Make a recovery backup in Profile. Connect encrypted sync there to copy ciphertext between devices.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .background(palette.canvas)
        .navigationTitle("Home")
    }

    private var profile: some View {
        List {
            if let profile = session.snapshot?.profile {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(palette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.headline)
                            Text("Your private space").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    NavigationLink { HabibiPersonalizationView(session: session, profile: profile) } label: {
                        Label("Personalization", systemImage: "slider.horizontal.3")
                    }
                }
            }
            Section {
                NavigationLink { HabibiChatGPTView(session: session) } label: {
                    Label("AI provider", systemImage: "sparkles")
                }.accessibilityIdentifier("habibi.profile.provider")
                NavigationLink { HabibiAppearanceView(session: session) } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }.accessibilityIdentifier("habibi.profile.appearance")
                NavigationLink { HabibiKitsView(session: session) } label: {
                    Label("Kits", systemImage: "square.stack.3d.up")
                }.accessibilityIdentifier("habibi.profile.kits")
                NavigationLink { HabibiCostumesView(session: session) } label: {
                    Label("Costumes", systemImage: "tshirt")
                }.accessibilityIdentifier("habibi.profile.costumes")
                NavigationLink { HabibiRecoveryView(session: session) } label: {
                    Label("Recovery backup", systemImage: "key")
                }
                NavigationLink { HabibiSyncView(session: session) } label: {
                    Label("Encrypted sync", systemImage: "lock.icloud")
                }.accessibilityIdentifier("habibi.profile.sync")
                NavigationLink { privacy } label: { Label("Privacy & storage", systemImage: "lock.shield") }
            }
            Section {
                LabeledContent("Version", value: "0.1.0 · Development")
            }
        }.background(palette.canvas).navigationTitle("Profile")
    }

    private var privacy: some View {
        List {
            Section("Your private key") {
                Text("Rust generates a random 256-bit encryption key on your device. The key is stored in this device’s Keychain, separately from a distinct sync token. Neither is an account password.")
            }
            Section("Encrypted local storage") {
                Text("Your name, interests, Kit code, entries and conversations are inside an authenticated AES-256-GCM/HKDF encrypted vault. Optional sync sends only encrypted snapshots to Habibi’s server, plus opaque IDs, sizes, digests and sequence numbers. Your content key never leaves this device except inside your separately encrypted recovery backup.")
                Text("This prototype has not had an independent security audit. Use fictional data for now. Device compromise and malicious app updates are outside the encryption boundary.")
            }
            Section("When you ask a cloud model") {
                Text("Your messages, requested Kit definitions and synthetic test results are shared with the selected inference provider only after approval. When you ask to use connected GitHub tools, their sanitized read-only profile and public repository results are also shared with the conversation’s provider and saved in encrypted conversation history. Connecting or checking GitHub alone does not share account data with the provider. Saved Kit entries, vault keys and connection credentials are never included by tools. Personal information you type in a message is still disclosed.")
            }
        }.background(palette.canvas).navigationTitle("Privacy & storage").navigationBarTitleDisplayMode(.inline)
    }
}

struct HabibiPersonalizationView: View {
    @ObservedObject var session: HabibiSession
    @State var profile: HabibiProfile
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Your name") { TextField("Name or nickname", text: $profile.name) }
            HabibiInterestFields(profile: $profile)
            Section { Text("These preferences stay in your encrypted vault. They are not automatically sent to an inference provider.").foregroundStyle(.secondary) }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Personalization").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
                            _ = try await session.persist("profile", arguments: ["profile": object])
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(saving || profile.goals.isEmpty)
            }
        }
    }
}

struct HabibiBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct HabibiRecoveryView: View {
    @ObservedObject var session: HabibiSession
    @State private var backup: Data?
    @State private var key = ""
    @State private var exporting = false
    @State private var showingKey = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Two things to keep safe").font(.headline)
                Text("Save the encrypted backup file and keep its recovery key in a different safe place, such as your password manager. Anyone with both can read your vault.")
                Text("This is a point-in-time backup. Create a new one after important changes. Habibi cannot reset a lost key.")
            }
            if backup != nil {
                Section("1. Encrypted backup") {
                    Button("Save backup file", systemImage: "square.and.arrow.up") { exporting = true }
                }
                Section("2. Separate recovery key") {
                    Button(showingKey ? "Hide recovery key" : "Show recovery key") { showingKey.toggle() }
                    if showingKey { Text(key).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).privacySensitive() }
                    Button("Copy recovery key for 60 seconds") {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
                    }
                    Text("The key is not inside the backup file. Do not store or share them together.").font(.footnote).foregroundStyle(.secondary)
                }
            } else { Section { ProgressView("Preparing encrypted backup…") } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Recovery backup").navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let result = try await session.exportRecovery()
                backup = try JSONSerialization.data(withJSONObject: result["backup"] ?? [:], options: [.sortedKeys])
                key = result["recoveryKey"] as? String ?? ""
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { key = ""; backup = nil; showingKey = false }
        .fileExporter(isPresented: $exporting, document: backup.map(HabibiBackupFile.init), contentType: .json,
                      defaultFilename: "habibi-encrypted-backup") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }
}
