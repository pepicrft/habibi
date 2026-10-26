// Uses Atlas Pip's bundled-artwork/native-motion pattern. Original Habibi art.
import SwiftUI
import UIKit

enum HabibiHeartlingExpression: String {
    case idle, curious, delighted, sleepy, attentive, blink

    var description: String {
        switch self {
        case .idle, .blink: "Ready to help"
        case .curious: "A curious hello"
        case .delighted: "Happy to see you"
        case .sleepy: "Resting"
        case .attentive: "Paying attention"
        }
    }
}

enum HabibiHeartlingSprites {
    private struct Manifest: Decodable {
        struct State: Decodable { let frames: [Int] }
        let image: String
        let frameWidth: Int
        let frameHeight: Int
        let columns: Int
        let states: [String: State]
    }

    static let images: [String: UIImage] = {
        for bundle in [Bundle.main, Bundle(for: HabibiResourceBundle.self)] {
            guard let url = bundle.url(forResource: "heartling", withExtension: "json"),
                  let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  let imageURL = bundle.url(forResource: manifest.image, withExtension: nil),
                  let sheet = UIImage(contentsOfFile: imageURL.path)?.cgImage else { continue }
            return manifest.states.mapValues { state in
                let index = state.frames[0]
                let rect = CGRect(x: (index % manifest.columns) * manifest.frameWidth,
                                  y: (index / manifest.columns) * manifest.frameHeight,
                                  width: manifest.frameWidth, height: manifest.frameHeight)
                return UIImage(cgImage: sheet.cropping(to: rect)!)
            }
        }
        preconditionFailure("The app must bundle the reviewed Heartling atlas and frame map")
    }()
}

struct HabibiHeartling: View {
    var interactive = true
    var working = false
    @Environment(\.habibiPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var expression = HabibiHeartlingExpression.idle
    @State private var greetings = 0
    @State private var lift = false

    private var active: Bool { scenePhase == .active }
    private var taskKey: String { "\(active):\(reduceMotion):\(working):\(greetings)" }

    var body: some View {
        Group {
            if interactive {
                Button(action: greet) { mascot.contentShape(Rectangle()).frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Heartling")
                    .accessibilityValue(expression.description)
                    .accessibilityHint("Tap to say hello. This does not send a message.")
                    .accessibilityIdentifier("habibi.heartling")
            } else { mascot.accessibilityHidden(true) }
        }
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .task(id: taskKey) {
            guard active, !working else { return }
            do {
                if expression != .idle {
                    try await Task.sleep(for: .milliseconds(200))
                    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6)) { lift = false }
                    try await Task.sleep(for: .seconds(1.2))
                    expression = .idle
                }
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(4.8))
                    expression = .blink
                    try await Task.sleep(for: .milliseconds(120))
                    expression = .idle
                }
            } catch { }
        }
        .onChange(of: scenePhase) { _, _ in expression = .idle; lift = false }
        .onChange(of: reduceMotion) { _, _ in expression = .idle; lift = false }
        .onDisappear { expression = .idle; lift = false }
    }

    private var mascot: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active || reduceMotion || !working)) { context in
            let phase = working && active && !reduceMotion ? context.date.timeIntervalSinceReferenceDate * 2.5 : 0
            let current = working ? HabibiHeartlingExpression.attentive : expression
            let sprite = Image(uiImage: HabibiHeartlingSprites.images[current.rawValue]!)
                .resizable().interpolation(.high).scaledToFit()
            GeometryReader { geometry in
                ZStack {
                    palette.accent
                    sprite.blendMode(.hardLight)
                }
                .compositingGroup().mask(sprite)
                .rotationEffect(.degrees(lift ? -7 : sin(phase) * 2), anchor: .bottom)
                .offset(y: lift ? -geometry.size.height * 0.06 : -abs(sin(phase)) * geometry.size.height * 0.025)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func greet() {
        guard active else { return }
        greetings += 1
        expression = greetings.isMultiple(of: 2) ? .delighted : .curious
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.55)) { lift = !reduceMotion }
    }
}
