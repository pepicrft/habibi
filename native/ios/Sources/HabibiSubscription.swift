import Foundation
import StoreKit
import SwiftUI

struct HabibiSubscriptionStatus: Decodable {
    let plan: String
    let active: Bool
    let expiresAt: String?
    let available: Bool

    enum CodingKeys: String, CodingKey { case plan, active, expiresAt = "expires_at", available }
}

@MainActor
final class HabibiSubscription: ObservableObject {
    static let productIDs = ["habibi_plus_monthly", "habibi_plus_yearly"]
    @Published private(set) var products: [Product] = []
    @Published private(set) var status: HabibiSubscriptionStatus?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let account: HabibiSyncAccount
    private var updates: Task<Void, Never>?

    init(account: HabibiSyncAccount) { self.account = account }
    deinit { updates?.cancel() }

    func resume() async {
        if updates == nil {
            updates = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled else { return }
                    await self?.receive(result)
                }
            }
        }
        guard (try? await account.connected()) == true, !busy else { return }
        for await result in StoreKit.Transaction.unfinished { await receive(result) }
        await refresh()
    }

    func load() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            products = try await Product.products(for: Self.productIDs)
                .filter {
                    $0.type == .autoRenewable && $0.subscription?.subscriptionPeriod.value == 1
                        && $0.subscription?.subscriptionPeriod.unit == ($0.id == Self.productIDs[0] ? .month : .year)
                }
                .sorted { Self.productIDs.firstIndex(of: $0.id)! < Self.productIDs.firstIndex(of: $1.id)! }
            if (try? await account.connected()) == true { try await fetchStatus() }
            if products.isEmpty { message = "Subscriptions aren’t available from the App Store yet. Nothing has been charged." }
        } catch { message = error.localizedDescription }
    }

    func refresh() async {
        guard !busy else { return }
        do { try await fetchStatus() }
        catch { status = nil; message = error.localizedDescription }
    }

    func purchase(_ product: Product) async {
        guard !busy, status?.available == true, status?.active != true else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let subject = try await account.verifyAccount()
            // Read server state again before opening a chargeable store flow.
            try await fetchStatus()
            guard status?.active != true else { return }
            guard status?.available == true else { throw unavailable }
            switch try await product.purchase(options: [.appAccountToken(subject)]) {
            case .success(let result): try await deliver(result)
            case .pending: message = "Purchase awaiting approval. Plus will activate after the store confirms payment."
            case .userCancelled: break
            @unknown default: message = "The App Store did not complete this purchase. Restore purchases to check again."
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            _ = try await account.verifyAccount()
            try await AppStore.sync()
            for await result in StoreKit.Transaction.currentEntitlements { try await deliver(result) }
            try await fetchStatus()
            message = status?.active == true ? "Habibi Plus is active on this account." : "No active Plus subscription found. Use the Habibi account that originally purchased it."
        } catch { message = error.localizedDescription }
    }

    func signedOut() { status = nil; message = nil }

    private func receive(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard (try? await account.connected()) == true else { return }
        do { try await deliver(result) }
        catch { message = "Your purchase still needs verification. Restore purchases to retry. \(error.localizedDescription)" }
    }

    private func deliver(_ result: VerificationResult<StoreKit.Transaction>) async throws {
        guard case .verified(let transaction) = result else {
            throw HabibiFailure(message: "The App Store could not verify this purchase. No Plus access was granted.")
        }
        guard Self.productIDs.contains(transaction.productID) else { return }
        let subject = try await account.verifyAccount()
        guard transaction.appAccountToken == nil || transaction.appAccountToken == subject else {
            throw HabibiFailure(message: "Sign in to the Habibi account that purchased Plus, then restore purchases.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["platform": "ios", "product_id": transaction.productID, "fetch_token": result.jwsRepresentation])
        let (data, response) = try await account.authorized("/v1/subscription/receipt", method: "POST", body: body, contentType: "application/json", limit: 4096)
        guard response.statusCode == 200 else { throw unavailable }
        status = try JSONDecoder().decode(HabibiSubscriptionStatus.self, from: data)
        // Leave an unfulfilled purchase in StoreKit's durable queue for retry.
        guard status?.active == true || transaction.revocationDate != nil || (transaction.expirationDate ?? .distantFuture) <= Date() else { throw unavailable }
        await transaction.finish()
        message = status?.active == true ? "Habibi Plus is ready. Your content stays encrypted." : "This subscription is no longer active. Your local data is unchanged."
    }

    private func fetchStatus() async throws {
        let (data, response) = try await account.authorized("/v1/subscription", limit: 4096)
        guard response.statusCode == 200 else { status = nil; throw unavailable }
        status = try JSONDecoder().decode(HabibiSubscriptionStatus.self, from: data)
    }

    private var unavailable: HabibiFailure {
        HabibiFailure(message: "Subscription verification is unavailable. No access was changed. If payment completed, restore purchases to retry without paying again.")
    }
}

struct HabibiPlusView: View {
    @ObservedObject var session: HabibiSession
    @ObservedObject var subscription: HabibiSubscription
    @State private var selected = HabibiSubscription.productIDs[1]
    @Environment(\.habibiPalette) private var palette
    @Environment(\.scenePhase) private var phase

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HabibiHeartling(interactive: false).frame(width: 80, height: 80)
                    Text("A little closer, on every device.").font(.title2.weight(.semibold))
                    Text("Support the private space you bring with you.").foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                Label("Encrypted sync across your devices", systemImage: "lock.icloud")
                Label("Pick up unsent drafts on another device", systemImage: "rectangle.2.swap")
                Text("Snapshots sync when you tap Sync now. Drafts hand off automatically while Habibi is open. Your encryption key stays with you.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("The essentials stay free") {
                Text("Conversations, on-device AI, local Kits, skins, encryption and recovery backups. No subscription needed.")
                Text("AI provider subscriptions and usage charges are separate.").font(.footnote).foregroundStyle(.secondary)
            }
            if subscription.status?.active == true {
                Section {
                    Label("Plus is active", systemImage: "checkmark.seal.fill").accessibilityIdentifier("habibi.plus.active")
                    if let expiry = subscription.status?.expiresAt {
                        Text("Access through \(expiry.prefix(10)). Cancellation keeps access until the paid period ends.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    Text("Bought on Google Play? Manage or cancel it in Google Play.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("Choose your plan") {
                    if subscription.products.isEmpty {
                        Text("App Store plans unavailable").foregroundStyle(.secondary)
                    }
                    ForEach(subscription.products) { product in
                        Button { selected = product.id } label: {
                            HStack {
                                Image(systemName: selected == product.id ? "largecircle.fill.circle" : "circle")
                                Text(product.id == HabibiSubscription.productIDs[0] ? "Monthly" : "Yearly")
                                Spacer()
                                Text("\(product.displayPrice) / \(product.id == HabibiSubscription.productIDs[0] ? "month" : "year")").fontWeight(.semibold)
                            }.foregroundStyle(palette.ink)
                        }
                        .accessibilityAddTraits(selected == product.id ? .isSelected : [])
                        .accessibilityIdentifier("habibi.plus.\(product.id)")
                    }
                    if !session.syncConnected {
                        Button("Sign in before subscribing") { Task { await session.connectSync(); await subscription.refresh() } }
                            .accessibilityIdentifier("habibi.plus.sign-in")
                        Text("Use the same passkey account on every device. Signing in is free and does not recover your vault key.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button("Subscribe to Plus") {
                            if let product = subscription.products.first(where: { $0.id == selected }) { Task { await subscription.purchase(product) } }
                        }
                        .disabled(subscription.status?.available != true || !subscription.products.contains(where: { $0.id == selected }))
                        .accessibilityIdentifier("habibi.plus.subscribe")
                    }
                    Text("Auto-renews monthly or yearly at the displayed price until canceled. Payment is charged to your Apple account. Manage or cancel in App Store settings before renewal.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Restore purchases") { Task { await subscription.restore() } }
                    .disabled(!session.syncConnected).accessibilityIdentifier("habibi.plus.restore")
                Button("Refresh availability") { Task { await subscription.load() } }
                if subscription.busy { ProgressView("Checking subscription…") }
                if let message = subscription.message { Text(message).font(.footnote).accessibilityIdentifier("habibi.plus.message") }
                if let error = session.syncError { Text(error).font(.footnote).foregroundStyle(.red) }
                Text("If Plus expires, uploads pause. Your local vault and recovery exports still work, and existing server downloads remain available. No data is deleted by cancellation.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("RevenueCat verifies purchases using your pseudonymous account ID and store receipt. It never receives your vault content or encryption key.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Terms of use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Link("Privacy", destination: URL(string: "https://habibi.fyi/#privacy")!)
            }
        }
        .navigationTitle("Habibi Plus").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .background(palette.canvas)
        .disabled(subscription.busy || session.syncing)
        .task { await subscription.load() }
        .onChange(of: subscription.products) { _, products in
            if !products.contains(where: { $0.id == selected }), let first = products.first { selected = first.id }
        }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await subscription.refresh() } } }
    }
}
