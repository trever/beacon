import Foundation

// Pure logic backing the Sonos setup UI in Settings (design 2026-07-26-sonos-setup-ui: give the two CLI
// subcommands, set-sonos-secret and sonos-authorize, a real UI). Kept out of SwiftUI/Keychain/UserDefaults
// so it is host-tested, mirroring the ChartInstrumentSearch/Selection precedent -- PageDesignerView (and
// now SonosSettingsView) hold state and call into here; the branching itself lives where it can be tested.

// Client ID resolution (SonosOAuth.clientID). Not secret -- the Sonos plan explicitly allows it in source
// or config -- but now that Settings can persist one, the UI-entered value must win over the
// SONOS_CLIENT_ID environment variable that was the only way to set it before this UI existed, while the
// env var keeps working as a fallback so nothing already relying on it breaks.
public enum SonosClientID {
    /// SonosOAuth's original fallback literal. Exported so this is the single source of truth for what
    /// "not yet configured" looks like -- SonosOAuth, SonosAuthorizer, and the UI all compare against it.
    public static let placeholder = "REPLACE_WITH_SONOS_CLIENT_ID"

    /// stored (Settings, persisted) > env (SONOS_CLIENT_ID) > placeholder.
    public static func resolve(stored: String?, env: String?) -> String {
        if let stored, !stored.isEmpty { return stored }
        if let env, !env.isEmpty { return env }
        return placeholder
    }
}

// Client secret validation. Mirrors main.swift's existing `set-sonos-secret` stdin guard exactly (>=16
// chars, no spaces) so the CLI and the Settings UI enforce and describe the SAME rule instead of two that
// could drift apart.
public enum SonosSecretValidation {
    public static let minLength = 16
    public static let refusalMessage = "that does not look like a client secret (>=16 chars, no spaces)"

    public static func isValid(_ secret: String) -> Bool {
        secret.count >= minLength && !secret.contains(" ")
    }
}

/// Outcome of the UI's "save secret" action. Never carries the secret itself -- only whether it was
/// stored, a length to display, or why it was refused/failed. See SonosSettingsView: the raw secret is
/// discarded from view state the moment this comes back.
public enum SonosSecretSaveResult: Equatable {
    case saved(charCount: Int)
    case refused(String)
    case keychainWriteFailed
}

// Status the Settings UI shows, in the four states the plan calls for: not configured / secret stored but
// not authorized / authorized (with expiry if known) / authorized but failing.
public enum SonosSetupStatus: Equatable {
    case notConfigured
    case secretStoredNotAuthorized
    case authorized(expiresAt: Date?)
    case authorizedButFailing(reason: String)
}

public enum SonosSetupState {
    /// Derive the status from what is actually on disk/in Keychain plus (optionally) the most recent
    /// classified poll result SonosProvider observed. `lastOutcome` reuses SonosProvider's own
    /// ProviderOutcome vocabulary for the failure text instead of the UI inventing a second classification
    /// of the same 401/403/network conditions SonosOutcomeClassifier already names. When no live outcome
    /// has been observed yet (e.g. right after launch, or no room selected so the poller has never run),
    /// this falls back to a purely structural check: a credential that is expired with a dead refresh
    /// token cannot work no matter what SonosProvider reports.
    public static func derive(secretStored: Bool, credential: SonosCredential?,
                              lastOutcome: ProviderOutcome?, now: Date) -> SonosSetupStatus {
        guard secretStored else { return .notConfigured }
        guard let credential else { return .secretStoredNotAuthorized }
        if let lastOutcome {
            switch lastOutcome {
            case .terminal(let reason, _):
                return .authorizedButFailing(reason: reason)
            case .transient(_, let reason):
                return .authorizedButFailing(reason: reason)
            case .live, .inactive:
                break   // .inactive just means "no room selected yet" -- not an authorization failure.
            }
        }
        if credential.isExpired(at: now), !credential.refreshTokenAlive {
            return .authorizedButFailing(reason: "Sonos session expired - run Authorize again")
        }
        return .authorized(expiresAt: credential.expiresAt)
    }
}

/// Everything the Settings UI needs to render the Sonos section, pulled fresh on demand (Keychain +
/// UserDefaults reads are cheap and local; there is no reason to keep this continuously live like the
/// BLE-driven state elsewhere in HubViewModel).
public struct SonosSetupSnapshot: Equatable {
    public let storedClientID: String       // "" when unset -- the raw value Settings persisted, if any.
    public let effectiveClientID: String    // what SonosOAuth.clientID actually resolves to right now.
    public let usingEnvOverride: Bool       // true when storedClientID is empty and SONOS_CLIENT_ID filled in.
    public let secretStored: Bool
    public let secretCharCount: Int
    public let status: SonosSetupStatus

    public init(storedClientID: String, effectiveClientID: String, usingEnvOverride: Bool,
               secretStored: Bool, secretCharCount: Int, status: SonosSetupStatus) {
        self.storedClientID = storedClientID
        self.effectiveClientID = effectiveClientID
        self.usingEnvOverride = usingEnvOverride
        self.secretStored = secretStored
        self.secretCharCount = secretCharCount
        self.status = status
    }

    public static let empty = SonosSetupSnapshot(storedClientID: "", effectiveClientID: SonosClientID.placeholder,
                                                  usingEnvOverride: false, secretStored: false,
                                                  secretCharCount: 0, status: .notConfigured)
}
