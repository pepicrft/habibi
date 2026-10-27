import NativeShell
import SwiftUI

/// Kit-owned presentation, separate from the host's connection and vault UI.
struct HabibiKitPageView: View {
    let kit: HabibiBundledKit
    @State private var page: [String: Any]?
    @State private var failed = false
    @State private var ready = false
    @State private var height: CGFloat = 240
    @ScaledMetric(relativeTo: .body) private var fontScale: CGFloat = 1
    @Environment(\.habibiPalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if failed {
                Text(page?["fallback"] as? String ?? "\(kit.name)\n\(kit.description)")
                    .foregroundStyle(palette.ink).textSelection(.enabled)
                    .accessibilityIdentifier("habibi.kit.page.fallback")
            } else if let page {
                HabibiKitPageSurface(page: page, colors: colors, fontScale: fontScale) { value in
                    ready = true
                    if abs(height - value) > 1 { height = value }
                } failure: { failed = true }
                .frame(height: height)
                .task {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    if !ready { failed = true }
                }
            } else { ProgressView("Opening Kit page…") }
        }
        .task(id: kit.id) {
            do { page = try HabibiCore.execute(["operation": "kit_page", "id": kit.id]) }
            catch { failed = true }
        }
    }

    private var colors: [String: String] {
        let colors: [String: UIColor] = contrast == .increased
            ? ["text": .label, "secondary": .secondaryLabel, "accent": .systemBlue]
            : ["text": UIColor(palette.ink), "secondary": UIColor(palette.muted), "accent": UIColor(palette.accent)]
        return colors.mapValues { color in
            let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        }
    }
}

private struct HabibiKitPageSurface: UIViewRepresentable {
    let page: [String: Any]
    let colors: [String: String]
    let fontScale: CGFloat
    let height: (CGFloat) -> Void
    let failure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NshAppView {
        let view = NshAppView()
        view.accessibilityIdentifier = "habibi.kit.page.runtime"
        view.limits = NshLimits(memoryMB: 16, loadBudget: 1, callBudget: 0.25, maxNodes: 512)
        let coordinator = context.coordinator
        view.storageDirectory = coordinator.directory.appendingPathComponent("storage")
        view.onError = { [weak coordinator] _ in
            DispatchQueue.main.async { coordinator?.failure?() }
        }
        view.register(component: "habibi.kit-page") { [weak coordinator] context in
            let bridge = Bridge(context, coordinator: coordinator)
            coordinator?.bridge = bridge
            return bridge
        }
        updateUIView(view, context: context)
        do {
            guard page["version"] as? Int == 1, let source = page["source"] as? String else {
                throw CocoaError(.coderInvalidValue)
            }
            try FileManager.default.createDirectory(at: coordinator.directory, withIntermediateDirectories: true)
            let bundle = coordinator.directory.appendingPathComponent("bundle.js")
            try Data(source.utf8).write(to: bundle)
            try Data("{\"id\":\"fyi.habibi.kit-page\"}".utf8).write(to: coordinator.directory.appendingPathComponent("app.json"))
            try Data("{\"network\":{\"hosts\":[],\"http\":[]},\"process\":{\"execute\":[],\"exit\":false,\"env\":[]},\"fs\":{\"read\":[],\"write\":[]},\"statusBar\":false,\"clipboard\":false}".utf8)
                .write(to: coordinator.directory.appendingPathComponent("capabilities.json"))
            try view.grantCapabilities("{}")
            try view.loadBundle(at: bundle)
        } catch { DispatchQueue.main.async { coordinator.failure?() } }
        return view
    }

    func updateUIView(_ view: NshAppView, context: Context) {
        let coordinator = context.coordinator
        coordinator.height = height
        coordinator.failure = failure
        if view.fontScale != fontScale { view.fontScale = fontScale }
        // Never forward the descriptor/source, vault, account, OAuth client,
        // credentials or session. Only public metadata and presentation tokens.
        let kit = page["kit"] as? [String: Any] ?? [:]
        let metadata = ["id": kit["id"] as? String ?? "", "name": kit["name"] as? String ?? "", "description": kit["description"] as? String ?? ""]
        let payload: [String: Any] = ["kit": metadata, "colors": colors,
            "typography": ["title": 28, "heading": 17, "body": 17, "caption": 13]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
              data != coordinator.lastData else { return }
        coordinator.lastData = data
        coordinator.payload = payload
        coordinator.bridge?.context.emit("data", payload)
    }

    static func dismantleUIView(_ view: NshAppView, coordinator: Coordinator) {
        view.onError = nil
        coordinator.height = nil
        coordinator.failure = nil
        coordinator.payload = [:]
        try? FileManager.default.removeItem(at: coordinator.directory)
    }

    final class Coordinator {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("habibi-kit-page-" + UUID().uuidString)
        weak var bridge: Bridge?
        var payload: [String: Any] = [:]
        var lastData: Data?
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
            // This is deliberately not an action/tool/authentication bridge.
            guard name == "height" else { return }
            if let number = args as? NSNumber, number.doubleValue == 0 { return }
            guard let number = args as? NSNumber, number.doubleValue.isFinite, (1...6000).contains(number.doubleValue) else {
                coordinator?.failure?()
                return
            }
            coordinator?.height?(CGFloat(number.doubleValue))
        }
    }
}
