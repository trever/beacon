import Foundation
import BeaconHubKit

// Persists the user's chosen Home complication assignment + a monotonic rev, mirroring PageConfigStore
// (which itself mirrors TickerConfigStore, issue #92). The rev is what makes a push idempotent: the
// device echoes it in `comps_ack`, and a stale ack (for an assignment the user has since edited past) is
// ignored rather than reported as the current state.
final class ComplicationStore {
    struct Snapshot: Equatable {
        var rev: Int
        /// Face id -> wire strings ("clock", "fin.sp500", ...). Kept in this raw form (not
        /// `[CompPlacement]`) so a face this build does not yet render still round-trips through
        /// UserDefaults untouched.
        var slots: [String: [String]] = [:]
    }

    private let defaults: UserDefaults
    private let slotsKey = "BeaconCompSlots"
    private let revKey = "BeaconCompRev"

    init(store: UserDefaults = .standard) { self.defaults = store }

    /// Pristine (never configured) => the shipped default Home assignment, at rev 0. A rev of 0 also
    /// tells the (re)connect path there is nothing worth pushing yet, so an untouched hub never nudges
    /// the device (design §7: "existing users see no change until they open the editor").
    var current: Snapshot {
        let rev = defaults.integer(forKey: revKey)
        let slots = (defaults.dictionary(forKey: slotsKey) as? [String: [String]])
            ?? [CompLimits.homeFace: ComplicationCatalog.defaultHome.map(\.wire)]
        return Snapshot(rev: rev, slots: slots)
    }

    var isPristine: Bool { defaults.dictionary(forKey: slotsKey) == nil }

    /// Store a new assignment and bump the rev. Returns the new snapshot. Bumping only on a real change
    /// matters less here than for pages (a complication edit does not restart the device), but the same
    /// discipline keeps `frame()`/`pushCompConfig()` from re-sending a no-op on every reconnect for no
    /// reason beyond the idempotent no-op the device already handles for free.
    @discardableResult
    func set(slots: [String: [String]]) -> Snapshot {
        let cur = current
        guard slots != cur.slots || isPristine else { return cur }
        let next = cur.rev + 1
        defaults.set(slots, forKey: slotsKey)
        defaults.set(next, forKey: revKey)
        return Snapshot(rev: next, slots: slots)
    }

    /// The frame to push for the current snapshot, or nil while pristine (rev 0) -- an untouched hub
    /// never pushes, matching PagesFrame/ConfigFrame's migration promise.
    func frame() -> CompsFrame? {
        let s = current
        guard s.rev > 0 else { return nil }
        var placements: [String: [CompPlacement]] = [:]
        for (face, wire) in s.slots {
            placements[face] = wire.compactMap(CompPlacement.init)
        }
        return CompsFrame(rev: s.rev, slots: placements)
    }
}
