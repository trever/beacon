import Foundation

// Pure change-detection rules for Sonos album art (design 2026-07-27-sonos-album-art-design.md §5, plan
// 2026-07-27-sonos-album-art-plan.md §4 WS-4), split out so the two-level cache the whole pipeline hinges
// on is table-testable without a network, CoreGraphics, or a LanAssetServer.
//
// Two levels, run in order by the impure caller (SonosArtPublisher):
//   1. `urlStep` -- cheap, first. If the Sonos `imageUrl` is byte-identical to the last one this pipeline
//      processed, `.doNothing`: no HTTPS GET, no CoreGraphics, no BLE frame. This kills ~99% of ticks at
//      zero cost. A nil/disabled URL is `.clear`. A genuinely changed, non-nil URL is `.publish` -- which
//      here means "go fetch and rasterise it," not "definitely send a new frame."
//   2. `digestStep` -- correct, second, called only after urlStep said `.publish` and the caller actually
//      fetched + rendered a tile. Compares the tile's SHA-256 against the last PUBLISHED tile's digest.
//      Equal digest => `.doNothing`: an expiring-signature URL (same album, new signed URL every poll)
//      costs one HTTPS GET, never a BLE frame or a device download. Different digest => `.publish`, and
//      `gen` increments only here -- the device only ever redownloads when the pixels actually differ.
public enum SonosArtAction: Equatable {
    case doNothing
    case clear
    case publish
}

// What the publisher last actually told the device, plus the `gen` it minted for that. `gen` is an
// identity the device compares with `!=`, never persisted across a hub relaunch (D-2) -- callers do not
// need to (and must not try to) restore this struct across launches.
public struct SonosArtCacheState: Equatable {
    public var lastImageUrl: String?
    public var lastTileDigest: String?
    public var lastPublishedAt: Date?
    public var gen: UInt32

    public init(lastImageUrl: String? = nil, lastTileDigest: String? = nil,
               lastPublishedAt: Date? = nil, gen: UInt32 = 0) {
        self.lastImageUrl = lastImageUrl
        self.lastTileDigest = lastTileDigest
        self.lastPublishedAt = lastPublishedAt
        self.gen = gen
    }
}

public enum SonosArtDecision {
    // `artEnabled == false` is folded into "the effective URL is nil" -- the Settings toggle behaves
    // exactly like the track having no art at all (D-6): a disabled-and-already-cleared cache
    // (lastImageUrl == nil) yields `.doNothing` on every subsequent tick, so toggling off publishes
    // exactly one S2 and then goes quiet, never re-clearing on every 5 s poll.
    //
    // Debounce applies ONLY to `.publish` (a tile actually about to be fetched/served) -- never to
    // `.clear`, which carries no URL and arms nothing, so there is no reason to delay it (and every
    // reason not to: a toggle-off must clear immediately, not wait out a scrub-protection window meant
    // for a different problem).
    public static func urlStep(newImageUrl: String?, state: SonosArtCacheState,
                               artEnabled: Bool, now: Date, debounce: TimeInterval) -> SonosArtAction {
        let effective = artEnabled ? nonEmpty(newImageUrl) : nil
        guard effective != state.lastImageUrl else { return .doNothing }
        guard effective != nil else { return .clear }
        if let lastPublishedAt = state.lastPublishedAt, now.timeIntervalSince(lastPublishedAt) < debounce {
            return .doNothing
        }
        return .publish
    }

    // Called only after a fetch+render succeeded. `.clear` is not a real outcome of this step (a
    // rendered tile always has a digest) -- it exists so the enum stays exhaustive for callers that
    // switch over the shared `SonosArtAction` type; treat it defensively the same as urlStep's `.clear`.
    public static func digestStep(newDigest: String, state: SonosArtCacheState) -> SonosArtAction {
        newDigest == state.lastTileDigest ? .doNothing : .publish
    }

    // `gen` is an opaque tile identity (D-2): the device compares with `!=`, so wraparound is a non-issue
    // and this is free to overflow-wrap rather than saturate.
    public static func nextGen(_ current: UInt32) -> UInt32 {
        current &+ 1
    }

    // Sonos hands back album art over PLAIN HTTP -- measured 2026-07-28 against a live account, e.g.
    // `http://albumart.siriusxm.com/albumart/...jpg`. macOS App Transport Security refuses those loads
    // outright ("the App Transport Security policy requires the use of a secure connection"), so every
    // fetch failed and the device correctly showed its no-art form. Upgrading the scheme is the fix that
    // does NOT weaken the app: `albumart.siriusxm.com` serves the identical image over TLS (verified
    // 200 image/jpeg). An ATS exception was rejected as the alternative -- it would have to name an
    // open-ended set of third-party hosts, and at least one of them
    // (`pri.art.prod.streaming.siriusxm.com`, the channel-logo fallback) presents a certificate that
    // does not match its own hostname, so no exception could make it safe to load anyway. That host
    // simply fails the fetch, and design 6.3's "on any art failure, publish S2, not silence" already
    // covers it: the tile clears rather than going stale.
    //
    // Anything that is not http (https, or a scheme we do not recognise) is returned untouched.
    public static func httpsUpgraded(_ raw: String) -> String {
        guard var c = URLComponents(string: raw), c.scheme?.lowercased() == "http" else { return raw }
        c.scheme = "https"
        return c.string ?? raw
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
