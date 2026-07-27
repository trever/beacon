import SwiftUI
import AppKit
import BeaconHubKit

// Sonos setup section for Settings (design 2026-07-26-sonos-setup-ui): Client ID + secret + authorize +
// status + disconnect, all driven by a pulled SonosSetupSnapshot -- see HubViewModel.onLoadSonosSetup.
// Split out of SettingsPanel.swift per the platform gotcha noted in the plan: a large SwiftUI body risks
// "unable to type-check this expression in reasonable time," and this section has enough moving parts
// (a text field, a secure field, a multi-stage async button, a 4-way status, two confirmations) to
// warrant its own @ViewBuilder-heavy file, the same way PageDesignerView split PageCard/PageOptions out.
//
// The secret NEVER lands in @Published/UserDefaults/logs here: `secretDraft` holds the pasted value only
// long enough to hand it to model.onSaveSonosSecret (which writes straight to Keychain), and is cleared
// immediately after -- see saveSecret() below. Only a character count ever comes back.
struct SonosSettingsSection: View {
    @ObservedObject var model: HubViewModel

    @State private var snapshot: SonosSetupSnapshot = .empty
    @State private var clientIDDraft = ""
    @State private var secretDraft = ""
    @State private var secretMessage: String?
    @State private var secretMessageIsError = false
    @State private var authorizing = false
    @State private var authorizeSucceeded = false
    @State private var authorizeMessage: String?
    @State private var confirmDisconnect = false
    @State private var confirmClearSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            SectionHeader(title: "Sonos", subtitle: "Connect Beacon Hub to your Sonos system")
            Card {
                VStack(alignment: .leading, spacing: HubSpace.m) {
                    statusRow
                    Divider()
                    clientIDField
                    secretField
                    authorizeRow
                    if hasStoredAuthorization || snapshot.secretStored {
                        Divider()
                        disconnectRow
                    }
                }
            }
        }
        .onAppear { refresh() }
        // SettingsWindowController builds this window ONCE and reuses it for the app's lifetime
        // (isReleasedWhenClosed = false) -- onAppear above only ever fires the first time this view is
        // inserted into that window's hierarchy, never again on a later reopen. Without this, a Settings
        // window that happened to first appear before Client ID/secret/authorization were set (e.g. the
        // first-run auto-open, or a race with AppDelegate's Sonos wiring) would show that stale snapshot
        // FOREVER, even after the user genuinely configures and authorizes Sonos through some other means
        // (the CLI's set-sonos-secret/sonos-authorize, run from a Terminal while the hub is already
        // running) -- there would be nothing left to trigger a re-read. Re-deriving on every
        // didBecomeKeyNotification re-checks truth each time this window (or the app) regains focus,
        // mirroring the existing "re-check on refocus" idiom AppDelegate.applicationDidBecomeActive already
        // uses for provider hooks. Cheap: these are local Keychain/UserDefaults reads, same as onAppear.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .alert("Disconnect Sonos?", isPresented: $confirmDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { model.onDisconnectSonos(); refresh() }
        } message: {
            Text("This clears the stored authorization. You can reconnect any time; the client secret stays saved.")
        }
        .alert("Clear the saved client secret?", isPresented: $confirmClearSecret) {
            Button("Cancel", role: .cancel) {}
            Button("Clear secret", role: .destructive) { model.onClearSonosSecret(); refresh() }
        } message: {
            Text("You will need to paste it again before reconnecting.")
        }
    }

    private func refresh() {
        snapshot = model.onLoadSonosSetup()
        clientIDDraft = snapshot.storedClientID
    }

    private var hasStoredAuthorization: Bool {
        switch snapshot.status {
        case .authorized, .authorizedButFailing: return true
        case .notConfigured, .secretStoredNotAuthorized: return false
        }
    }

    // --- status ---

    // Collapses the four `SonosSetupSnapshot.status` cases into `HubState` (design §3.3), the one status
    // vocabulary every surface in this system now shares. `.notConfigured` and `.secretStoredNotAuthorized`
    // both map to `.notSetUp`, never `.warn` -- design §3.3/§2.3 calls out the old orange used for "you
    // haven't set a Client ID yet" as miscast: that's a normal first-run state, not a warning, and the
    // fix (below, in `clientIDHint`) drops the orange entirely.
    private var sonosState: HubState {
        switch snapshot.status {
        case .notConfigured, .secretStoredNotAuthorized: return .notSetUp
        case .authorized:                                return .ok
        case .authorizedButFailing:                      return .warn
        }
    }

    // Not the `StatusRow` component itself: that component's own `space.m` horizontal inset assumes a
    // zero-padding row-stack card (design §3.2), and this card holds a mixed form (fields, buttons, a
    // status line), not a stack of rows -- wrapping it in `StatusRow` here would double the inset against
    // the card's own `space.l` content padding. Consuming `HubState`'s glyph/tint directly still lands the
    // one shared vocabulary; only the layout differs from the row-stack case.
    @ViewBuilder private var statusRow: some View {
        HStack(alignment: .top, spacing: HubSpace.m) {
            Image(systemName: sonosState.glyph)
                .foregroundStyle(sonosState.tint)
                .frame(width: HubControlMetrics.iconColumn)
            VStack(alignment: .leading, spacing: HubSpace.xs) {
                Text(statusTitle).font(HubType.body).foregroundStyle(HubColor.inkPrimary)
                if let statusDetail {
                    Text(statusDetail).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: HubSpace.s)
        }
    }

    private var statusTitle: String {
        switch snapshot.status {
        case .notConfigured:             return "Not configured"
        case .secretStoredNotAuthorized: return "Secret stored, not connected"
        case .authorized:                return "Connected"
        case .authorizedButFailing:      return "Connected, but not working"
        }
    }

    private var statusDetail: String? {
        switch snapshot.status {
        case .notConfigured:
            return "Set a Client ID and secret below, then authorize."
        case .secretStoredNotAuthorized:
            return "Click Authorize with Sonos to finish connecting."
        case .authorized(let expiresAt):
            guard let expiresAt else { return "Access token does not expire." }
            return "Access token refreshes automatically; the current one expires \(Self.expiryFormatter.string(from: expiresAt))."
        case .authorizedButFailing(let reason):
            return reason
        }
    }

    private static let expiryFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    // --- client ID ---

    @ViewBuilder private var clientIDField: some View {
        VStack(alignment: .leading, spacing: HubSpace.xs) {
            Text("Client ID").font(HubType.body).foregroundStyle(HubColor.inkPrimary)
            HStack(spacing: HubSpace.s) {
                TextField(SonosClientID.placeholder, text: $clientIDDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(HubType.control)
                    .onSubmit { saveClientID() }
                HubButton(title: "Save", isEnabled: clientIDDraft != snapshot.storedClientID) { saveClientID() }
            }
            clientIDHint
        }
    }

    // Both branches are informational (a normal first-run nudge, or a note about an env override) --
    // neither is a warning, so both are `ink.secondary`, not the old orange (design §3.3: a first-run
    // "you haven't set this up" state is `notSetUp`, never `warn`).
    @ViewBuilder private var clientIDHint: some View {
        if snapshot.usingEnvOverride {
            Text("Using SONOS_CLIENT_ID from the environment. Saving a value here will override it.")
                .font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
        } else if snapshot.effectiveClientID == SonosClientID.placeholder {
            Text("Not set. Get a Client ID from a \u{201C}Control\u{201D} integration at integration.sonos.com.")
                .font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
        }
    }

    private func saveClientID() {
        model.onSaveSonosClientID(clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        refresh()
    }

    // --- client secret ---

    @ViewBuilder private var secretField: some View {
        VStack(alignment: .leading, spacing: HubSpace.xs) {
            Text("Client secret").font(HubType.body).foregroundStyle(HubColor.inkPrimary)
            HStack(spacing: HubSpace.s) {
                SecureField(snapshot.secretStored ? "Replace the stored secret" : "Paste the client secret",
                           text: $secretDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(HubType.control)
                HubButton(title: "Save", isEnabled: !secretDraft.isEmpty) { saveSecret() }
            }
            // Shows the stored secret only as a character count, never the value (unchanged). Error text
            // is `ink.primary` (design §3.9), not a state colour standing in for a glyph-less word.
            Text(secretStatusText).font(HubType.secondary)
                .foregroundStyle(secretMessageIsError ? HubColor.inkPrimary : HubColor.inkSecondary)
        }
    }

    private var secretStatusText: String {
        if let secretMessage { return secretMessage }
        return snapshot.secretStored ? "Stored (\(snapshot.secretCharCount) characters)." : "Not stored."
    }

    // Never let the pasted value linger in view state once Keychain has it -- see the file-level comment.
    private func saveSecret() {
        switch model.onSaveSonosSecret(secretDraft) {
        case .saved(let count):
            secretMessage = "Saved (\(count) characters)."
            secretMessageIsError = false
        case .refused(let reason):
            secretMessage = reason
            secretMessageIsError = true
        case .keychainWriteFailed:
            secretMessage = "Could not write to the Keychain."
            secretMessageIsError = true
        }
        secretDraft = ""
        refresh()
    }

    // --- authorize ---

    @ViewBuilder private var authorizeRow: some View {
        HStack(alignment: .top, spacing: HubSpace.m) {
            HubButton(title: authorizing ? "Authorizing\u{2026}" : "Authorize with Sonos",
                      kind: .primary, isEnabled: canAuthorize && !authorizing) { authorize() }
            authorizeStatusText
            Spacer()
        }
    }

    // The result word stays `ink.primary` (design §2.3: "state is never colour alone") -- the outcome is
    // carried by `HubState`'s glyph/tint pair beside it, reusing the same one vocabulary `sonosState`
    // above draws from, not a bare coloured word standing in for a glyph.
    @ViewBuilder private var authorizeStatusText: some View {
        if let authorizeMessage {
            HStack(spacing: HubSpace.xs) {
                if !authorizing {
                    let outcome: HubState = authorizeSucceeded ? .ok : .warn
                    Image(systemName: outcome.glyph).foregroundStyle(outcome.tint)
                }
                Text(authorizeMessage).font(HubType.secondary)
                    .foregroundStyle(authorizing ? HubColor.inkSecondary : HubColor.inkPrimary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else if !canAuthorize {
            Text(disabledReason).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
        }
    }

    private var canAuthorize: Bool {
        snapshot.effectiveClientID != SonosClientID.placeholder && snapshot.secretStored
    }

    private var disabledReason: String {
        if snapshot.effectiveClientID == SonosClientID.placeholder { return "Set a Client ID first." }
        if !snapshot.secretStored { return "Save a client secret first." }
        return ""
    }

    private func authorize() {
        authorizing = true
        authorizeSucceeded = false
        authorizeMessage = "Opening your browser\u{2026}"
        model.onAuthorizeSonos({ stage in
            authorizeMessage = describe(stage)
        }, { result in
            authorizing = false
            switch result {
            case .success:
                authorizeSucceeded = true
                authorizeMessage = "Connected."
            case .failure(let e):
                authorizeSucceeded = false
                authorizeMessage = describe(e)
            }
            refresh()
        })
    }

    private func describe(_ stage: SonosAuthorizer.Stage) -> String {
        switch stage {
        case .openingBrowser:     return "Opening your browser\u{2026}"
        case .waitingForRedirect: return "Waiting for you to approve in the browser\u{2026}"
        case .exchangingToken:    return "Connecting\u{2026}"
        }
    }

    // The model for error copy in this system (design §3.9): every case is a specific sentence, and the
    // loopback-bind case even names the port. Kept verbatim.
    private func describe(_ e: SonosAuthError) -> String {
        switch e {
        case .noClientSecret:       return "No client secret stored."
        case .placeholderClientID:  return "Client ID is still the placeholder."
        case .loopbackBindFailed:
            return "Could not open a local listener on localhost:\(SonosLoopbackServer.port). Is something else using that port?"
        case .timedOut:            return "Timed out waiting for you to approve in the browser."
        case .malformedCallback:   return "The Sonos redirect was missing expected data. Try again."
        case .stateMismatch:       return "Security check failed (state mismatch). Try again."
        case .exchangeFailed(let m): return "Could not complete the connection: \(m)"
        case .keychainWriteFailed:  return "Connected, but could not save to the Keychain."
        }
    }

    // --- disconnect ---

    @ViewBuilder private var disconnectRow: some View {
        HStack(spacing: HubSpace.s) {
            VStack(alignment: .leading, spacing: HubSpace.xs) {
                Text("Disconnect").font(HubType.body).foregroundStyle(HubColor.inkPrimary)
                Text("Clears the stored authorization. The client secret stays saved.")
                    .font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
            }
            Spacer()
            if snapshot.secretStored {
                HubButton(title: "Clear secret") { confirmClearSecret = true }
            }
            HubButton(title: "Disconnect", isEnabled: hasStoredAuthorization) { confirmDisconnect = true }
        }
    }
}

#if DEBUG
#Preview {
    let m = HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000))
    m.onLoadSonosSetup = {
        SonosSetupSnapshot(storedClientID: "abc123", effectiveClientID: "abc123", usingEnvOverride: false,
                           secretStored: true, secretCharCount: 44,
                           status: .authorized(expiresAt: Date().addingTimeInterval(3600)))
    }
    return SonosSettingsSection(model: m).padding(HubSpace.l).frame(width: 460)
}
#endif
