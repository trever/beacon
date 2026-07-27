import Foundation

// UserDefaults-backed home for the Sonos OAuth Client ID entered in Settings (design
// 2026-07-26-sonos-setup-ui). Mirrors SonosRoomStore's shape (injectable UserDefaults, one key). Stays a
// thin persistence layer only -- SonosClientID.resolve (BeaconHubKit, pure) owns the stored/env/placeholder
// precedence rule, and AppDelegate is what turns this + Keychain into the UI's SonosSetupSnapshot.
//
// The Client ID is NOT secret (SonosOAuth's own doc comment: "may live in source or config"), so
// UserDefaults is the right store -- unlike the client secret, which must only ever reach SonosKeychain.
final class SonosSetupStore {
    private static let clientIDKey = "BeaconSonosClientID"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var storedClientID: String {
        get { defaults.string(forKey: Self.clientIDKey) ?? "" }
        set { defaults.set(newValue.isEmpty ? nil : newValue, forKey: Self.clientIDKey) }
    }
}
