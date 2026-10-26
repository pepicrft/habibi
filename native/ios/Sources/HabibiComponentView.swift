import NativeShell
import SwiftUI

// Adapted from Atlas at 9af36c01be under native/ATLAS_LICENSE (MIT).
// The reviewed, byte-identical Atlas bundle deliberately keeps its original
// atlas.thread-card bridge and app ID. NSH's Apache notice ships with the bundle.
struct HabibiComponent: Codable, Equatable {
    struct Content: Codable, Equatable {
        let title: String
        var columns: [String]? = nil
        var rows: [[String]]? = nil
        var kitId: String? = nil
        var prefill: [Prefill]? = nil
    }
    struct Prefill: Codable, Equatable {
        let key: String
        let value: HabibiValue
    }
    struct Action: Codable, Equatable {
        let id: String
        let label: String
    }
    let type: String
    let version: Int
    let data: Content
    let actions: [Action]
    let fallback: String
}

struct HabibiComponentView: View {
    let card: HabibiComponent
    let action: (String) -> Void
    @State private var height: CGFloat = 180
    @State private var ready = false
    @State private var failed = false
    @ScaledMetric(relativeTo: .body) private var fontScale: CGFloat = 1
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.habibiPalette) private var palette

    var body: some View {
        Group {
            if failed {
                VStack(alignment: .leading) {
                    Text(card.fallback).font(.callout).textSelection(.enabled)
                    if let item = card.actions.first(where: { $0.id == "show_source" }) {
                        Button(item.label) { action(item.id) }.frame(minHeight: 44)
                    }
                }
                .accessibilityIdentifier("thread-card-fallback")
            } else {
                HabibiComponentSurface(card: card, colors: colors, fontScale: fontScale, action: action) { value in
                    ready = true
                    if abs(height - value) > 1 { height = value }
                } failure: { failed = true }
                .frame(height: height)
                .task {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    if !ready { failed = true }
                }
            }
        }
    }

    private var colors: [String: String] {
        if contrast == .increased {
            return ["text": hex(.label), "secondary": hex(.secondaryLabel),
                    "surface": hex(.secondarySystemGroupedBackground),
                    "accent": hex(.systemBlue), "border": hex(.separator)]
        }
        return [
            "text": hex(UIColor(palette.ink)),
            "secondary": hex(UIColor(palette.muted)),
            "surface": hex(UIColor(palette.surface)),
            "accent": hex(UIColor(palette.accent)),
            "border": hex(UIColor(palette.border))
        ]
    }

    private func hex(_ color: UIColor) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

private struct HabibiComponentSurface: UIViewRepresentable {
    let card: HabibiComponent
    let colors: [String: String]
    let fontScale: CGFloat
    let action: (String) -> Void
    let height: (CGFloat) -> Void
    let failure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NshAppView {
        let view = NshAppView()
        view.accessibilityIdentifier = "thread-card-runtime"
        view.limits = NshLimits(memoryMB: 16, loadBudget: 1, callBudget: 0.25, maxNodes: 512)
        view.storageDirectory = context.coordinator.storage
        view.onError = { _ in context.coordinator.failure?() }
        view.register(component: "atlas.thread-card") { [weak coordinator = context.coordinator] value in
            let bridge = Bridge(value, coordinator: coordinator)
            coordinator?.bridge = bridge
            return bridge
        }
        updateUIView(view, context: context)
        guard context.coordinator.validated else { return view }
        do {
            try view.grantCapabilities("{}")
            guard let url = Bundle.main.url(forResource: "bundle", withExtension: "js") else { throw CocoaError(.fileNoSuchFile) }
            try view.loadBundle(at: url)
        } catch { DispatchQueue.main.async { failure() } }
        return view
    }

    func updateUIView(_ view: NshAppView, context: Context) {
        let coordinator = context.coordinator
        coordinator.action = action
        coordinator.height = height
        coordinator.failure = failure
        if view.fontScale != fontScale { view.fontScale = fontScale }
        guard let encoded = try? JSONEncoder().encode(card),
              let cardData = try? JSONSerialization.jsonObject(with: encoded),
              let result = try? HabibiCore.execute(["operation": "validate_component", "component": cardData]),
              let validated = result["component"] as? [String: Any] else {
            coordinator.validated = false
            coordinator.allowedActions = []
            DispatchQueue.main.async { failure() }
            return
        }
        coordinator.validated = true
        coordinator.allowedActions = Set(card.actions.filter { $0.id == "show_source" }.map(\.id))
        let payload: [String: Any] = ["card": validated, "colors": colors]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
              data != coordinator.lastData else { return }
        coordinator.lastData = data
        coordinator.payload = payload
        coordinator.bridge?.context.emit("data", payload)
    }

    static func dismantleUIView(_ view: NshAppView, coordinator: Coordinator) {
        view.onError = nil
        coordinator.action = nil
        coordinator.height = nil
        coordinator.failure = nil
        coordinator.allowedActions = []
        coordinator.payload = [:]
        coordinator.lastData = nil
        try? FileManager.default.removeItem(at: coordinator.storage)
    }

    final class Coordinator {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("habibi-card-" + UUID().uuidString)
        weak var bridge: Bridge?
        var validated = false
        var allowedActions: Set<String> = []
        var payload: [String: Any] = [:]
        var lastData: Data?
        var action: ((String) -> Void)?
        var height: ((CGFloat) -> Void)?
        var failure: (() -> Void)?
    }

    final class Bridge: NshComponent {
        let view = UIView()
        let context: NshComponentContext
        weak var coordinator: Coordinator?

        init(_ context: NshComponentContext, coordinator: Coordinator?) {
            self.context = context
            self.coordinator = coordinator
        }

        func setProp(_ name: String, _ value: Any?) {
            if name == "ready", let payload = coordinator?.payload { context.emit("data", payload) }
        }

        func command(_ name: String, _ args: Any?) {
            switch name {
            case "action":
                if let event = args as? String, event == "show_source",
                   coordinator?.allowedActions.contains(event) == true { coordinator?.action?(event) }
            case "height":
                if let number = args as? NSNumber, number.doubleValue == 0 { return }
                if let number = args as? NSNumber, number.doubleValue.isFinite, (1...6_000).contains(number.doubleValue) {
                    coordinator?.height?(CGFloat(number.doubleValue))
                } else { coordinator?.failure?() }
            default: break
            }
        }
    }
}
