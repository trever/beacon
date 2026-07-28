import Foundation
import Network
import BeaconHubKit

// The impure half of the album-art pipeline (design 2026-07-27-sonos-album-art-design.md, plan
// 2026-07-27-sonos-album-art-plan.md §4 WS-4): holds the change-detection cache (SonosArtDecision, pure),
// calls SonosArtRenderer.fetchAndRender (Phase A, pure network glue), calls LanAssetServer.arm (WS-1),
// and emits `sart` frames via `onFrame` for AppDelegate to hand to `central.send`. Consumes `sart_stat`
// to drive the Local Network Settings row through LocalNetworkCheck.
//
// Everything here is confined to `queue` -- AppDelegate calls in from the main actor. Callbacks out are
// NOT uniformly hopped to main: `onFrame` fires on `queue` itself, which is safe because its only
// consumer, `central.send`, is thread-safe on its own (it re-dispatches onto BeaconCentral's own internal
// queue regardless of caller thread, the same as every other `central.send` call site in AppDelegate).
// `onLocalNetworkOutcome` DOES hop to `DispatchQueue.main` first (see handleSartStat below), because its
// consumer writes an `@MainActor`, `@Published` HubViewModel property that SwiftUI observes.
//
// Deliberately NEVER references `PowerAssertions` (design §7.2): album art arms the LAN listener roughly
// once per track, and taking `.idleSystemSleepDisabled` at that duty cycle would stop the user's Mac from
// ever sleeping. `LanAssetServer` itself cannot reach that seam even by accident (D-5); this file simply
// never calls it either -- see SonosArtPublisherTests' testArtPublishTakesNoSleepAssertion.
final class SonosArtPublisher {
    // `LanAssetServer.arm`'s exact signature, extracted here (not there -- LanAssetServer.swift is WS-1's,
    // "consume, don't edit") so SonosArtPublisherTests can substitute a spy. `LanAssetServer` conforms via
    // the plain `extension` below, which needs no change to LanAssetServer.swift itself.
    protocol Arming: AnyObject {
        func arm(_ data: Data, contentType: String, peer: IPv4Address, ttl: TimeInterval, maxServes: Int,
                 completion: @escaping (Result<URL, LanAssetServer.ArmError>) -> Void)
        func disarm()
        var onServed: ((Bool) -> Void)? { get set }
    }

    // Arm parameters, strictly tighter than OTA on every axis (design §7.1) -- caller arguments to
    // LanAssetServer.arm, not constants there.
    static let armTTL: TimeInterval = 30
    static let armMaxServes = 1
    static let contentType = "application/octet-stream"
    static let debounce: TimeInterval = 2

    var onFrame: ((Data) -> Void)?
    var onLocalNetworkOutcome: ((LanServeOutcome) -> Void)?

    private let server: Arming
    private let fetchAndRender: (URL, @escaping (Result<SonosArtRenderer.Tile, SonosArtRenderer.FetchError>) -> Void) -> Void
    private let now: () -> Date
    private let queue = DispatchQueue(label: "beacon.sonosart")

    // --- queue-confined state ---
    private var cache = SonosArtCacheState()
    private var artEnabled: Bool
    private var deviceIP: IPv4Address?
    private var linkUp = false
    private var sonosPageEnabled = false
    private var currentTile: SonosArtRenderer.Tile?
    private var pendingReconnectRepublish = false
    private var inFlightFetchToken: UInt64 = 0

    init(artEnabled: Bool = true,
         server: Arming = LanAssetServer(),
         fetchAndRender: @escaping (URL, @escaping (Result<SonosArtRenderer.Tile, SonosArtRenderer.FetchError>) -> Void) -> Void
            = { url, completion in SonosArtRenderer.fetchAndRender(url: url, completion: completion) },
         now: @escaping () -> Date = Date.init) {
        self.artEnabled = artEnabled
        self.server = server
        self.fetchAndRender = fetchAndRender
        self.now = now
        self.server.onServed = { ok in
            FileHandle.standardError.write(Data("[beacon-hub] sonos-art serve ok=\(ok)\n".utf8))
        }
    }

    // --- inputs, all main-actor callers hopping onto `queue` ---

    // D-7: fired from SonosProvider.onArtURL, on its own cadence, independent of the text-tuple gate.
    func handleArtURL(_ url: String?) {
        queue.async { [weak self] in self?.processURL(url) }
    }

