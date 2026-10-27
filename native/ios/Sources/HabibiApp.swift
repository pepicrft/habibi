import SwiftUI

@main
struct HabibiApp: App {
    @StateObject private var session = HabibiSession()
    @StateObject private var appearance = HabibiAppearance()

    var body: some Scene {
        WindowGroup { HabibiRootView(session: session, appearance: appearance) }
    }
}

private struct HabibiRootView: View {
    @ObservedObject var session: HabibiSession
    @ObservedObject var appearance: HabibiAppearance
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemScheme

    private var preferredScheme: ColorScheme? {
        switch session.snapshot?.profile.appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        let colors = appearance.catalog.theme(session.snapshot?.profile.theme).colors
        let palette = HabibiPalette(tokens: (preferredScheme ?? systemScheme) == .dark ? colors.dark : colors.light)
        return Group {
            Group {
                if !session.ready {
                    VStack(spacing: 12) {
                        HabibiHeartling(interactive: false, working: true).frame(width: 80, height: 80)
                        Text("Opening your private space…")
                    }
                }
                else if session.snapshot != nil { HabibiWorkspaceView(session: session) }
                else { HabibiWelcomeView(session: session) }
            }
            .foregroundStyle(palette.ink)
            .scrollContentBackground(.hidden)
            .background(palette.canvas.ignoresSafeArea())
            .privacySensitive()
            .overlay {
                if scenePhase != .active {
                    palette.canvas.ignoresSafeArea().overlay { HabibiMark() }.accessibilityHidden(true)
                }
            }
            .task { await session.start(); session.setDraftSyncActive(scenePhase == .active); await appearance.refresh() }
            .onChange(of: scenePhase) { _, phase in
                session.setDraftSyncActive(phase == .active)
                if phase == .background { session.stop(); session.finishDraftHandoff() }
            }
            .sheet(item: $session.review, onDismiss: { session.resolveReview(false) }) { review in
                HabibiReviewView(session: session, review: review)
            }
        }
        .tint(palette.accent)
        .environment(\.habibiPalette, palette)
        .environmentObject(appearance)
        .preferredColorScheme(preferredScheme)
    }
}
