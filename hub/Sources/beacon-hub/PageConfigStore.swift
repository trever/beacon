import Foundation
import BeaconHubKit

// Persists the user's chosen page list + a monotonic rev, mirroring TickerConfigStore (issue #92).
//
// The rev is what makes a push idempotent: the device echoes it in `pages_ack`, and a stale ack (for a
// list the user has since edited again) is ignored rather than reported as the current state.
final class PageConfigStore {
    struct Snapshot: Equatable {
        var rev: Int
        var ids: [String]
        /// Per-page options keyed by page id. Kept separate from `ids` so ordering and content stay
        /// independent -- reordering must not disturb what a page is configured to show.
        var opts: [String: [String: String]] = [:]
        var specs: [PageSpec] { ids.map { PageSpec(id: $0, opts: opts[$0]) } }
    }

    private let defaults: UserDefaults
    private let idsKey = "BeaconPageIDs"
    private let revKey = "BeaconPageRev"
    private let optsKey = "BeaconPageOpts"

    init(store: UserDefaults = .standard) { self.defaults = store }

    /// Pristine (never configured) => the shipped default order, at rev 0. A rev of 0 also tells the
    /// (re)connect path there is nothing worth pushing yet, so an untouched hub never reboots the device.
    var current: Snapshot {
        let rev = defaults.integer(forKey: revKey)
        let ids = defaults.stringArray(forKey: idsKey) ?? PageCatalog.defaultOrder
        let opts = (defaults.dictionary(forKey: optsKey) as? [String: [String: String]]) ?? [:]
        return Snapshot(rev: rev, ids: ids, opts: opts)
    }

    var isPristine: Bool { defaults.stringArray(forKey: idsKey) == nil }

    /// Store a new list and bump the rev. Returns the new snapshot. Bumping only on a real change keeps
    /// the device from rebooting for a no-op edit (applying a page list restarts it).
    @discardableResult
    func set(ids: [String], opts: [String: [String: String]] = [:]) -> Snapshot {
        let cur = current
        // Options count as a change too: switching the chart's instrument must reach the device even
        // when the page order is untouched.
        guard ids != cur.ids || opts != cur.opts || isPristine else { return cur }
        let next = cur.rev + 1
        defaults.set(ids, forKey: idsKey)
        defaults.set(opts, forKey: optsKey)
        defaults.set(next, forKey: revKey)
        return Snapshot(rev: next, ids: ids, opts: opts)
    }

    /// The frame to push for the current snapshot, or nil when nothing has been configured yet.
    func frame() -> PagesFrame? {
        let s = current
        guard s.rev > 0 else { return nil }
        return PagesFrame(rev: s.rev, s.specs)
    }
}
