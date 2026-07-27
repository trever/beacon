import Foundation

// UserDefaults-backed home for the selected Sonos room (design 2026-07-26-sonos-now-playing-plan). The
// room-picker UI is a separate agent's work (plan step 11: room is a per-page `opts["room"]` value, same
// plumbing as `chart.sym`); this is only the persistence SonosProvider polls against, so the picker has
// somewhere to write once it exists. Injectable `defaults` mirrors TickerConfigStore's shape so both
// sides are testable without touching the real domain.
final class SonosRoomStore {
    private static let key = "BeaconSonosSelectedRoom"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var selectedRoom: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
