import CryptoKit
import Foundation
import SwiftUI

// Public presentation data only. Preferences belong to the encrypted profile;
// this catalog never receives a vault identifier, OAuth header or sync token.
struct HabibiThemeCatalog: Decodable {
    struct Theme: Decodable, Identifiable {
        struct Colors: Decodable {
            let light: [String: String]
            let dark: [String: String]

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: Token.self)
                var light: [String: String] = [:]
                for key in values.allKeys where key.stringValue != "modes" {
                    light[key.stringValue] = try values.decode(String.self, forKey: key)
                }
                self.light = light
                dark = try values.decode([String: [String: String]].self, forKey: Token(stringValue: "modes")!)["dark"] ?? [:]
            }

            private struct Token: CodingKey {
                var stringValue: String
                var intValue: Int? { nil }
                init?(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { return nil }
            }
        }
        let id: String
        let name: String
        let colors: Colors
    }

    let version: Int
    let defaultTheme: String
    let themes: [Theme]

    init(data: Data) throws {
        guard data.count <= 128 * 1024 else { throw Self.invalid }
        self = try JSONDecoder().decode(Self.self, from: data)
        let required = Set(["primary", "background", "text", "textMuted", "accent", "muted", "border", "surface", "onPrimary"])
        guard version == 1, (1...16).contains(themes.count), Set(themes.map(\.id)).count == themes.count,
              themes.contains(where: { $0.id == defaultTheme }), themes.allSatisfy({ theme in
                  theme.id.range(of: "^[a-z][a-z0-9-]{0,39}$", options: .regularExpression) != nil
                  && !theme.name.isEmpty && theme.name.count <= 60
                  && [theme.colors.light, theme.colors.dark].allSatisfy { colors in
                      required.isSubset(of: Set(colors.keys)) && colors.values.allSatisfy {
                          $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
                      }
                  }
              }) else { throw Self.invalid }
    }

    static let bundled: HabibiThemeCatalog = {
        // Once bundles the exact server-generated fallback, not a native fork.
        let bundles = [Bundle.main, Bundle(for: HabibiResourceBundle.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "themes", withExtension: "json"),
               let data = try? Data(contentsOf: url), let catalog = try? HabibiThemeCatalog(data: data) { return catalog }
        }
        preconditionFailure("The app must bundle the validated server theme catalog")
    }()

    func theme(_ id: String?) -> Theme {
        themes.first { $0.id == id } ?? themes.first { $0.id == defaultTheme }!
    }

    private static var invalid: HabibiFailure { HabibiFailure(message: "The server returned an unsupported theme catalog. The previous themes are still available.") }
}

final class HabibiResourceBundle: NSObject {}

@MainActor
final class HabibiAppearance: ObservableObject {
    @Published private(set) var catalog: HabibiThemeCatalog
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?
    let origin: HabibiSyncOrigin
    private let http: any HabibiSyncHTTP
    private let cacheURL: URL?

    init(origin: HabibiSyncOrigin = .current, http: any HabibiSyncHTTP = HabibiSyncURLSession(),
         bundled: HabibiThemeCatalog = .bundled, cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) {
        self.origin = origin
        self.http = http
        let key = SHA256.hash(data: Data(origin.value.utf8)).map { String(format: "%02x", $0) }.joined()
        cacheURL = cacheDirectory?.appendingPathComponent("habibi-themes-\(key).json")
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cached = try? HabibiThemeCatalog(data: data) { catalog = cached }
        else { catalog = bundled }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            var request = URLRequest(url: origin.url("/assets/themes.json"))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await http.send(request, limit: 128 * 1024)
            guard response.statusCode == 200, response.url == request.url else {
                throw HabibiFailure(message: "Could not refresh public themes. Bundled or cached themes remain available offline.")
            }
            let received = try HabibiThemeCatalog(data: data)
            if let cacheURL {
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
            }
            catalog = received
            error = nil
        } catch { self.error = "Could not refresh public themes. Your current theme is unchanged; try again when online." }
    }
}

struct HabibiAppearanceView: View {
    @ObservedObject var session: HabibiSession
    @EnvironmentObject private var appearance: HabibiAppearance
    @Environment(\.habibiPalette) private var palette
    @State private var saving = false
    @State private var error: String?

    private var profile: HabibiProfile? { session.snapshot?.profile }
    private var locked: Bool { saving || session.busy || session.syncing || session.chatRunning || session.review != nil }

    var body: some View {
        List {
            Section {
                HStack { Spacer(); HabibiHeartling().frame(width: 128, height: 128); Spacer() }
                Text("Heartling wears your colors. Tap to say hello.").font(.footnote).foregroundStyle(palette.muted)
            }
            Section("Theme") {
                ForEach(appearance.catalog.themes) { theme in
                    Button { save(theme: theme.id) } label: {
                        HStack {
                            Circle().fill(Color(habibiHex: theme.colors.light["primary"]!)).frame(width: 20, height: 20)
                            Text(theme.name).foregroundStyle(palette.ink)
                            Spacer()
                            if appearance.catalog.theme(profile?.theme).id == theme.id { Image(systemName: "checkmark") }
                        }.frame(minHeight: 36)
                    }
                    .accessibilityIdentifier("habibi.theme.\(theme.id)")
                    .accessibilityAddTraits(appearance.catalog.theme(profile?.theme).id == theme.id ? .isSelected : [])
                    .disabled(locked)
                }
                if let id = profile?.theme, !appearance.catalog.themes.contains(where: { $0.id == id }) {
                    Text("Your saved theme is not in this server’s catalog. Showing its default without changing your preference.")
                        .font(.footnote).foregroundStyle(palette.muted)
                }
            }
            Section("Appearance") {
                Picker("Appearance", selection: Binding(get: { profile?.appearance ?? "system" }, set: { save(mode: $0) })) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .tint(palette.accent)
                // UIKit caches this menu's tint across appearance changes.
                .id(palette.tokens["primary"])
                .disabled(locked).accessibilityIdentifier("habibi.appearance.mode")
            }
            Section {
                Text("Themes come from your Habibi server. Your selection stays in your encrypted profile, recovery backups and optional sync. Native typography follows your accessibility settings.")
                    .font(.footnote).foregroundStyle(palette.muted)
                Button("Refresh server themes") { Task { await appearance.refresh() } }.disabled(appearance.refreshing)
                if appearance.refreshing { ProgressView("Refreshing themes…") }
                if let error = error ?? appearance.error { Text(error).font(.footnote).foregroundStyle(palette.muted) }
            }
        }.background(palette.canvas).navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
    }

    private func save(theme: String? = nil, mode: String? = nil) {
        guard !locked, var profile else { return }
        if let theme { profile.theme = theme }
        if let mode { profile.appearance = mode }
        saving = true
        Task {
            defer { saving = false }
            do {
                let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
                _ = try await session.persist("profile", arguments: ["profile": value])
                error = nil
            } catch { self.error = "Could not save your appearance. Your previous preference is unchanged." }
        }
    }
}
