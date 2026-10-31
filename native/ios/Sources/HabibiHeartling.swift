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
    var avatar: HabibiSkinAvatar?
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
                    .accessibilityLabel(avatar == nil ? "Heartling" : "Skin avatar")
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
        .onChange(of: avatar) { _, _ in expression = .idle; lift = false }
        .onDisappear { expression = .idle; lift = false }
    }

    private var mascot: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active || reduceMotion || !working)) { context in
            let phase = working && active && !reduceMotion ? context.date.timeIntervalSinceReferenceDate * 2.5 : 0
            let current = working ? HabibiHeartlingExpression.attentive : expression
            GeometryReader { geometry in
                Group {
                    if let avatar {
                        HabibiSkinAvatarDrawing(avatar: avatar, expression: current)
                    } else {
                        let sprite = Image(uiImage: HabibiHeartlingSprites.images[current.rawValue]!)
                            .resizable().interpolation(.high).scaledToFit()
                        ZStack {
                            palette.accent
                            sprite.blendMode(.hardLight)
                        }.compositingGroup().mask(sprite)
                    }
                }
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

// Only the bounded M/L/Q/C/Z geometry validated by the core reaches this renderer.
private struct HabibiSkinAvatarDrawing: View {
    let avatar: HabibiSkinAvatar
    let expression: HabibiHeartlingExpression
    @Environment(\.habibiPalette) private var palette

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / 100, y: side / 100)
            let silhouette = path
            context.fill(silhouette, with: .color(palette.accent))
            context.fill(silhouette, with: .linearGradient(
                Gradient(colors: [.clear, .black.opacity(0.22)]),
                startPoint: CGPoint(x: 25, y: 15), endPoint: CGPoint(x: 75, y: 90)))
            context.stroke(silhouette, with: .color(.white.opacity(0.18)), lineWidth: 0.7)
            let eyes = avatar.eyes
            let gaze = (expression == .curious ? 0.8 : expression == .attentive ? -0.8 : 0) * eyes.scale
            for x in [eyes.x - eyes.spacing / 2, eyes.x + eyes.spacing / 2] {
                let center = CGPoint(x: x + gaze, y: eyes.y)
                let radius = 3.2 * eyes.scale
                if expression == .blink || expression == .sleepy || expression == .delighted {
                    var lid = Path()
                    lid.move(to: CGPoint(x: center.x - radius, y: center.y))
                    lid.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y),
                                     control: CGPoint(x: center.x, y: center.y - (expression == .delighted ? radius * 1.6 : 0)))
                    context.stroke(lid, with: .color(.black.opacity(0.78)), style: StrokeStyle(lineWidth: 1.6 * eyes.scale, lineCap: .round))
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius * 1.25,
                                                       width: radius * 2, height: radius * 2.5)), with: .color(.black.opacity(0.78)))
                    context.fill(Path(ellipseIn: CGRect(x: center.x - radius * 0.4, y: center.y - radius * 0.7,
                                                       width: radius * 0.55, height: radius * 0.55)), with: .color(.white.opacity(0.65)))
                }
            }
        }
    }

    private var path: Path {
        let tokens = avatar.body.path.split(whereSeparator: \.isWhitespace)
        var index = 0
        var result = Path()
        func point() -> CGPoint {
            let value = CGPoint(x: Double(tokens[index])!, y: Double(tokens[index + 1])!)
            index += 2
            return value
        }
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M": result.move(to: point())
            case "L": result.addLine(to: point())
            case "Q":
                let control = point()
                result.addQuadCurve(to: point(), control: control)
            case "C":
                let first = point(), second = point()
                result.addCurve(to: point(), control1: first, control2: second)
            case "Z": result.closeSubpath()
            default: return Path()
            }
        }
        return result
    }
}
