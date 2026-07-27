import Foundation
import BeaconHubKit

// Normalized Sonos now-playing -- the ONLY shape that crosses out of SonosProvider (design
// 2026-07-26-sonos-now-playing-plan step 3; AGENTS.md "credentials never reach the device", generalized
// here to "provider JSON never reaches the device" -- SonosAPI's raw Sonos response types stop at this
// struct's constructor).
struct SonosNowPlaying: Equatable {
    let room: String
    let track: String?
    let artist: String?
    let album: String?
    let playing: Bool
}

// Resolves the Sonos household/groups, polls the selected room's playback metadata, and reports a
// normalized SonosNowPlaying via `onUpdate` whenever it changes (design 2026-07-26-sonos-now-playing-plan
// steps 3-4). Owns its own OAuth refresh (mirrors ClaudeTokenRefresher's direct-refresh idiom) and its own
// poll-gate backoff (mirrors ClaudeCodeProvider.noteUsageOutcome/shouldPollUsage exactly, including field
// names, for the same reason: a network-reached terminal must stop the retry loop, not just be logged --
// see SonosOutcomeClassifier's doc comment and issue #7).
//
// Deliberately NOT an AgentProvider/UsagePoller participant: those planes are session/prompt/quota-window
// specific, and forcing a fourth (now-playing) concern through ProviderMux would mean modeling a plane it
// does not otherwise have, for a value shape (room/track/artist/album/playing) that plane was never built
// to carry. SonosProvider drives its own timer instead, the same way ClaudeCodeProvider's transcript
// scanner drives its own.
//
// `onUpdate`'s payload is deliberately the raw tuple the plan's brief specifies, not a wire/frame type: a
// separate agent owns SonosFrame encoding in BeaconHubKit, and this file must not define one (that would
// be two agents inventing the same type in parallel). AppDelegate.pushSonosFrame is the single marked
// integration point where the two meet.
final class SonosProvider {
    var onUpdate: ((_ room: String, _ track: String?, _ artist: String?, _ album: String?, _ playing: Bool) -> Void)?
    // Additive observation hook (design 2026-07-26-sonos-setup-ui): fires with every classified outcome
    // alongside noteOutcome's own gate bookkeeping below, unchanged. Lets the Settings UI surface the SAME
    // live failure reason (401/403/network/etc., already classified by SonosOutcomeClassifier) the poll
    // gate computed, instead of a second guess at the same condition -- see SonosSetupState.derive. Does
    // not participate in fails/backoffUntil and cannot affect SonosGateTests, which never sets it (nil by
    // default, so the extra call below is a no-op there).
    var onOutcome: ((ProviderOutcome) -> Void)?

    private let session: URLSession
    private let queue = DispatchQueue(label: "beacon.sonos")
    private var timer: DispatchSourceTimer?
    private let interval: TimeInterval
    private let roomStore: SonosRoomStore

    // Queue-confined poll state.
    private var cachedCredential: SonosCredential?
    private var householdId: String?
    private var groupCache: (room: String, group: SonosAPI.Group)?
    private var lastSent: SonosNowPlaying?
    private var refreshing = false

    // Poll gate (lock-protected, not queue-confined: mirrors ClaudeCodeProvider's gateLock so a future
    // caller could read/note outcomes off-queue too, and so SonosGateTests can drive it directly).
    private let gateLock = NSLock()
    private var fails = 0
    private var backoffUntil: Date?
    private let backoffCap: TimeInterval = 900
    private let retryAfterSanityCap: TimeInterval = 3600

    init(session: URLSession = .shared, interval: TimeInterval = 5, roomStore: SonosRoomStore = SonosRoomStore()) {
        self.session = session
        self.interval = interval
        self.roomStore = roomStore
    }

    func start() {
        queue.async { [weak self] in self?.scheduleTimer() }
    }

    func stop() {
        queue.async { [weak self] in self?.timer?.cancel(); self?.timer = nil }
    }

    // The room-picker UI (a separate agent's work) calls this: persists immediately and drops the cached
    // group so the next tick re-resolves against the NEW room instead of polling the old one under a
    // stale cache hit.
    func setSelectedRoom(_ room: String?) {
        roomStore.selectedRoom = room
        queue.async { [weak self] in self?.groupCache = nil }
    }

