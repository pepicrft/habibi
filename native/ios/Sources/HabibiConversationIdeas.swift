import SwiftUI

struct HabibiConversationIdea: Identifiable {
    let id: Int
    let symbol: String
    let title: String
    let detail: String
    let prompt: String

    static func suggestions(costume: HabibiCostumeDefinition?, hasMessages: Bool) -> [Self] {
        var ideas: [Self]
        if hasMessages {
            ideas = [
                .init(id: 0, symbol: "flag.checkered", title: "Find the next step",
                      detail: "Turn what we’ve discussed into one small, doable action.",
                      prompt: "Based on our conversation, what’s one small, practical next step I can take?"),
                .init(id: 1, symbol: "lightbulb", title: "See it another way",
                      detail: "Explore a different angle or something we might have missed.",
                      prompt: "Show me a different perspective on what we’ve discussed. What might we be missing?"),
                .init(id: 2, symbol: "list.bullet.clipboard", title: "Make it practical",
                      detail: "Bring the useful parts together in a simple checklist.",
                      prompt: "Turn the useful parts of our conversation into a short, practical checklist."),
                .init(id: 3, symbol: "square.stack.3d.up", title: "Make a little Kit",
                      detail: "Shape this conversation into a personal tool you can keep.",
                      prompt: "Could we turn something from this conversation into a simple personal Kit? Help me decide what it should do.")
            ]
        } else {
            ideas = [
                .init(id: 0, symbol: "square.stack.3d.up", title: "Make a little Kit",
                      detail: "A workout tracker, a daily journal, or a tool that’s just yours.",
                      prompt: "Help me build a simple workout tracker Kit."),
                .init(id: 1, symbol: "sun.horizon", title: "Make space for today",
                      detail: "Find a gentler rhythm with a small, realistic plan.",
                      prompt: "Help me make a gentle, realistic plan for today. Ask what’s on my plate first."),
                .init(id: 2, symbol: "lightbulb", title: "Follow your curiosity",
                      detail: "Pick something you’d love to understand and start small.",
                      prompt: "Help me learn something new. Ask what I’m curious about, then guide me one step at a time."),
                .init(id: 3, symbol: "leaf", title: "Take a little pause",
                      detail: "Check in with yourself, without needing to have an answer.",
                      prompt: "Help me reflect on how I’m feeling today. Start with one gentle question.")
            ]
        }
        if let costume {
            ideas[0] = .init(id: 0, symbol: "tshirt", title: "Try \(costume.name)",
                             detail: costume.description, prompt: costume.examplePrompt)
        }
        return ideas
    }
}

struct HabibiConversationIdeas: View {
    let ideas: [HabibiConversationIdea]
    let dismiss: () -> Void
    let select: (String) -> Void
    @State private var selectedID: Int? = 0
    @ScaledMetric(relativeTo: .body) private var cardHeight = 232
    @ScaledMetric(relativeTo: .headline) private var headingHeight = 56
    @Environment(\.habibiPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let height = min(cardHeight, max(120, geometry.size.height - headingHeight - 84))
            ZStack(alignment: .bottom) {
                palette.canvas.opacity(reduceTransparency ? 1 : 0.55)
                    .contentShape(Rectangle()).onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("A little inspiration").font(.headline).fixedSize(horizontal: false, vertical: true)
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text("Choose an idea. Make it yours.").font(.caption).foregroundStyle(palette.muted)
                            }
                        }
                        Spacer()
                        Button(action: dismiss) {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(palette.surface, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel("Close ideas")
                            .accessibilityIdentifier("habibi.ideas.close")
                    }.padding(.horizontal, 24).frame(height: headingHeight)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(ideas) { idea in
                                ScrollView(.vertical) {
                                    Button { select(idea.prompt) } label: {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Image(systemName: idea.symbol)
                                                .font(.system(size: 42, weight: .medium))
                                                .foregroundStyle(palette.accent)
                                                .frame(height: 54).accessibilityHidden(true)
                                            Text(idea.title).font(.title3.weight(.semibold)).foregroundStyle(palette.ink)
                                            Text(idea.detail).font(.subheadline).foregroundStyle(palette.muted)
                                            Label("Add to draft", systemImage: "arrow.up.left")
                                                .font(.caption.weight(.medium)).foregroundStyle(palette.accent)
                                        }
                                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(22).frame(minHeight: height, alignment: .topLeading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Adds editable text to your draft. Nothing is sent.")
                                    .accessibilityIdentifier("habibi.idea.\(idea.id)")
                                }
                                .frame(width: min(360, geometry.size.width - 72))
                                .background(palette.surface, in: RoundedRectangle(cornerRadius: 24))
                                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(palette.border.opacity(0.7)) }
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                                .id(idea.id)
                            }
                        }.scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 24, for: .scrollContent)
                    .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $selectedID)
                    .frame(height: height)
                    .accessibilityIdentifier("habibi.ideas.carousel")
                    HStack(spacing: 0) {
                        ForEach(ideas) { idea in
                            Button {
                                withAnimation(reduceMotion ? nil : .snappy) { selectedID = idea.id }
                            } label: {
                                Circle().fill(palette.ink.opacity(selectedID == idea.id ? 1 : 0.2))
                                    .frame(width: 6, height: 6).frame(width: 28, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Idea \(idea.id + 1) of \(ideas.count)")
                            .accessibilityAddTraits(selectedID == idea.id ? .isSelected : [])
                        }
                    }
                }
                .padding(.bottom, 8).frame(maxWidth: 688)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            .foregroundStyle(palette.ink)
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                if !dynamicTypeSize.isAccessibilitySize, value.translation.height > 60,
                   value.translation.height > abs(value.translation.width) { dismiss() }
            })
            .accessibilityAction(.escape, dismiss)
        }
    }
}
