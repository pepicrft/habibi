import Foundation
import SwiftUI
import UIKit

@MainActor
final class HabibiBetaUpdates: ObservableObject {
    struct Build: Decodable, Equatable {
        let version: String
        let build: String
        let minimumOSVersion: String

        var label: String { "\(version) (\(build))" }
        var valid: Bool { [version, build, minimumOSVersion].allSatisfy(Self.numeric) }

        func newer(than other: Build) -> Bool {
            let versionOrder = Self.compare(version, other.version)
            return versionOrder == .orderedDescending ||
                (versionOrder == .orderedSame && Self.compare(build, other.build) == .orderedDescending)
        }

        func compatible(with systemVersion: String) -> Bool {
            Self.compare(minimumOSVersion, systemVersion) != .orderedDescending
        }

        private static func compare(_ left: String, _ right: String) -> ComparisonResult {
            let lhs = left.split(separator: ".").compactMap { Int($0) }
            let rhs = right.split(separator: ".").compactMap { Int($0) }
            for index in 0..<max(lhs.count, rhs.count) {
                let a = index < lhs.count ? lhs[index] : 0
                let b = index < rhs.count ? rhs[index] : 0
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            }
            return .orderedSame
        }

        private static func numeric(_ value: String) -> Bool {
            value.range(of: "^[0-9]{1,9}(\\.[0-9]{1,9}){0,2}$", options: .regularExpression) != nil
        }
    }

    static let testFlightURL = URL(string: "itms-beta://testflight.apple.com/v1/app/6828413839")!
    static var isBeta: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--beta-updates")
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    @Published private(set) var available: Build?
    @Published private(set) var checking = false
    @Published private(set) var checked = false
    @Published private(set) var error: String?
    let installed: Build
    let enabled: Bool
    private let origin: HabibiSyncOrigin
    private let http: any HabibiSyncHTTP
    private let systemVersion: String
    private var lastCheck: Date?

    init(origin: HabibiSyncOrigin = .current, http: any HabibiSyncHTTP = HabibiSyncURLSession(resourceTimeout: 25),
         installed: Build? = nil, systemVersion: String? = nil, enabled: Bool? = nil) {
        self.origin = origin
        self.http = http
        self.systemVersion = systemVersion ?? UIDevice.current.systemVersion
        self.installed = installed ?? Build(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                                            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
                                            minimumOSVersion: Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String ?? "17.0")
        self.enabled = enabled ?? Self.isBeta
    }

    func refresh(force: Bool = false) async {
        guard enabled, !checking, force || lastCheck.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        checking = true
        lastCheck = Date()
        defer { checking = false }
        do {
            var request = URLRequest(url: origin.url("/v1/updates/ios"))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await http.send(request, limit: 256 * 1024)
            guard response.statusCode == 200, response.url == request.url else { throw URLError(.badServerResponse) }
            struct Metadata: Decodable { let builds: [Build] }
            let builds = try JSONDecoder().decode(Metadata.self, from: data).builds
            guard builds.count <= 2000, builds.allSatisfy(\.valid) else { throw URLError(.cannotParseResponse) }
            available = builds.filter {
                $0.newer(than: installed) && $0.compatible(with: systemVersion)
            }.max { $1.newer(than: $0) }
            checked = true
            error = nil
        } catch {
            // A failed check must not claim the installed version is current or retain a withdrawn offer.
            available = nil
            checked = false
            self.error = String(localized: "Couldn’t check for updates. Try again when you’re online.")
        }
    }
}

struct HabibiBetaUpdateSection: View {
    @ObservedObject var updates: HabibiBetaUpdates
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var openingFailed = false

    var body: some View {
        Section {
            LabeledContent("Version", value: updates.installed.label)
            if updates.enabled {
                if let build = updates.available {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Update available", systemImage: "arrow.down.circle")
                            .font(.headline)
                        Text("Habibi \(build.label)").font(.subheadline).foregroundStyle(.secondary)
                        Button("Open TestFlight", systemImage: "arrow.up.right") {
                            openURL(HabibiBetaUpdates.testFlightURL) { openingFailed = !$0 }
                        }
                        .accessibilityIdentifier("habibi.updates.open")
                    }.padding(.vertical, 4)
                }
                Button { Task { await updates.refresh(force: true) } } label: {
                    HStack {
                        Text("Check for updates")
                        Spacer()
                        if updates.checking { ProgressView() }
                    }
                }.disabled(updates.checking).accessibilityIdentifier("habibi.updates.check")
            }
        } footer: {
            if updates.enabled {
                if openingFailed && updates.available != nil { Text("Couldn’t open TestFlight. Open the TestFlight app to update Habibi.") }
                else if let error = updates.error { Text(error) }
                else if updates.available != nil { Text("TestFlight installs the update. Your private space stays on this device.") }
                else if updates.checked { Text("No newer compatible Private Beta build is available.") }
                else { Text("Check for a newer Private Beta build in TestFlight.") }
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await updates.refresh() }
        }
    }
}
