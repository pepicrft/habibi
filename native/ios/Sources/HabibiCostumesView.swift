import SwiftUI
import UniformTypeIdentifiers

struct HabibiCostumesView: View {
    @ObservedObject var session: HabibiSession
    @State private var catalog: [HabibiCostumeDefinition] = []
    @State private var draft: HabibiCostumeDefinition?
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    HabibiHeartling().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Still your Habibi.").font(.headline)
                        Text("Different ways to help. Try on a skin, then keep the ones that feel like you.")
                            .foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Your wardrobe") {
                if session.wardrobe.isEmpty {
                    Text("Your wardrobe is ready for its first skin.").foregroundStyle(.secondary)
                }
                ForEach(session.wardrobe) { costume in
                    NavigationLink {
                        HabibiCostumeDetail(session: session, definition: costume.definition, costumeID: costume.id)
                    } label: { row(costume.definition) }
                    .accessibilityIdentifier("habibi.costumes.saved.\(costume.id)")
                }
            }
            Section("Try something on") {
                ForEach(catalog) { definition in
                    NavigationLink { HabibiCostumeDetail(session: session, definition: definition) } label: { row(definition) }
                        .accessibilityIdentifier("habibi.costumes.bundled.\(definition.name)")
                }
            }
            Section {
                Button("Make a skin", systemImage: "plus") {
                    draft = HabibiCostumeDefinition(author: session.snapshot?.profile.name ?? "Me")
                }.accessibilityIdentifier("habibi.costumes.create")
                Button("Import a skin", systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("habibi.costumes.import")
                Text("Skins change Habibi’s approach, never its permissions. Your wardrobe is encrypted with your vault.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Skins")
        .toolbar(.hidden, for: .tabBar)
        .task { do { catalog = try HabibiCostumeDefinition.catalog() } catch { self.error = error.localizedDescription } }
        .sheet(item: $draft) { definition in
            NavigationStack { HabibiCostumeEditor(session: session, definition: definition) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 32 * 1024 + 1) ?? Data()
                guard data.count <= 32 * 1024 else { throw HabibiFailure(message: "Skin files must be smaller than 32 KiB.") }
                // Validate raw JSON first; Codable alone would discard unknown capability fields.
                let object = try JSONSerialization.jsonObject(with: data)
                let checked = try HabibiCore.execute(["operation": "validate_costume", "definition": object])
                draft = try JSONDecoder().decode(HabibiCostumeDefinition.self, from: JSONSerialization.data(withJSONObject: checked["definition"] ?? [:]))
            } catch { self.error = error.localizedDescription }
        }
    }

    private func row(_ definition: HabibiCostumeDefinition) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(definition.name, systemImage: "tshirt").font(.headline)
            Text(definition.description).font(.subheadline).foregroundStyle(.secondary)
            Text("By \(definition.author) · Author supplied").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}

private struct HabibiCostumeDetail: View {
    @ObservedObject var session: HabibiSession
    let definition: HabibiCostumeDefinition
    var costumeID: String?
    @State private var editing = false
    @State private var removing = false
    @State private var exporting = false
    @State private var exportData: Data?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var current: HabibiCostumeDefinition {
        session.wardrobe.first { $0.id == costumeID }?.definition ?? definition
    }

    var body: some View {
        List {
            Section {
                Label(current.name, systemImage: "tshirt").font(.title2.weight(.semibold))
                Text(current.description)
                Text("By \(current.author) · Author supplied, not verified").font(.caption).foregroundStyle(.secondary)
            }
            Section("How Habibi will help") { Text(current.instructions) }
            Section("Give it a try") {
                Text(current.examplePrompt).foregroundStyle(.secondary)
                Button("Try on", systemImage: "sparkles") {
                    session.newConversation(prompt: current.examplePrompt, costume: current)
                }.disabled(!session.canChangeCostume).accessibilityIdentifier("habibi.costumes.try")
                Text("Opens a separate conversation with an editable example. Nothing is sent until you tap Send; trying on does not add it to your wardrobe.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if costumeID != nil {
                    Button("Wear", systemImage: "tshirt") { session.newConversation(costume: current) }
                        .accessibilityIdentifier("habibi.costumes.wear")
                    Button("Edit skin", systemImage: "pencil") { editing = true }
                    Button("Export skin", systemImage: "square.and.arrow.up") {
                        do { exportData = try JSONEncoder().encode(current); exporting = true }
                        catch { self.error = error.localizedDescription }
                    }
                    Text("Exports the definition only, not conversations or memories. Review its text for personal information before sharing.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Remove from wardrobe", role: .destructive) { removing = true }
                } else {
                    Button("Add to wardrobe", systemImage: "plus") { editing = true }
                        .accessibilityIdentifier("habibi.costumes.add")
                }
                Text("Only the selected skin’s name and instructions join your model request. It cannot grant tools or data access. Existing conversations keep their own copy when you edit or remove a skin.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.disabled(!session.canChangeCostume)
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(current.name).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            NavigationStack { HabibiCostumeEditor(session: session, definition: current, costumeID: costumeID) }
        }
        .confirmationDialog("Remove this skin? Conversations keep their own copy.", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove from wardrobe", role: .destructive) {
                guard let costumeID else { return }
                Task {
                    do { try await session.removeCostume(costumeID); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportData.map(HabibiBackupFile.init), contentType: .json, defaultFilename: "habibi-skin") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
    }
}

private struct HabibiCostumeEditor: View {
    @ObservedObject var session: HabibiSession
    @State var definition: HabibiCostumeDefinition
    var costumeID: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("The skin") {
                TextField("Name", text: $definition.name).accessibilityIdentifier("habibi.costumes.name")
                TextField("Short description", text: $definition.description, axis: .vertical).lineLimit(2...4)
                TextField("Author (not verified)", text: $definition.author)
            }
            Section("How Habibi should help") {
                TextEditor(text: $definition.instructions).frame(minHeight: 160)
                    .accessibilityLabel("Skin instructions").accessibilityIdentifier("habibi.costumes.instructions")
                Text("Describe its approach, questions and habits. Up to 4,000 characters. No code, tools or permissions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Example to try on") {
                TextField("A starting prompt", text: $definition.examplePrompt, axis: .vertical).lineLimit(2...4)
            }
            Section {
                Text("Review every field before adding an imported skin. Author names are not verified. Its selected name and instructions are sent to your chosen model when you send a message. Never put secrets here.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(costumeID == nil ? "Add to wardrobe" : "Edit skin").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(costumeID == nil ? "Add" : "Save") {
                    Task {
                        do { try await session.saveCostume(definition, id: costumeID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(!session.canChangeCostume).accessibilityIdentifier("habibi.costumes.save")
            }
        }
    }
}