    // D-6: toggling off must publish S2 with a fresh gen, then go quiet -- not merely stop arming.
    // Toggling back on republishes from the cache the next real tick clears naturally (urlStep sees the
    // current URL as "changed" against the now-nil lastImageUrl), so there is nothing to force here.
    func setArtEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.artEnabled != enabled else { return }
            self.artEnabled = enabled
            if !enabled {
                self.pendingReconnectRepublish = false
                self.commitClear()
                self.currentTile = nil
            }
        }
    }

    // "Armed only while the sonos page is in the device's page list" (design §7.1) -- AppDelegate calls
    // this at startup and on every page-list edit.
    func setSonosPageEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sonosPageEnabled = enabled
            self.tryFlushPendingReconnect()
        }
    }

    // "...and the BLE link is up." AppDelegate's refreshLink already computes this per phase change.
    func setLinkUp(_ up: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.linkUp = up
            self.tryFlushPendingReconnect()
        }
    }

    // D-1/D-2's integration point: the device's own reported IP (`cmd:"report","what":"device"`,
    // CONTRACT.md §B4), which the hub needs to (a) pick which of its OWN interfaces to advertise via
    // LanInterface (inside LanAssetServer.arm) and (b) pass as `peer` for the source-address restriction.
    //
    // MUST be treated as a repeatable, last-writer-wins update, never a once-per-connection event: BLE
    // connects roughly 9 s before WiFi joins on a cold boot (measured on hardware), so the device's FIRST
    // report of every connection carries no IP at all, and it re-reports at ~1 s cadence whenever its live
    // IP stops matching what the connection was told. A nil `ipString` is a REAL state (WiFi is down / not
    // yet up), not a parse failure -- it must clear any previously-known address, not be ignored, or a
    // stale address would survive a WiFi drop and the hub would keep trying to arm against an address the
    // device can no longer be reached at.
    func setDeviceIP(_ ipString: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deviceIP = ipString.flatMap { IPv4Address($0) }
            self.tryFlushPendingReconnect()
        }
    }

    // "BLE (re)connect => re-arm with a fresh token and re-push S1 with a fresh gen" (design §5, not
    // optional: the device's tile lives in RAM, so a reboot leaves it with none, and the hub cannot tell a
    // reconnect from a reboot). AppDelegate calls this from the same central.onReady site pushSonosFrame()
    // already resends from on every (re)connect.
    //
    // This does NOT go through the normal handleArtURL/urlStep path on purpose: if the currently playing
    // track has not changed since before the disconnect, urlStep's identity check (`effective ==
    // state.lastImageUrl`) would see nothing to do and stay silent forever -- exactly the failure this
    // rule exists to prevent. A dedicated pending-republish latch is used instead, because at the moment
    // BLE reports ready the device's IP is very often not known yet (same ~9 s gap above): the latch
    // survives until setDeviceIP/setSonosPageEnabled/setLinkUp all agree conditions are met, however long
    // that takes and in whatever order the three land.
    func noteReconnected() {
        queue.async { [weak self] in
            guard let self, self.artEnabled, self.currentTile != nil else { return }
            self.pendingReconnectRepublish = true
            self.tryFlushPendingReconnect()
        }
    }

    // `sart_stat` (CONTRACT.md §B4) -- one-way, no ack. Feeds the Local Network row via
    // LocalNetworkCheck.derive; `gen` itself needs no reconciliation here (it already told the device
    // which tile this refers to; the hub does not track per-gen delivery state beyond this signal).
    func handleSartStat(ok: Bool, err: String?) {
        let outcome: LanServeOutcome = ok ? .served : .deviceErr(err ?? "net")
        DispatchQueue.main.async { [weak self] in self?.onLocalNetworkOutcome?(outcome) }
    }

    // Test seam only (internal, not part of the contract any of the setters/handlers above expose): lets
    // a test know every call issued on `queue` before this one has finished running, without a sleep or a
    // poll loop -- useful for the "nothing happened" assertions (e.g. no arm when the gate is closed),
    // where there is no positive event to hang an expectation off of. Mirrors the problem LanAssetServer's
    // own `onTornDown` seam solves, one layer up.
    func drain(_ completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    // --- pipeline, all on `queue` ---

    // Diagnostics. This pipeline crosses three processes (Sonos cloud, this hub, the device) and every
    // stage has a legitimate "do nothing" outcome, so a silent path is indistinguishable from a broken
    // one -- which is exactly what happened the first time it was run against real hardware. Same
    // stderr idiom as ClaudeCodeProvider/BeaconCentral. Never log the URL's query: Sonos art URLs carry
    // an expiring signature.
    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[beacon-hub] art \(message)\n".utf8))
    }

    private static func redact(_ url: String?) -> String {
        guard let url, let c = URLComponents(string: url) else { return "(none)" }
        return "\(c.host ?? "?")\(c.path)"
    }

    private func processURL(_ url: String?) {
        switch SonosArtDecision.urlStep(newImageUrl: url, state: cache, artEnabled: artEnabled,
                                        now: now(), debounce: Self.debounce) {
        case .doNothing:
            return
        case .clear:
            log("step=clear url=\(Self.redact(url))")
            commitClear()
        case .publish:
            // Gate BEFORE fetching, not just before arming: with no sonos page or no BLE link there is
            // nobody who could ever receive the frame this fetch would produce, so skip the HTTPS GET
            // entirely rather than do the work and throw it away. The cache is left untouched, so the
            // next tick (or the gate re-opening) sees the same "changed" URL and retries -- nothing is
            // lost, just deferred.
            guard linkUp, sonosPageEnabled, let url, let target = URL(string: url) else {
                log("step=publish BLOCKED linkUp=\(linkUp) sonosPage=\(sonosPageEnabled) url=\(Self.redact(url))")
                return
            }
            log("step=publish fetching \(Self.redact(url))")
            let token = inFlightFetchToken &+ 1
            inFlightFetchToken = token
            fetchAndRender(target) { [weak self] result in
                self?.queue.async { self?.handleFetchResult(result, urlString: url, token: token) }
            }
        }
    }

    private func handleFetchResult(_ result: Result<SonosArtRenderer.Tile, SonosArtRenderer.FetchError>,
                                   urlString: String, token: UInt64) {
        // A superseded fetch (a newer URL tick started another one before this completed) is dropped
        // silently -- latest wins, mirroring the device-side rule for the same reason (design §4.4).
        guard token == inFlightFetchToken else { return }
        switch result {
        case .failure(let err):
            log("fetch FAILED \(err) url=\(Self.redact(urlString))")
            // Design §6.3/§8: on any art failure, publish S2, not silence.
            commitClear()
        case .success(let tile):
            switch SonosArtDecision.digestStep(newDigest: tile.sha256Hex, state: cache) {
            case .doNothing:
                // Pixels match what is already on the device -- absorb the (expiring-signature) URL
                // change so the NEXT identical-content URL hits urlStep's cheap identity path instead of
                // re-fetching again.
                cache.lastImageUrl = urlString
            case .clear:
                commitClear()
            case .publish:
                log("fetch ok digest=\(tile.sha256Hex.prefix(8)) bytes=\(tile.pixels.count)")
                commitPublish(urlString: urlString, tile: tile)
            }
        }
    }

    private func commitPublish(urlString: String, tile: SonosArtRenderer.Tile) {
        guard linkUp, sonosPageEnabled else { return }   // state may have changed while the fetch was in flight
        let gen = SonosArtDecision.nextGen(cache.gen)
        armAndEmit(urlString: urlString, tile: tile, gen: gen)
    }

    private func tryFlushPendingReconnect() {
        // `deviceIP != nil` MUST be part of this guard, not left to armAndEmit's own check below: if it
        // were left out, a flush attempt made before the device's first real deviceReport would consume
        // (clear) `pendingReconnectRepublish` here and then silently fail inside armAndEmit, losing the
        // republish forever -- setDeviceIP's later call with a real address would find the flag already
        // gone and never retry. This was caught by testReconnectDefersUntilDeviceIPArrives.
        guard pendingReconnectRepublish, artEnabled, linkUp, sonosPageEnabled,
              deviceIP != nil, let tile = currentTile else { return }
        pendingReconnectRepublish = false
        let gen = SonosArtDecision.nextGen(cache.gen)
        armAndEmit(urlString: cache.lastImageUrl, tile: tile, gen: gen)
    }

    private func armAndEmit(urlString: String?, tile: SonosArtRenderer.Tile, gen: UInt32) {
        guard let peer = deviceIP else {
            log("arm DEFERRED: no device IP yet")
            return   // the caller retries later
        }
        server.arm(tile.pixels, contentType: Self.contentType, peer: peer,
                  ttl: Self.armTTL, maxServes: Self.armMaxServes) { [weak self] result in
            self?.queue.async { self?.applyArmResult(result, urlString: urlString, tile: tile, gen: gen) }
        }
    }

    private func applyArmResult(_ result: Result<URL, LanAssetServer.ArmError>, urlString: String?,
                                tile: SonosArtRenderer.Tile, gen: UInt32) {
        switch result {
        case .success(let url):
            log("armed gen=\(gen) serving on port \(url.port.map(String.init) ?? "?")")
            cache.gen = gen
            cache.lastImageUrl = urlString
            cache.lastTileDigest = tile.sha256Hex
            cache.lastPublishedAt = now()
            currentTile = tile
            if let data = try? SonosArtFrame(gen: gen, url: url.absoluteString).encoded() {
                onFrame?(data)
            }
        case .failure(let err):
            log("arm FAILED \(err)")
            // Could not arm (no routable interface, listener failed, already armed) -- tell the device
            // plainly rather than leave it showing stale art (design §8: "on any art failure, publish
            // S2, not silence").
            commitClear()
        }
    }

    private func commitClear() {
        let gen = SonosArtDecision.nextGen(cache.gen)
        cache.gen = gen
        cache.lastImageUrl = nil
        cache.lastTileDigest = nil
        currentTile = nil
        if let data = try? SonosArtFrame(gen: gen).encoded() {
            onFrame?(data)
        }
    }
}

extension LanAssetServer: SonosArtPublisher.Arming {}