    private func scheduleTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard shouldPoll(now: Date()) else { return }
        poll(now: Date())
    }

    // --- poll gate (mirrors ClaudeCodeProvider.noteUsageOutcome/shouldPollUsage) ---

    // Internal (not private) so SonosGateTests exercises the gating contract directly, the same way
    // ClaudeUsageGateTests exercises ClaudeCodeProvider.noteUsageOutcome/shouldPollUsage.
    func noteOutcome(_ outcome: ProviderOutcome) {
        onOutcome?(outcome)
        gateLock.lock(); defer { gateLock.unlock() }
        switch outcome {
        case .live:
            fails = 0; backoffUntil = nil
        case .transient(let retryAfter, _):
            fails += 1
            let delay = UsagePollDecision.pollDelay(consecutiveFails: fails, retryAfter: retryAfter,
                                                    base: interval, cap: backoffCap,
                                                    retryAfterSanityCap: retryAfterSanityCap,
                                                    jitterFraction: Double.random(in: -0.2...0.2))
            backoffUntil = Date().addingTimeInterval(delay)
        case .terminal:
            // A terminal reached THROUGH the network (401/403) must not be re-issued next tick -- see
            // SonosOutcomeClassifier's doc comment. Gate at the cap; a fixed credential is retried once it
            // lapses (self-heals without a hub restart, same contract as Claude's gate).
            backoffUntil = Date().addingTimeInterval(backoffCap)
        case .inactive:
            break   // "no room selected yet" -- cheap to recheck every tick, nothing to back off from.
        }
    }

    func shouldPoll(now: Date) -> Bool {
        gateLock.lock(); defer { gateLock.unlock() }
        return !(backoffUntil.map { now < $0 } ?? false)
    }

    // --- poll pipeline ---

    private func poll(now: Date) {
        guard let secret = SonosKeychain.readSecret() else {
            noteOutcome(.terminal(reason: "Sonos client secret missing - run set-sonos-secret", kind: .missingCredential))
            return
        }
        guard let cred = credential() else {
            noteOutcome(.terminal(reason: "Sonos not connected - run sonos-authorize", kind: .missingCredential))
            return
        }
        guard let room = roomStore.selectedRoom, !room.isEmpty else {
            noteOutcome(.inactive(reason: "Sonos: no room selected"))
            return
        }
        if cred.isExpired(at: now) {
            guard cred.refreshTokenAlive, let refreshToken = cred.refreshToken else {
                noteOutcome(.terminal(reason: "Sonos session expired - re-run sonos-authorize", kind: .staleToken))
                return
            }
            guard !refreshing else { return }   // a refresh from a prior tick is still in flight
            refreshing = true
            SonosOAuth.refresh(refreshToken: refreshToken, secret: secret, session: session) { [weak self] result in
                guard let self else { return }
                self.queue.async { self.applyRefresh(result, fallbackRefreshToken: refreshToken, room: room) }
            }
            return
        }
        resolveAndFetch(room: room)
    }

    private func applyRefresh(_ result: Result<SonosCredential, SonosAuthError>, fallbackRefreshToken: String, room: String) {
        refreshing = false
        switch result {
        case .success(let fresh):
            let mergedRefresh = fresh.refreshToken ?? fallbackRefreshToken
            guard let blob = ProviderCredentials.sonosBlob(accessToken: fresh.accessToken, expiresAt: fresh.expiresAt,
                                                           refreshToken: mergedRefresh),
                  SonosKeychain.writeOAuthBlob(blob)
            else {
                noteOutcome(.terminal(reason: "Sonos token refresh: could not persist", kind: .other))
                return
            }
            cachedCredential = ProviderCredentials.parseSonos(blob)
            resolveAndFetch(room: room)
        case .failure:
            noteOutcome(.terminal(reason: "Sonos token refresh failed - re-run sonos-authorize", kind: .staleToken))
        }
    }

    private func credential() -> SonosCredential? {
        if let cachedCredential { return cachedCredential }
        guard let blob = SonosKeychain.readOAuthBlob(), let c = ProviderCredentials.parseSonos(blob) else { return nil }
        cachedCredential = c
        return c
    }

    private func resolveAndFetch(room: String) {
        if let cache = groupCache, cache.room == room {
            fetchNowPlaying(room: room, group: cache.group)
            return
        }
        fetchHouseholdIfNeeded { [weak self] householdId in
            guard let self, let householdId else { return }   // a failure already called noteOutcome
            self.fetchGroups(householdId: householdId, room: room)
        }
    }

    // --- HTTP: one small helper the three endpoints share ---

    private struct APIResult { let status: Int; let data: Data?; let retryAfter: TimeInterval?; let networkError: String? }

    private func api(path: String, completion: @escaping (APIResult) -> Void) {
        guard let cred = cachedCredential, let url = URL(string: "\(SonosAPI.base)/\(path)") else {
            completion(APIResult(status: -1, data: nil, retryAfter: nil, networkError: "no credential"))
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(cred.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, resp, err in
            if let err {
                completion(APIResult(status: -1, data: nil, retryAfter: nil, networkError: err.localizedDescription))
                return
            }
            let http = resp as? HTTPURLResponse
            let retryAfter = RetryAfter.parse(http?.value(forHTTPHeaderField: "Retry-After"), now: Date())
            completion(APIResult(status: http?.statusCode ?? -1, data: data, retryAfter: retryAfter, networkError: nil))
        }.resume()
    }

    // status==401 clears the cached access token so the NEXT allowed poll re-reads Keychain (and, if
    // actually expired, attempts a refresh) instead of replaying the same now-known-bad token forever.
    // status==404 drops the cached group so the next poll re-resolves topology (see
    // SonosOutcomeClassifier's doc comment on why 404 is transient here, unlike 401/403).
    private func handleNonSuccess(status: Int, retryAfter: TimeInterval?, networkError: String?) {
        if let networkError {
            noteOutcome(.transient(retryAfter: nil, reason: "Sonos network error: \(networkError)"))
            return
        }
        if status == 401 { cachedCredential = nil }
        if status == 404 { groupCache = nil }
        noteOutcome(SonosOutcomeClassifier.classify(status: status, retryAfter: retryAfter))
    }

    // --- household / groups / now-playing ---

    private func fetchHouseholdIfNeeded(completion: @escaping (String?) -> Void) {
        if let householdId { completion(householdId); return }
        api(path: "households") { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard result.status == 200, result.networkError == nil, let data = result.data else {
                    self.handleNonSuccess(status: result.status, retryAfter: result.retryAfter, networkError: result.networkError)
                    completion(nil)
                    return
                }
                guard let households = SonosAPI.parseHouseholds(data), let first = households.first else {
                    self.noteOutcome(.terminal(reason: "Sonos: no household on this account", kind: .other))
                    completion(nil)
                    return
                }
                self.householdId = first.id
                completion(first.id)
            }
        }
    }

    private func fetchGroups(householdId: String, room: String) {
        api(path: "households/\(householdId)/groups") { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard result.status == 200, result.networkError == nil, let data = result.data else {
                    self.handleNonSuccess(status: result.status, retryAfter: result.retryAfter, networkError: result.networkError)
                    return
                }
                guard let parsed = SonosAPI.parseGroups(data) else {
                    self.noteOutcome(.terminal(reason: "Sonos groups: unexpected response shape", kind: .other))
                    return
                }
                guard let group = SonosAPI.findGroup(room: room, in: parsed) else {
                    // Not a broken credential -- the room may just be off/renamed right now. Transient so
                    // it is retried at the base cadence, not gated at the terminal cap.
                    self.noteOutcome(.transient(retryAfter: nil, reason: "Sonos room '\(room)' not found in current groups"))
                    return
                }
                self.groupCache = (room, group)
                self.fetchNowPlaying(room: room, group: group)
            }
        }
    }

    private func fetchNowPlaying(room: String, group: SonosAPI.Group) {
        var metaResult: APIResult?
        var stateResult: APIResult?
        let dg = DispatchGroup()
        dg.enter(); api(path: "groups/\(group.id)/playbackMetadata") { r in metaResult = r; dg.leave() }
        dg.enter(); api(path: "groups/\(group.id)/playback") { r in stateResult = r; dg.leave() }
        dg.notify(queue: queue) { [weak self] in
            guard let self, let metaResult, let stateResult else { return }
            self.combineNowPlaying(room: room, group: group, meta: metaResult, state: stateResult)
        }
    }

    private func combineNowPlaying(room: String, group: SonosAPI.Group, meta: APIResult, state: APIResult) {
        // Both legs hit the same group/credential, so a non-200 on either fails the same way; report the
        // first one found (arbitrary but deterministic) rather than both.
        for leg in [meta, state] where leg.status != 200 || leg.networkError != nil {
            handleNonSuccess(status: leg.status, retryAfter: leg.retryAfter, networkError: leg.networkError)
            return
        }
        guard let metaData = meta.data, let stateData = state.data,
              let track = SonosAPI.parsePlaybackMetadata(metaData),
              let playing = SonosAPI.parsePlaybackState(stateData)
        else {
            noteOutcome(.terminal(reason: "Sonos now-playing: unexpected response shape", kind: .other))
            return
        }
        noteOutcome(.live)
        let np = SonosNowPlaying(room: room, track: track.track, artist: track.artist, album: track.album, playing: playing)
        guard np != lastSent else { return }
        lastSent = np
        let cb = onUpdate
        DispatchQueue.main.async { cb?(np.room, np.track, np.artist, np.album, np.playing) }
    }
}
