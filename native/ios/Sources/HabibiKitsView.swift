import SwiftUI

struct HabibiKitsView: View {
    @ObservedObject var session: HabibiSession

    var body: some View {
        List {
            Section {
                Text("Little tools, made for your life.").font(.headline)
                Text("Ask Habibi to build a workout log, calorie journal or something entirely your own. Each Kit has a name, a description and its own entries.")
                    .foregroundStyle(.secondary)
                Button("Make a Kit", systemImage: "sparkles") {
                    session.newConversation(prompt: "Help me make my own Kit.")
                }.disabled(session.chatRunning || session.review != nil)
                    .accessibilityIdentifier("habibi.kits.create")
            }
            Section("Your Kits") {
                if let kits = session.snapshot?.kits, !kits.isEmpty {
                    ForEach(kits) { kit in
                        NavigationLink { HabibiKitView(session: session, kitID: kit.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(kit.definition.name).font(.headline)
                                Text(kit.definition.description).font(.subheadline).foregroundStyle(.secondary)
                                Text("\(kit.entries.count) entries · Private on this device").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                } else {
                    ContentUnavailableView("Your first Kit starts with an idea", systemImage: "square.stack.3d.up",
                                           description: Text("Describe it in Conversations. You’ll review it before anything is saved."))
                }
            }
            if let draft = session.draft, let definition = try? decodeDefinition(draft) {
                Section("Unsaved draft") {
                    NavigationLink { HabibiDefinitionView(definition: definition) } label: {
                        Label(definition.name, systemImage: "doc")
                    }
                    Text("Only in memory. Ask Habibi to evaluate and save it.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Kits run locally in an isolated Wasm interpreter. They cannot access the network, your keys or other Kits. Only the host app saves entries. Public sharing is not available yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Kits")
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
