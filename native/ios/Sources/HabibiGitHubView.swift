import SwiftUI

struct HabibiGitHubView: View {
    @ObservedObject var session: HabibiSession
    let kit: HabibiBundledKit
    @Environment(\.habibiPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @StateObject private var connector = HabibiGitHubConnector()
    @State private var disconnect = false
    @State private var browserError = false
    @State private var now = Date()
    private var connection: HabibiConnectionSummary? { session.snapshot?.connections?.first { $0.kitId == "github" } }
    private var locked: Bool { connector.activity != nil || session.busy || session.syncing || session.chatRunning || session.review != nil }

    var body: some View {
        detail(at: now).task(id: connection?.expiresAt) {
            now = Date()
            if let expiry = connection?.expiresAt, Double(expiry) > now.timeIntervalSince1970 {
                do { try await Task.sleep(for: .seconds(max(0, Double(expiry) - Date().timeIntervalSince1970))) }
                catch { return }
                guard !Task.isCancelled else { return }
                now = max(Date(), Date(timeIntervalSince1970: Double(expiry)))
            }
        }
    }

    private func detail(at date: Date) -> some View {
        let expired = connection?.expired(at: date) == true
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 16) {
                    HabibiKitIcon(github: true, size: 72)
                    HabibiKitPageView(kit: kit)
                }.frame(maxWidth: .infinity).padding(.bottom, 4)

                Text("When you ask, these read-only tools share sanitized profile and public repository results with your conversation’s inference provider and save them in encrypted history. Credentials stay in your vault. Connecting or checking alone does not share account data with the provider.")
                    .font(.footnote).foregroundStyle(palette.muted).accessibilityIdentifier("habibi.github.disclosure")

                if connector.activity == .connect {
                    authorization
                } else {
                    if let connection {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(expired ? "Expired · Reconnect to continue" : "Connected", systemImage: expired ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.shield")
                                .font(.headline).accessibilityIdentifier("habibi.github.status")
                            LabeledContent("Account", value: connection.account).privacySensitive()
                                .accessibilityIdentifier("habibi.github.account")
                            if let expiry = connection.expiresAt {
                                LabeledContent("Token expires", value: Date(timeIntervalSince1970: Double(expiry)).formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote).foregroundStyle(palette.muted)
                            }
                        }
                        .padding(20).background(palette.surface, in: RoundedRectangle(cornerRadius: 24))
                    }
                    VStack(spacing: 12) {
                        Button {
                            browserError = false
                            connector.perform(.connect, session: session)
                        } label: {
                            Text(connection == nil ? "Connect" : "Reconnect").font(.headline).frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule)
                        .tint(palette.accent).disabled(locked || !kit.githubConfigured)
                        .accessibilityIdentifier("habibi.github.connect")
                        if !kit.githubConfigured {
                            Text(HabibiBundledKit.githubUnavailable).font(.footnote).foregroundStyle(palette.muted)
                                .accessibilityIdentifier("habibi.github.unconfigured")
                        }
                        if connection != nil {
                            HStack {
                                Button("Check connection", systemImage: "checkmark.circle") { connector.perform(.check, session: session) }
                                    .frame(minHeight: 44)
                                    .disabled(locked || expired).accessibilityIdentifier("habibi.github.check")
                                Spacer()
                                Button("Disconnect", role: .destructive) { disconnect = true }
                                    .frame(minHeight: 44)
                                    .disabled(locked).accessibilityIdentifier("habibi.github.disconnect")
                            }.font(.subheadline).padding(.vertical, 8)
                        }
                    }
                }
                if connector.activity == .check || connector.activity == .disconnect { ProgressView("Working securely…") }
                if let login = connector.checkedLogin {
                    LabeledContent("GitHub /user returned", value: login).privacySensitive().accessibilityIdentifier("habibi.github.check-result")
                    Text("This check stays in the native app, outside your conversations.").font(.footnote).foregroundStyle(palette.muted)
                }
                if let error = connector.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("habibi.github.error") }

                VStack(spacing: 12) {
                    LabeledContent("Permission", value: "read:user")
                    Divider()
                    LabeledContent("Authentication", value: "GitHub in your browser")
                }.font(.subheadline).padding(20).background(palette.surface, in: RoundedRectangle(cornerRadius: 24))
                DisclosureGroup("Privacy, recovery & revocation") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Connect, then approve Habibi on GitHub in your browser. Review the app name and read:user permission before approving.")
                        Text("The access token is saved inside your encrypted vault, not in chat. To use it on another device, restore the same encrypted recovery backup with its separate key, connect encrypted sync, then manually sync both devices. Signing into Habibi alone does not recover your keys or this connection.")
                        Text("Expiring or revoked tokens require reconnecting, even when no expiry is shown. Habibi does not save or use refresh tokens. Your existing connection is replaced only after successful authorization and a durable encrypted save.")
                        Text("Disconnect removes this device’s saved connection. It reaches other devices only after manual sync and conflict resolution. Older backups or devices may still hold a working token.")
                        Text("For actual revocation, open GitHub Settings → Applications → Authorized OAuth Apps and revoke the app. This also stops access from old backups and other devices.")
                    }.font(.footnote).foregroundStyle(palette.muted).padding(.top, 12)
                }.accessibilityIdentifier("habibi.github.details")
            }.frame(maxWidth: 640).padding(24).frame(maxWidth: .infinity)
        }
        .background(palette.canvas).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close GitHub").accessibilityIdentifier("habibi.github.close")
            }
        }
        .onDisappear { connector.cancel(); browserError = false }
        .confirmationDialog("Disconnect GitHub on this device?", isPresented: $disconnect) {
            Button("Disconnect GitHub", role: .destructive) { connector.perform(.disconnect, session: session) }
        } message: { Text("This is a local encrypted-vault change until you sync. It does not revoke the token on GitHub. Old backups and devices may retain access; revoke the app on GitHub to stop it everywhere.") }
    }

    private var authorization: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Authorize on GitHub").font(.headline)
            if let code = connector.userCode {
                Text(code).font(.system(.title, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled).privacySensitive().accessibilityIdentifier("habibi.github.user-code")
                Text("Enter this code at github.com/login/device. Check the app name and read:user permission, approve, then return here.")
                    .font(.subheadline).foregroundStyle(palette.muted)
                if let expiry = connector.codeExpiresAt {
                    LabeledContent("Code expires", value: expiry.formatted(date: .omitted, time: .shortened)).font(.footnote)
                }
                Button("Open GitHub in browser", systemImage: "arrow.up.right.square") {
                    // Never open a verification_uri from a response or model output.
                    UIApplication.shared.open(HabibiGitHub.verificationURL, options: [:]) { opened in
                        if !opened { browserError = true }
                    }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("habibi.github.open-browser")
                if browserError { Text("Could not open the browser. Open github.com/login/device yourself and enter the code.").foregroundStyle(.red) }
                ProgressView("Waiting for GitHub approval…")
            } else { ProgressView("Requesting a code…") }
            Button("Cancel authorization", role: .cancel) { connector.cancel() }.accessibilityIdentifier("habibi.github.cancel")
            Text("Canceling or closing discards this attempt. If you already approved on GitHub, revoke that grant there if you do not want it retained.")
                .font(.footnote).foregroundStyle(palette.muted)
        }.padding(20).background(palette.surface, in: RoundedRectangle(cornerRadius: 24))
    }
}
