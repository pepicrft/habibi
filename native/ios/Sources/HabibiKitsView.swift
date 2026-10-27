import SwiftUI

struct HabibiKitsView: View {
    @ObservedObject var session: HabibiSession
    @Environment(\.habibiPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var bundled: [HabibiBundledKit]?
    @State private var bundledError = false
    @State private var search = ""
    @State private var filter = "All"
    @State private var selectedKit: HabibiBundledKit?
    @State private var now = Date()
    @FocusState private var searching: Bool

    private var deadlines: [Int64] { (session.snapshot?.connections ?? []).compactMap(\.expiresAt).sorted() }

    private func connectedIDs(at date: Date) -> Set<String> {
        Set((session.snapshot?.connections ?? []).filter { !$0.expired(at: date) }.map(\.kitId))
    }
    private func connections(at date: Date) -> [HabibiBundledKit] {
        (bundled ?? []).filter {
            filter != "Personal" && (filter != "Connected" || connectedIDs(at: date).contains($0.id)) && matches($0.name, $0.description)
        }
    }
    private var personal: [HabibiKit] {
        (session.snapshot?.kits ?? []).filter {
            (filter == "All" || filter == "Personal") && matches($0.definition.name, $0.definition.description)
        }
    }

    private func matches(_ name: String, _ description: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "\(name) \(description)".localizedStandardContains(query)
    }

    var body: some View {
        // Wake only at token deadlines so an open catalog never counts an
        // expired connection as connected. No polling or network requests.
        catalog(at: now).task(id: deadlines) {
            now = Date()
            for expiry in deadlines where Double(expiry) > now.timeIntervalSince1970 {
                do { try await Task.sleep(for: .seconds(max(0, Double(expiry) - Date().timeIntervalSince1970))) }
                catch { return }
                guard !Task.isCancelled else { return }
                now = max(Date(), Date(timeIntervalSince1970: Double(expiry)))
            }
        }
    }

    private func catalog(at date: Date) -> some View {
        let connections = connections(at: date)
        let connectedCount = (bundled ?? []).filter { connectedIDs(at: date).contains($0.id) }.count
        return List {
            Section {
                Group {
                    if typeSize.isAccessibilitySize { scopes.pickerStyle(.menu) }
                    else { scopes.pickerStyle(.segmented) }
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            } header: {
                Text("Connect your apps. Make something your own.")
                    .font(.subheadline).textCase(nil).padding(.bottom, 12)
            }
            if filter != "Personal" {
                Section(filter == "Connected" ? "Connected services" : "Connections") {
                    if bundledError {
                        Text("Bundled connections are unavailable. Reopen Kits to try again.").foregroundStyle(.secondary)
                    } else if bundled == nil { ProgressView("Loading bundled Kits…") }
                    ForEach(connections) { kit in
                        let connection = session.snapshot?.connections?.first { $0.kitId == kit.id }
                        Button { searching = false; selectedKit = kit } label: {
                            HStack(spacing: 12) {
                                HabibiKitIcon(github: true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(kit.name).font(.headline).foregroundStyle(palette.ink)
                                    Text(kit.description).font(.subheadline).foregroundStyle(palette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let connection {
                                        Text(connection.expired(at: date) ? "Reconnect needed" : "Connected").font(.caption).foregroundStyle(palette.muted)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.muted)
                            }
                            .padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("habibi.kits.bundled.github")
                    }
                }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            }
            if !personal.isEmpty {
                Section("Personal") {
                    ForEach(personal) { kit in
                        NavigationLink { HabibiKitView(session: session, kitID: kit.id) } label: {
                            HStack(spacing: 12) {
                                HabibiKitIcon()
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(kit.definition.name).font(.headline).foregroundStyle(palette.ink)
                                    Text(kit.definition.description).font(.subheadline).foregroundStyle(palette.muted)
                                    Text("\(kit.entries.count) entries · Personal Kit").font(.caption).foregroundStyle(palette.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 8)
                        }
                    }
                }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            }
            if connections.isEmpty && personal.isEmpty && (bundled != nil || filter == "Personal") {
                Section {
                    ContentUnavailableView(
                        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Kits found" : filter == "Connected" ? "No connected Kits" : "Your first Kit starts with an idea",
                        systemImage: search.isEmpty ? "square.stack.3d.up" : "magnifyingglass",
                        description: Text(search.isEmpty ? "Explore connections or make a personal Kit with Habibi." : "Try another name or description."))
                        .accessibilityIdentifier("habibi.kits.empty")
                }.listRowBackground(Color.clear)
            }
            if let draft = session.draft, let definition = try? decodeDefinition(draft) {
                Section {
                    NavigationLink { HabibiDefinitionView(definition: definition) } label: {
                        Label(definition.name, systemImage: "doc")
                    }
                } header: { Text("Unsaved draft") }
                footer: { Text("Only in memory. Ask Habibi to evaluate and save it.") }
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            }
            Section {
                Button("Make a Kit", systemImage: "plus") {
                    searching = false
                    session.newConversation(prompt: "Help me make my own Kit.")
                }
                .frame(minHeight: 44)
                .disabled(session.chatRunning || session.review != nil).accessibilityIdentifier("habibi.kits.create")
            } header: { Text("Made for your everyday") }
            footer: {
                Text("A workout log, a reading journal, an idea of your own. Describe it to Habibi and review your Kit before saving.")
            }.listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            Section {
                Text("Personal Kits run privately on your device, without network or credential access. Connections let Habibi use authorized tools when you ask; requested results reach your inference provider, never credentials.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }.listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively).background(palette.canvas).navigationTitle("Kits")
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { filter = "Connected" } label: { Text("\(connectedCount) connected").font(.subheadline) }
                    .accessibilityIdentifier("habibi.kits.connected")
                    .accessibilityAddTraits(filter == "Connected" ? [.isSelected] : [])
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                TextField("Search Kits", text: $search, prompt: Text("Search Kits").foregroundStyle(palette.muted)).focused($searching)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.search)
                    .onSubmit { searching = false }.accessibilityIdentifier("habibi.kits.search")
                    .frame(minHeight: 44)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .foregroundStyle(palette.muted).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 7).background { HabibiGlassSurface() }
            .frame(maxWidth: 688).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $selectedKit) { kit in
            NavigationStack { HabibiGitHubView(session: session, kit: kit) }
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .task {
            do {
                let kits = try session.bundledKits()
                // Only offer the native implementation shipped in this app.
                bundled = kits.filter { $0.id == "github" && $0.permissions == ["read:user"] && $0.authentication == "device_code" }
                bundledError = false
            } catch { bundled = nil; bundledError = true }
        }
    }

    private var scopes: some View {
        Picker("Show Kits", selection: $filter) {
            ForEach(["All", "Connections", "Personal", "Connected"], id: \.self) { value in
                Text(value).tag(value).accessibilityIdentifier("habibi.kits.filter.\(value.lowercased())")
            }
        }
    }
}

struct HabibiKitIcon: View {
    var github = false
    var size: CGFloat = 48
    @Environment(\.habibiPalette) private var palette
    // Loose resources are bundled by Once, rather than an Xcode asset catalog.
    private static let githubMark = UIImage(contentsOfFile: Bundle.main.url(forResource: "github", withExtension: "png")!.path)!

    var body: some View {
        Group {
            if github {
                // Official mark: github.githubassets.com/images/modules/logos_page/GitHub-Mark.png
                Image(uiImage: Self.githubMark).renderingMode(.template).resizable().scaledToFit().padding(size * 0.18)
            } else {
                Image(systemName: "square.stack.3d.up").font(.system(size: size * 0.45))
            }
        }
        .foregroundStyle(palette.ink).frame(width: size, height: size)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: size * 0.25))
        .overlay { RoundedRectangle(cornerRadius: size * 0.25).stroke(palette.border) }
        .accessibilityHidden(true)
    }
}

struct HabibiKitView: View {
    @ObservedObject var session: HabibiSession
    let kitID: String
    @Environment(\.habibiPalette) private var palette
    @State private var metrics: [HabibiMetric] = []
    @State private var summaryError: String?
    @State private var adding = false
    @State private var removing = false
    @Environment(\.dismiss) private var dismiss
    private var kit: HabibiKit? { session.snapshot?.kits.first { $0.id == kitID } }

    var body: some View {
        Group {
            if let kit {
                List {
                    Section {
                        Text(kit.definition.description).foregroundStyle(.secondary)
                        Label("Private on this device", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("At a glance") {
                        ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                            LabeledContent(metric.label) {
                                Text([metric.value, metric.unit].filter { !$0.isEmpty }.joined(separator: " "))
                                    .foregroundStyle(palette.ink).fontWeight(.semibold)
                            }
                        }
                        if let summaryError { Text(summaryError).font(.footnote).foregroundStyle(.red) }
                        else if metrics.isEmpty { Text("No metrics yet").foregroundStyle(.secondary) }
                    }
                    Section {
                        Button("Add entry", systemImage: "plus.circle.fill") { adding = true }
                            .accessibilityIdentifier("habibi.kit.add-entry")
                    }
                    Section("Entries · \(kit.entries.count)") {
                        if kit.entries.isEmpty { Text("Your first entry starts here.").foregroundStyle(.secondary) }
                        ForEach(kit.entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(kit.definition.fields) { field in
                                    HStack {
                                        Text(field.label).foregroundStyle(.secondary)
                                        Spacer()
                                        Text([entry.values[field.key]?.display ?? "", field.unit].filter { !$0.isEmpty }.joined(separator: " "))
                                    }
                                }
                            }.font(.subheadline).padding(.vertical, 6)
                        }
                    }
                    Section("Made by you") {
                        NavigationLink { HabibiDefinitionView(definition: kit.definition) } label: {
                            Label("Fields & JavaScript", systemImage: "curlybraces")
                        }
                        Button("Ask Habibi to update this Kit", systemImage: "sparkles") {
                            session.newConversation(prompt: "I want to update my Kit \(kit.definition.name) (id: \(kit.id)). Read it first and help me improve it without changing its fields.")
                        }.disabled(session.chatRunning || session.review != nil)
                        Button("Remove Kit", systemImage: "trash", role: .destructive) {
                            removing = true
                            Task {
                                defer { removing = false }
                                do {
                                    _ = try await session.executeTool("remove_kit", arguments: ["id": kitID])
                                    if self.kit == nil { dismiss() }
                                } catch { summaryError = error.localizedDescription }
                            }
                        }.disabled(removing || session.chatRunning)
                    }
                }
                .navigationTitle(kit.definition.name).navigationBarTitleDisplayMode(.inline)
                .task(id: "\(kit.entries.count):\(kit.definition.source)") {
                    do {
                        let result = try await session.store.call("summary", arguments: ["id": kitID, "today": habibiDay()])
                        metrics = try JSONDecoder().decode([HabibiMetric].self, from: JSONSerialization.data(withJSONObject: result["metrics"] ?? []))
                        summaryError = nil
                    } catch { metrics = []; summaryError = error.localizedDescription }
                }
                .sheet(isPresented: $adding) { HabibiEntryView(session: session, kit: kit) }
            } else {
                ContentUnavailableView("This Kit was removed", systemImage: "square.stack.3d.up")
            }
        }
    }
}

struct HabibiEntryView: View {
    @ObservedObject var session: HabibiSession
    let kit: HabibiKit
    @State private var values: [String: String] = [:]
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(kit.definition.name) {
                    ForEach(kit.definition.fields) { field in
                        if field.type == "date" {
                            DatePicker(field.label, selection: Binding(get: {
                                dayFormatter.date(from: values[field.key] ?? habibiDay()) ?? Date()
                            }, set: { values[field.key] = habibiDay($0) }), displayedComponents: .date)
                                .accessibilityIdentifier("habibi.field.\(field.key)")
                        } else {
                            LabeledContent(field.unit.isEmpty ? field.label : "\(field.label) (\(field.unit))") {
                                TextField(field.label, text: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }))
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(field.type == "number" ? .numbersAndPunctuation : .default)
                                    .accessibilityIdentifier("habibi.field.\(field.key)")
                            }
                        }
                    }
                }
                Section { Text("This entry is encrypted and saved locally. The inference provider does not receive it.").font(.footnote).foregroundStyle(.secondary) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Add entry").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving).accessibilityIdentifier("habibi.entry.save")
                }
            }.interactiveDismissDisabled(saving)
        }
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func save() {
        var entry: [String: Any] = [:]
        for field in kit.definition.fields {
            let text = (values[field.key] ?? (field.type == "date" ? habibiDay() : "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if field.type == "number" {
                guard let number = Double(text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")), number.isFinite else {
                    error = "Enter a number for \(field.label)."; return
                }
                entry[field.key] = number
            } else { entry[field.key] = text }
        }
        saving = true
        Task {
            defer { saving = false }
            do { _ = try await session.persist("add_entry", arguments: ["id": kit.id, "values": entry]); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

// Inputs come from the installed Kit, not model-provided field definitions.
// Editing is local view state; only an explicit save reaches the encrypted vault.
struct HabibiKitEntryCard: View {
    @ObservedObject var session: HabibiSession
    let conversationID: UUID
    let message: HabibiMessage
    let card: HabibiComponent
    let editingChanged: (Bool) -> Void
    @Environment(\.habibiPalette) private var palette
    @FocusState private var focusedField: String?
    @State private var values: [String: String] = [:]
    @State private var saving = false
    @State private var error: String?

    private var kit: HabibiKit? { session.snapshot?.kits.first { $0.id == card.data.kitId } }
    private var saved: Bool { message.entryId != nil }
    private var savedEntry: HabibiEntry? { kit?.entries.first { $0.id == message.entryId } }
    private var locked: Bool { saving || saved || session.busy || session.chatRunning || session.syncing || session.review != nil }
    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(card.data.title, systemImage: "square.stack.3d.up").font(.headline)
            if let kit, validPrefill(kit.definition) {
                Text(kit.definition.name).font(.subheadline).foregroundStyle(palette.muted)
                ForEach(kit.definition.fields) { field in
                    if saved {
                        LabeledContent(field.label, value: [savedEntry?.values[field.key]?.display ?? "—", field.unit].filter { !$0.isEmpty }.joined(separator: " "))
                    } else if field.type == "date" {
                        DatePicker(field.label, selection: Binding(get: {
                            dayFormatter.date(from: values[field.key] ?? habibiDay()) ?? Date()
                        }, set: { values[field.key] = habibiDay($0) }), displayedComponents: .date)
                            .accessibilityIdentifier("habibi.card.field.\(field.key)")
                    } else {
                        LabeledContent(field.unit.isEmpty ? field.label : "\(field.label) (\(field.unit))") {
                            TextField(field.label, text: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }), axis: .vertical)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(field.type == "number" ? .numbersAndPunctuation : .default)
                                .focused($focusedField, equals: field.key)
                                .accessibilityIdentifier("habibi.card.field.\(field.key)")
                        }.frame(minHeight: 40)
                    }
                }.disabled(locked)
                if saved {
                    Label("Saved privately", systemImage: "checkmark.shield.fill")
                        .font(.subheadline).foregroundStyle(palette.accent).accessibilityIdentifier("habibi.card.saved")
                } else {
                    Button { save(kit) } label: {
                        HStack { if saving { ProgressView().tint(palette.onPrimary) }; Text(card.actions.first?.label ?? "Save entry") }
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .foregroundStyle(palette.onPrimary)
                    }
                    .buttonStyle(.borderedProminent).disabled(locked)
                    .accessibilityIdentifier("habibi.card.save")
                    Text("Saved only when you tap. Your inputs are not sent to the model. Unsaved inputs are not backed up.")
                        .font(.caption).foregroundStyle(palette.muted)
                }
            } else {
                Text(card.fallback)
                Text("This card’s Kit is unavailable or its suggested values no longer match. Ask for a new card.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("habibi.card.error") }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(palette.border) }
        .accessibilityElement(children: .contain)
        .onChange(of: focusedField) { _, key in editingChanged(key != nil) }
        .onDisappear { if focusedField != nil { editingChanged(false) } }
        .onAppear {
            if values.isEmpty, let kit {
                for item in card.data.prefill ?? [] {
                    switch item.value {
                    case .text(let text): values[item.key] = text
                    case .number(let number): values[item.key] = String(number)
                    }
                }
                for field in kit.definition.fields where field.type == "date" && values[field.key] == nil { values[field.key] = habibiDay() }
            }
        }
    }

    private func validPrefill(_ definition: HabibiDefinition) -> Bool {
        (card.data.prefill ?? []).allSatisfy { item in
            guard let field = definition.fields.first(where: { $0.key == item.key }) else { return false }
            switch (field.type, item.value) {
            case ("text", .text(let text)): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 500
            case ("date", .text(let text)): return dayFormatter.date(from: text).map { habibiDay($0) == text } ?? false
            case ("number", .number(let number)):
                return number.isFinite && abs(number) <= 1e9 && number >= (field.min ?? -1e9) && number <= (field.max ?? 1e9)
            default: return false
            }
        }
    }

    private func save(_ kit: HabibiKit) {
        guard !locked else { return }
        var entry: [String: Any] = [:]
        for field in kit.definition.fields {
            let text = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if field.type == "number" {
                guard let number = Double(text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")), number.isFinite else {
                    error = "Enter a number for \(field.label)."; return
                }
                entry[field.key] = number
            } else { entry[field.key] = text }
        }
        saving = true
        Task {
            defer { saving = false }
            do { try await session.submitKitEntry(conversationID: conversationID, messageID: message.id, values: entry); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct HabibiDefinitionView: View {
    let definition: HabibiDefinition
    var body: some View {
        List {
            Section { Text(definition.description) }
            Section("Fields · API v\(definition.apiVersion)") {
                ForEach(definition.fields) { field in
                    LabeledContent(field.label, value: [field.type, field.unit].filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
            Section("JavaScript · Isolated Wasm") {
                Text(definition.source).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }
        }.navigationTitle(definition.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct HabibiReviewView: View {
    @ObservedObject var session: HabibiSession
    let review: HabibiReview
    @Environment(\.habibiPalette) private var palette
    private var definition: HabibiDefinition? {
        (review.payload["definition"] as? [String: Any]).flatMap { try? decodeDefinition($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(review.removal ? "Remove this Kit?" : "A little tool, ready for you", systemImage: review.removal ? "trash" : "square.stack.3d.up")
                        .font(.headline)
                    Text(review.name).font(.title2.weight(.semibold))
                    if let definition { Text(definition.description).foregroundStyle(.secondary) }
                }
                if review.removal {
                    Section {
                        Text("This permanently removes the Kit and its \(review.payload["entryCount"] as? Int ?? 0) saved entries from your local vault. This cannot be undone.")
                    }
                } else if let definition {
                    Section("What it stores") {
                        ForEach(definition.fields) { field in LabeledContent(field.label, value: field.type) }
                    }
                    Section {
                        Label("Runs locally in isolated Wasm", systemImage: "lock.shield")
                        Text("No network, files or access to other Kits. Only this app can save entries. Updates preserve your existing entries and cannot change these fields.")
                            .font(.footnote).foregroundStyle(.secondary)
                        NavigationLink("Review JavaScript") { HabibiDefinitionView(definition: definition) }
                    }
                }
            }
            .navigationTitle(review.removal ? "Review removal" : "Review Kit").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.resolveReview(false) } } }
            .safeAreaInset(edge: .bottom) {
                Button(review.removal ? "Remove Kit & entries" : "Save Kit", role: review.removal ? .destructive : nil) {
                    session.resolveReview(true)
                }
                .tint(review.removal ? .red : palette.accent)
                .foregroundStyle(review.removal ? .white : palette.onPrimary)
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .accessibilityIdentifier("habibi.review.approve").padding().background(.bar)
            }
        }
    }
}

private func decodeDefinition(_ object: [String: Any]) throws -> HabibiDefinition {
    try JSONDecoder().decode(HabibiDefinition.self, from: JSONSerialization.data(withJSONObject: object))
}
