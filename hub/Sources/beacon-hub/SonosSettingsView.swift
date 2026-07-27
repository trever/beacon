import SwiftUI
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
    @State private var authorizing = false
    @State private var authorizeSucceeded = false
    @State private var authorizeMessage: String?
    @State private var confirmDisconnect = false
    @State private var confirmClearSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Sonos", subtitle: "Connect Beacon Hub to your Sonos system")
            Module {
                VStack(alignment: .leading, spacing: 12) {
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

    @ViewBuilder private var statusRow: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: statusGlyph.name).foregroundStyle(statusGlyph.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.system(size: 13, weight: .medium))
                if let statusDetail {
                    Text(statusDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
        }
    }

    private var statusGlyph: (name: String, color: Color) {
        switch snapshot.status {
        case .notConfigured:              return ("circle", .secondary)
        case .secretStoredNotAuthorized:  return ("circle.dashed", .secondary)
        case .authorized:                 return ("checkmark.circle.fill", .green)
        case .authorizedButFailing:       return ("exclamationmark.triangle.fill", .orange)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Client ID").font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                TextField(SonosClientID.placeholder, text: $clientIDDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { saveClientID() }
                DeckButton(title: "Save", enabled: clientIDDraft != snapshot.storedClientID) { saveClientID() }
            }
            clientIDHint
        }
    }

    @ViewBuilder private var clientIDHint: some View {
        if snapshot.usingEnvOverride {
            Text("Using SONOS_CLIENT_ID from the environment. Saving a value here will override it.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        } else if snapshot.effectiveClientID == SonosClientID.placeholder {
            Text("Not set. Get a Client ID from a \u{201C}Control\u{201D} integration at integration.sonos.com.")
                .font(.system(size: 10)).foregroundStyle(.orange)
        }
    }

    private func saveClientID() {
        model.onSaveSonosClientID(clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        refresh()
    }

    // --- client secret ---

    @ViewBuilder private var secretField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Client secret").font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                SecureField(snapshot.secretStored ? "Replace the stored secret" : "Paste the client secret",
                           text: $secretDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                DeckButton(title: "Save", enabled: !secretDraft.isEmpty) { saveSecret() }
            }
            Text(secretStatusText).font(.system(size: 10))
                .foregroundStyle(secretMessage != nil ? Color.orange : Color.secondary)
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
        case .refused(let reason):
            secretMessage = reason
        case .keychainWriteFailed:
            secretMessage = "Could not write to the Keychain."
        }
        secretDraft = ""
        refresh()
    }

    // --- authorize ---

    @ViewBuilder private var authorizeRow: some View {
        HStack(alignment: .top, spacing: 10) {
            DeckButton(title: authorizing ? "Authorizing\u{2026}" : "Authorize with Sonos",
                      kind: .primary, enabled: canAuthorize && !authorizing) { authorize() }
            authorizeStatusText
            Spacer()
        }
    }

    @ViewBuilder private var authorizeStatusText: some View {
        if let authorizeMessage {
            Text(authorizeMessage).font(.system(size: 11))
                .foregroundStyle(authorizing ? Color.secondary : (authorizeSucceeded ? Color.green : Color.orange))
                .fixedSize(horizontal: false, vertical: true)
        } else if !canAuthorize {
            Text(disabledReason).font(.system(size: 11)).foregroundStyle(.secondary)
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

    private func describe(_ e: SonosAuthError) -> String {
        switch e {
        case .noClientSecret:       return "No client secret stored."
        case .placeholderClientID:  return "Client ID is still the placeholder."
        case .loopbackBindFailed:
            return "Could not open a local listener on 127.0.0.1:\(SonosLoopbackServer.port). Is something else using that port?"
        case .timedOut:            return "Timed out waiting for you to approve in the browser."
        case .malformedCallback:   return "The Sonos redirect was missing expected data. Try again."
        case .stateMismatch:       return "Security check failed (state mismatch). Try again."
        case .exchangeFailed(let m): return "Could not complete the connection: \(m)"
        case .keychainWriteFailed:  return "Connected, but could not save to the Keychain."
        }
    }

    // --- disconnect ---

    @ViewBuilder private var disconnectRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Disconnect").font(.system(size: 12, weight: .medium))
                Text("Clears the stored authorization. The client secret stays saved.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if snapshot.secretStored {
                DeckButton(title: "Clear secret") { confirmClearSecret = true }
            }
            DeckButton(title: "Disconnect", enabled: hasStoredAuthorization) { confirmDisconnect = true }
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
    return SonosSettingsSection(model: m).padding(16).frame(width: 460)
}
#endif
