import AppKit
import Foundation
import CryptoKit
import ServiceManagement
import BeaconHubKit

// Wires the subsystems together (design 2026-07-19): a shared LocalIngestServer + registered
// AgentProviders (Claude, Codex, omp) feed a ProviderMux, which merges per-provider usage/sessions/prompts
// into a single Usage + BuddyState + [Session]. We serialize those to StatusFrame/SessionsFrame and push
// to the device over BLE, resending the full frame on (re)connect and on a 30 s heartbeat. The usage
// poller iterates usage-enabled providers; per-provider toggles (ProviderSettings) drive live setEnabled.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menubar = MenubarController()
    private let central = BeaconCentral()
    private let mux = ProviderMux()
    private let settings = ProviderSettings(store: UserDefaults.standard)
    private let ingest = LocalIngestServer()
    private var providers: [AgentProvider] = []
    private var claude: ClaudeCodeProvider?            // typed ref for drain + device-connected + statusline
    private var codex: HookBuddyProvider?              // typed ref for drain + device-connected
    private var omp: HookBuddyProvider?                // typed ref for drain + device-connected
    private var poller: UsagePoller!                   // built once providers exist
    private var sonos: SonosProvider?                   // Sonos OAuth + polling (design 2026-07-26-sonos-now-playing-plan)
    private let sonosSetupStore = SonosSetupStore()     // persisted Client ID (design 2026-07-26-sonos-setup-ui)
    // Read-side accessor for the selected room (SonosRoomStore is a thin, stateless UserDefaults wrapper --
    // this instance and the one SonosProvider owns internally always agree, since both just read/write the
    // same "BeaconSonosSelectedRoom" key). Writes still go through `sonos?.setSelectedRoom` so the group
    // cache invalidates too; see onLoadSonosRoom/onSetSonosRoom wiring in startSonosSettings.
    private let sonosRoomStore = SonosRoomStore()
    // Most recent classified outcome SonosProvider observed, fed by its onOutcome hook -- purely for the
    // Settings status line (SonosSetupState.derive); never read by the poll gate itself.
    private var sonosLastOutcome: ProviderOutcome?
    // Fingerprint of the Sonos Keychain items as of the last check (Defect 1, CLI half): `set-sonos-secret`
    // and `sonos-authorize` run as a SEPARATE process (main.swift) from this already-running hub, so there
    // is no direct call path for that CLI to reach SonosProvider -- writing to Keychain does not notify us.
    // refreshSonosCredentialOnRefocus compares against these on every applicationDidBecomeActive (the user
    // clicking the menubar icon after running a CLI subcommand counts) and only resets the gate on an
    // ACTUAL change -- see that method for why an unconditional reset on every refocus is not an option.
    // SHA-256 digests, never the values themselves: change detection only needs to know whether the bytes
    // differ, so there is no reason to keep a client secret and an OAuth token resident in process memory
    // for the app's whole lifetime. SonosProvider caches a credential because it must send it; this does
    // not. Public repo, and the rest of this flow is careful about the same thing (stdin not argv, only a
    // character count echoed back) -- holding plaintext here purely to compare it would be out of step.
    private var sonosLastObservedSecretDigest: String?
    private var sonosLastObservedOAuthDigest: String?

    private static func sonosCredDigest(_ data: Data?) -> String? {
        guard let data else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func sonosCredDigest(_ text: String?) -> String? {
        sonosCredDigest(text.map { Data($0.utf8) })
    }
    private let location = LocationProvider()
    private let tickerStore = TickerConfigStore()   // desired ticker list + monotonic rev (issue #92)
    private let pageStore = PageConfigStore()      // which device pages, in what order (+ monotonic rev)
    private var reportAssembler = ReportAssembler()   // reassembles device->hub ticker report chunks (#105)
    private let tickerSearch = TickerSearch()        // Binance(cached) + Yahoo(live) discovery (issue #92 B4)
    private lazy var tickerEditor = TickerEditorWindowController(model: menubar.viewModel)
    private lazy var settingsWindow = SettingsWindowController(model: menubar.viewModel)
    private lazy var pageDesigner = PageDesignerWindowController(model: menubar.viewModel)
    private var binanceCandidates: [TickerCandidate] = []   // warmed-once cache for local Binance filtering

    // A single ephemeral session (15s timeout) shared by every provider's usage source (#64).
    private let usageSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    // Latest known state -- the source of truth we (re)send on heartbeat/reconnect.
    private var usage = Usage()          // merged provider array (from the mux); resent on heartbeat
    private var buddy = BuddyState()
    private var sessions: [Session] = []
    private var sessionDetails: [SessionDetail] = []   // resent on (re)connect alongside `sessions`
    // Latest normalized Sonos now-playing (resent on reconnect, same as sessions/sessionDetails above);
    // nil until the poller has resolved a room and gotten a live result at least once.
    private var sonosNowPlaying: (room: String, track: String?, artist: String?, album: String?, playing: Bool)?
    private var lastFix: Loc?   // most recent CoreLocation fix (issue #54); rides the (re)connect full frame
    private var heartbeat: Timer?

    // Per-provider usage reliability (#108). Any LIVE value (oauth poll or, for Claude, statusline
    // rate_limits) becomes last-known-good; a transient failure serves last-good as STALE. Keyed by id
    // so the reducer generalizes across providers. maxStale = 30 min.
    private let maxStale: TimeInterval = 1800
    private let inactiveThreshold: TimeInterval = 48 * 3600   // #126: demote an abandoned Claude to a quiet note
    private var descriptors: [String: ProviderDescriptor] = [:]
    private var registrationOrder: [String] = []
    private var retentions: [String: ProviderRetention] = [:]
    private var displays: [String: ProviderUsage] = [:]
    private var notes: [String: UsageNote] = [:]
    // Claude-only: its authoritative statusline source takes precedence over a late oauth poll (#93).
    private var statuslineClaude: ProviderUsage?   // #59 dedup
    // #93 source-precedence gate + #126 abandonment signal, persisted across launches: an in-memory-only
    // timestamp resets to nil every launch, making an abandoned Claude indistinguishable from a just-
    // launched active one, so the demotion could only lean on a long expiry gate. Persisting it lets a
    // returning active user carry a recent last-activity time and never be wrongly demoted. 0/absent => nil.
    private static let statuslineClaudeAtKey = "BeaconStatuslineClaudeAt"
    private var statuslineClaudeAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.statuslineClaudeAtKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.statuslineClaudeAtKey) }
    }
    private var claudeTransientReason: String?     // #108 backoff-window recheck reason
    // Per-provider hooks/setup state surfaced in the Settings window; AppDelegate owns the truth so a
    // toggle-driven refreshProviderToggles never clobbers a transient install spinner/note.
    private var providerHooks: [String: CheckState] = [:]
    private var providerInstalling: Set<String> = []
    private var providerNote: [String: String] = [:]
    private var checkBluetooth: CheckState = .checking
    private var checkPaired: CheckState = .checking

    func applicationDidFinishLaunching(_ notification: Notification) {
        startProviders()
        startCentral()
        startPoller()
        // Wire Sonos (onLoadSonosSetup/onAuthorizeSonos/...) BEFORE startSettings(): the latter can
        // auto-open the Settings window immediately via showIfNeeded() on a not-yet-first-run-complete
        // machine, and that window is built once and reused for the app's lifetime (SettingsWindowController
        // never rebuilds it). If it opens before these closures exist, SonosSettingsSection's one-time
        // onAppear captures HubViewModel's still-default `{ .empty }` onLoadSonosSetup and -- because the
        // reused window never re-derives except via that onAppear or its own Save/Authorize actions --
        // Settings could show "Not configured" indefinitely even after the user genuinely configures and
        // authorizes Sonos through some other path (see also the didBecomeKeyNotification refresh added to
        // SonosSettingsView.swift, which is the other half of this fix: re-derive on every reopen too, not
        // just rely on ordering).
        startSonos()
        startSonosSettings()
        startSettings()
        startLoginItem()
        startLocation()
        startTickerEditor()
        menubar.setPages(ids: pageStore.current.ids, opts: pageStore.current.opts)

        // Heartbeat resends the full frame WITHOUT loc (issue #54): location rides the (re)connect frame
        // and on-change frames only, never the 30s heartbeat.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.mux.reap(); self?.sendFullFrame(includeLocation: false) }
        }
        heartbeat?.tolerance = 3   // #66 L6: let the OS coalesce the 30s heartbeat wakeup.
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Hooks can change out-of-band (manual edit) between launches; re-check on re-focus (off-main).
        refreshProviderHooks()
        refreshLoginItem()   // cheap re-sync; the menu-open refresh is the reliable path for this accessory app.
        refreshSonosCredentialOnRefocus()
    }

    // Defect 1, CLI half: see sonosLastObservedSecret/sonosLastObservedOAuthBlob's doc comment. Only an
    // ACTUAL change to either Keychain item resets the gate -- comparing every refocus and resetting
    // unconditionally would re-issue a request against a genuinely-still-broken credential on every single
    // app switch, which is exactly the retry-storm issue #7 already burned an hour on. A byte-identical
    // read means nothing changed and any existing gate (terminal or transient) is left exactly as it was.
    private func refreshSonosCredentialOnRefocus() {
        let secret = Self.sonosCredDigest(SonosKeychain.readSecret())
        let oauthBlob = Self.sonosCredDigest(SonosKeychain.readOAuthBlob())
        defer { sonosLastObservedSecretDigest = secret; sonosLastObservedOAuthDigest = oauthBlob }
        guard secret != sonosLastObservedSecretDigest || oauthBlob != sonosLastObservedOAuthDigest else { return }
        sonos?.resetForCredentialChange()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let drainers = [claude?.drainHeldPrompts, codex?.drainHeldPrompts, omp?.drainHeldPrompts].compactMap { $0 }
        guard !drainers.isEmpty else { return .terminateNow }
        var replied = false
        let reply = { if !replied { replied = true; NSApp.reply(toApplicationShouldTerminate: true) } }
        let group = DispatchGroup()
        for drain in drainers {
            group.enter()
            drain("Beacon hub is quitting", { group.leave() })
        }
        group.notify(queue: .main, execute: reply)
        // Safety cap so Quit never hangs if a socket write stalls; the drain replies earlier on real flush,
        // and immediately when nothing was held. A dropped conn would fail-OPEN per CONTRACT.md C.3.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { reply() }
        return .terminateLater
    }

    // --- settings window + per-provider setup ---

    private func startSettings() {
        menubar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        menubar.onInstallProviderHooks = { [weak self] id in self?.installHooks(for: id) }
        menubar.onOpenBluetooth = { SettingsLinks.open(SettingsLinks.bluetooth) }
        refreshProviderHooks()
        settingsWindow.showIfNeeded()
    }

    // Re-read every provider's hooks state off the main thread (sync file IO + parse), then apply on main
    // without stomping a provider mid-install.
    private func refreshProviderHooks() {
        let ids = providers.map { $0.descriptor.id }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let states = ids.map { ($0, HooksInstaller.isInstalled(providerID: $0)) }
            Task { @MainActor in
                guard let self else { return }
                for (id, ok) in states where !self.providerInstalling.contains(id) {
                    self.providerHooks[id] = ok ? .ok : .bad
                }
                self.refreshProviderToggles()
                self.maybeMarkComplete()
            }
        }
    }

    // Install one provider's hooks (Process-backed, off the main thread), then re-check + surface a note.
    private func installHooks(for id: String) {
        guard !providerInstalling.contains(id) else { return }
        providerInstalling.insert(id)
        providerNote[id] = nil
        refreshProviderToggles()
        let label = descriptors[id]?.label.capitalized ?? id
        Task.detached { [weak self] in
            let errorMessage: String?
            do { try HooksInstaller.install(providerID: id); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
            let ok = HooksInstaller.isInstalled(providerID: id)
            guard let self else { return }
            await MainActor.run {
                self.providerInstalling.remove(id)
                self.providerHooks[id] = ok ? .ok : .bad
                self.providerNote[id] = ok ? "Installed. Restart \(label) for hooks to take effect." : errorMessage
                self.refreshProviderToggles()
                self.maybeMarkComplete()
            }
        }
    }

    // First-run auto-open stops once Bluetooth + pairing + every provider's hooks are satisfied.
    private func maybeMarkComplete() {
        let hooksOk = providers.allSatisfy { (providerHooks[$0.descriptor.id] ?? .checking) == .ok }
        if checkBluetooth == .ok, checkPaired == .ok, hooksOk { settingsWindow.markComplete() }
    }

    // --- login item (issue #16) ---

    private func startLoginItem() {
        menubar.onToggleLoginItem = { [weak self] on in self?.applyLoginItem(on) }
        menubar.onMenuWillOpen = { [weak self] in self?.refreshLoginItem() }
        menubar.onForgetDevice = { [weak self] in self?.forgetDevice() }
        refreshLoginItem()
    }

    // Map SMAppService.Status onto the UI enum so MenubarController never imports ServiceManagement.
    private func loginItemStatus() -> MenubarController.LoginItemStatus {
        switch LoginItem.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        default:                return .disabled   // .notRegistered/.notFound => off.
        }
    }

    private func refreshLoginItem() { menubar.setLoginItemState(loginItemStatus()) }

    private func applyLoginItem(_ on: Bool) {
        do { try LoginItem.setEnabled(on) }
        catch { showGuidance("Couldn't change the login item", info: error.localizedDescription) }
        refreshLoginItem()   // always re-read truth; never trust the requested value (ad-hoc signing).
        if loginItemStatus() == .requiresApproval {
            showGuidance("Approve Beacon to start at login",
                         info: "Open System Settings > General > Login Items and turn Beacon on.")
        }
    }

    // One-shot informational dialog for a user-initiated action (login-item / forget-device). NOT the
    // persistent menu-bar `alert` slot -- that one is the undeliverable-prompt surface (it appends
    // "couldn't show prompt" and is cleared by reconnect), so reusing it here mis-worded the message and
    // left a stale warning after the user fixed things. A modal dismissed by the user has no stale state.
    private func showGuidance(_ message: String, info: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    // --- forget device / re-pair (issue #16) ---

    private func forgetDevice() {
        central.forgetAndRescan()
        // CoreBluetooth cannot clear the OS bond (no API); the app-side reset drops the link + rescans, so
        // a healthy bond reconnects on its own. The real "forget" is the user removing Beacon in Bluetooth
        // settings, so we jump straight there (the Settings window spells out the two clicks).
        SettingsLinks.open(SettingsLinks.bluetooth)
    }

    // --- providers + mux ---

    private func startProviders() {
        // Wire mux outputs FIRST so the initial register() emit (seeded usage / empty buddy) is captured.
        mux.onUsage = { [weak self] merged in
            guard let self else { return }
            self.usage = merged
            self.sendFrame(StatusFrame(usage: merged))
        }
        mux.onBuddy = { [weak self] state in self?.onBuddy(state) }
        mux.onSessions = { [weak self] sessions in
            guard let self else { return }
            self.sessions = sessions
            self.menubar.viewModel.sessions = sessions   // feeds the page designer's Agents/Home previews
            if let data = try? SessionsFrame(sessions).encoded() { self.central.send(data) }
        }
        // Own frame, own budget: the sessions frame's caps are frozen and have no room for title/message.
        mux.onSessionDetails = { [weak self] details in
            guard let self else { return }
            self.sessionDetails = details
            self.menubar.viewModel.sessionDetails = details
            if let data = try? SessionDetailsFrame(details).encoded() { self.central.send(data) }
        }
        mux.onAttention = { [weak self] in self?.menubar.playAttentionSoundIfEnabled() }
        mux.onPromptArrived = { [weak self] in self?.menubar.playPromptSoundIfEnabled() }
        mux.resolvePromptHandler = { [weak self] pid, nid, approve in
            guard let self, let p = self.providers.first(where: { $0.descriptor.id == pid })
            else { return .unknown }
            return p.resolvePrompt(nativeID: nid, approve: approve)
        }

        ingest.onStatus = { [weak self] msg in Task { @MainActor in self?.menubar.setBridgeAlert(msg) } }

        let claude = ClaudeCodeProvider(server: ingest, usageSession: usageSession)
        claude.onClaudeUsage = { [weak self] c in Task { @MainActor in self?.onStatuslineClaude(c) } }
        claude.onStatuslineActivity = { [weak self] in Task { @MainActor in self?.onStatuslineActivity() } }
        // Providers report a prompt they couldn't show (device offline); the message already names the
        // agent. Cleared on reconnect in refreshLink.
        let undeliverable: (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.menubar.setAlert(message) }
        }
        claude.onPromptUndeliverable = undeliverable
        self.claude = claude

        // No .usage, same as Claude: Codex's token is only refreshed by the `codex` CLI, so on a machine
        // that has not run it the access token is long expired and its usage endpoint cannot answer.
        let codex = HookBuddyProvider(
            descriptor: ProviderDescriptor(id: "codex", label: "CODEX",
                                           capabilities: [.sessions, .prompts]),
            routePath: CodexHooks.routePath,
            capSeconds: 575,
            server: ingest,
            usageSource: nil)
        codex.onPromptUndeliverable = undeliverable
        self.codex = codex

        // omp: buddy plane only (no usage entry -- omp quota reports duplicate Claude/Codex). Fed by the
        // managed beacon.ts extension -> /omp/hook. Cap 26s: device 25 < hub 26 < fetch 28 < omp 30.
        let omp = HookBuddyProvider(
            descriptor: ProviderDescriptor(id: "omp", label: "OMP",
                                           capabilities: [.sessions, .prompts]),
            routePath: OmpHooks.routePath,
            capSeconds: 26,
            server: ingest)
        omp.onPromptUndeliverable = undeliverable
        self.omp = omp
        providers = [claude, codex, omp]

        for p in providers {
            descriptors[p.descriptor.id] = p.descriptor
            registrationOrder.append(p.descriptor.id)
            let caps = settings.enabled(for: p.descriptor.id)
            mux.register(p.descriptor, enabled: caps)
            p.start(sink: mux)          // registers ingest routes before ingest.start()
            p.setEnabled(caps)          // apply a persisted-off buddy state on launch
        }
        ingest.start()

        // Provider toggle cards: seed + wire live setEnabled.
        menubar.onSetProviderUsage = { [weak self] id, on in self?.setProviderUsage(id, on) }
        menubar.onSetProviderBuddy = { [weak self] id, on in self?.setProviderBuddy(id, on) }
        refreshProviderToggles()
        pushMenubarUsage()
    }

    private func refreshProviderToggles() {
        let toggles = providers.map { p -> ProviderToggle in
            let id = p.descriptor.id
            let e = settings.enabled(for: id)
            return ProviderToggle(id: id, label: p.descriptor.label.capitalized,
                                  supportsUsage: p.descriptor.supportsUsage,
                                  supportsBuddy: p.descriptor.supportsBuddy,
                                  usageOn: e.usage, buddyOn: e.buddy,
                                  hooks: providerHooks[id] ?? .checking,
                                  installing: providerInstalling.contains(id),
                                  note: providerNote[id])
        }
        menubar.setProviderToggles(toggles)
    }

    private func setProviderUsage(_ id: String, _ on: Bool) { settings.setUsage(on, for: id); applyEnabled(id) }
    private func setProviderBuddy(_ id: String, _ on: Bool) { settings.setBuddy(on, for: id); applyEnabled(id) }

    private func applyEnabled(_ id: String) {
        let caps = settings.enabled(for: id)
        // Usage off: drop the retained note/retention/reason so a stale banner cannot resurface on
        // re-enable (#126). statuslineClaudeAt (liveness) and statuslineClaude (value cache, kept synced
        // by the ungated handler path) are intentionally preserved so re-enable is immediately correct.
        if !caps.usage {
            notes.removeValue(forKey: id)
            retentions.removeValue(forKey: id)
            if id == "claude" { claudeTransientReason = nil }
        }
        mux.setEnabled(id, caps)
        providers.first { $0.descriptor.id == id }?.setEnabled(caps)
        refreshProviderToggles()
        pushMenubarUsage()   // a usage toggle re-includes/excludes the provider's card immediately
    }

    // --- sonos (OAuth + polling provider; the BLE frame encoder is owned by a separate agent) ---

    private func startSonos() {
        // Seed the refocus fingerprint (Defect 1, CLI half) so the FIRST applicationDidBecomeActive after
        // launch does not see a spurious nil -> already-there "change" and fire an unnecessary reset.
        sonosLastObservedSecretDigest = Self.sonosCredDigest(SonosKeychain.readSecret())
        sonosLastObservedOAuthDigest = Self.sonosCredDigest(SonosKeychain.readOAuthBlob())
        rebuildSonosProvider()
    }

    // Tear down and reconstruct the provider (design 2026-07-26-sonos-setup-ui): also called by
    // Disconnect/Clear-secret so a credential change from the UI is not still served out of
    // SonosProvider's in-memory cachedCredential/groupCache -- rebuilding forces a fresh Keychain read on
    // the very next poll tick, without touching SonosProvider's own logic at all. The room selection
    // survives (SonosRoomStore reads the same UserDefaults key regardless of which SonosProvider instance
    // owns it).
    private func rebuildSonosProvider() {
        sonos?.stop()
        let provider = SonosProvider(session: usageSession)
        provider.onUpdate = { [weak self] room, track, artist, album, playing in
            Task { @MainActor in
                self?.sonosNowPlaying = (room, track, artist, album, playing)
                self?.pushSonosFrame()
            }
        }
        provider.onOutcome = { [weak self] outcome in
            Task { @MainActor in self?.sonosLastOutcome = outcome }
        }
        sonos = provider
        provider.start()
    }

    // --- sonos setup UI (design 2026-07-26-sonos-setup-ui) ---

    private func startSonosSettings() {
        menubar.viewModel.onLoadSonosSetup = { [weak self] in self?.sonosSnapshot() ?? .empty }
        menubar.viewModel.onSaveSonosClientID = { [weak self] value in
            self?.sonosSetupStore.storedClientID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        menubar.viewModel.onSaveSonosSecret = { [weak self] secret in
            guard SonosSecretValidation.isValid(secret) else { return .refused(SonosSecretValidation.refusalMessage) }
            guard SonosKeychain.writeSecret(secret) else { return .keychainWriteFailed }
            self?.sonosLastObservedSecretDigest = Self.sonosCredDigest(secret)   // keep the refocus fingerprint in sync; see its doc comment
            return .saved(charCount: secret.count)
        }
        menubar.viewModel.onAuthorizeSonos = { [weak self] progress, completion in
            // SonosAuthorizer.authorize never blocks; its own completion already lands on an unspecified
            // background queue (URLSession/NWListener callback queues), so hop to the main actor before
            // touching AppDelegate/HubViewModel state rather than assume the caller already did.
            SonosAuthorizer.authorize(progress: { stage in
                Task { @MainActor in progress(stage) }
            }, completion: { result in
                Task { @MainActor in
                    // Defect 1 (live bug): a fresh authorization must start polling NOW, not sit out
                    // whatever gate a prior missing-credential launch already raised (up to 900s) nor wait
                    // for an app restart. resetForCredentialChange clears the gate's CONSEQUENCE the same
                    // way `.live` does and forces an immediate re-check -- it does not touch the terminal/
                    // transient classification or the backoff curve (see SonosProvider.resetForCredentialChange
                    // and SonosGateTests.testCredentialChangeClearsTheGate). Also covers re-authorizing
                    // after a Disconnect: rebuildSonosProvider already swaps in a fresh SonosProvider there,
                    // and this call targets whichever instance is current.
                    if case .success = result {
                        self?.sonos?.resetForCredentialChange()
                        self?.sonosLastObservedOAuthDigest = Self.sonosCredDigest(SonosKeychain.readOAuthBlob())   // keep the fingerprint in sync
                    }
                    completion(result)
                }
            })
        }
        menubar.viewModel.onDisconnectSonos = { [weak self] in
            guard let self else { return }
            SonosKeychain.deleteOAuthBlob()
            self.sonosNowPlaying = nil
            self.sonosLastOutcome = nil
            self.sonosLastObservedOAuthDigest = nil   // keep the refocus fingerprint in sync; see its doc comment
            self.rebuildSonosProvider()
        }
        menubar.viewModel.onClearSonosSecret = { [weak self] in
            guard let self else { return }
            SonosKeychain.deleteSecret()
            self.sonosNowPlaying = nil
            self.sonosLastOutcome = nil
            self.sonosLastObservedSecretDigest = nil   // keep the refocus fingerprint in sync; see its doc comment
            self.rebuildSonosProvider()   // the stored secret is gone too -- stop polling with it
        }
        // Defect 2: the Page Designer's room picker (PageDesignerView.swift) calls this to populate itself
        // from the real household -- see SonosProvider.fetchAvailableRooms's doc comment for why this is a
        // separate, read-only path rather than reusing fetchHouseholdIfNeeded/fetchGroups.
        menubar.viewModel.onFetchSonosRooms = { [weak self] completion in
            guard let self, let sonos = self.sonos else { completion(.notAuthorized); return }
            sonos.fetchAvailableRooms(completion: completion)
        }
        // The room is PROVIDER state, not page-presentation state (see the doc comment on
        // onLoadSonosRoom/onSetSonosRoom in HubViewModel): read directly from SonosRoomStore, and apply
        // immediately through SonosProvider.setSelectedRoom -- independent of Save & push and of whether
        // the Sonos page happens to be enabled, so a disabled page can never strip it.
        menubar.viewModel.onLoadSonosRoom = { [weak self] in self?.sonosRoomStore.selectedRoom }
        menubar.viewModel.onSetSonosRoom = { [weak self] room in self?.sonos?.setSelectedRoom(room) }
    }

    // Everything the Settings UI needs to render the Sonos section, assembled fresh on every call
    // (Keychain + UserDefaults reads are cheap and local -- see HubViewModel.onLoadSonosSetup).
    private func sonosSnapshot() -> SonosSetupSnapshot {
        let stored = sonosSetupStore.storedClientID
        let env = ProcessInfo.processInfo.environment["SONOS_CLIENT_ID"]
        let effective = SonosClientID.resolve(stored: stored, env: env)
        let secret = SonosKeychain.readSecret()
        let credential = SonosKeychain.readOAuthBlob().flatMap { ProviderCredentials.parseSonos($0) }
        let status = SonosSetupState.derive(secretStored: secret != nil, credential: credential,
                                            lastOutcome: sonosLastOutcome, now: Date())
        return SonosSetupSnapshot(storedClientID: stored, effectiveClientID: effective,
                                  usingEnvOverride: stored.isEmpty && !(env ?? "").isEmpty,
                                  secretStored: secret != nil, secretCharCount: secret?.count ?? 0,
                                  status: status)
    }

    private func pushSonosFrame() {
        guard let np = sonosNowPlaying else { return }
        let payload = BeaconHubKit.SonosNowPlaying(room: np.room, track: np.track, artist: np.artist,
                                                   album: np.album, playing: np.playing)
        if let data = try? SonosFrame(payload).encoded() { central.send(data) }
    }

    // --- central ---

    private func startCentral() {
        central.onPhaseChange = { [weak self] phase in
            Task { @MainActor in self?.refreshLink(phase) }
        }
        central.onReady = { [weak self] in
            // Link state is refreshed by the isConnected didSet's onPhaseChange (fires just before
            // this); onReady only resends the full frame to a freshly-(re)subscribed device. The
            // (re)connect frame carries the cached location fix (issue #54). Push the ticker config after
            // the full frame so a rebooted/re-bonded device re-syncs its list (issue #92).
            Task { @MainActor in
                self?.reportAssembler.reset()   // discard any partial device report from a prior connection (#105)
                self?.sendFullFrame(includeLocation: true)
                if let data = try? SessionsFrame(self?.sessions ?? []).encoded() { self?.central.send(data) }
                // Without this the device redraws its rows on reconnect with no project/title/message.
                if let data = try? SessionDetailsFrame(self?.sessionDetails ?? []).encoded() { self?.central.send(data) }
                self?.pushTickerConfig()
                self?.pushPageConfig()
                self?.pushSonosFrame()   // resend the latest Sonos now-playing on (re)connect, same as sessions/sdetail above
            }
        }
        central.onCommand = { [weak self] cmd in
            Task { @MainActor in self?.handle(cmd) }
        }
        menubar.onRetryPairing = { [weak self] in self?.central.retryPairing() }
        menubar.viewModel.onApplyPages = { [weak self] ids, opts in self?.applyPageEdit(ids: ids, opts: opts) }
        menubar.viewModel.onOpenPages = { [weak self] in self?.pageDesigner.show() }
        // Revert re-seeds the editor from the store, which is the list the device is running.
        menubar.viewModel.onRevertPages = { [weak self] in
            guard let self else { return }
            self.menubar.setPages(ids: self.pageStore.current.ids, opts: self.pageStore.current.opts)
            self.menubar.setPageSync(nil)
        }
        menubar.onApplyTickerEdit = { [weak self] rows in self?.applyTickerEdit(rows) }
        central.start()
    }

    // `phase` is computed on BeaconCentral's queue (no cross-thread read of the link state).
    private func refreshLink(_ phase: LinkPhase) {
        let link: MenubarController.Link
        switch phase {
        case .bluetoothOff:        link = .bluetoothOff
        case .unauthorized:        link = .unauthorized
        case .unavailable:         link = .unavailable
        case .searching:           link = .searching
        case .connecting(let n):   link = .connecting(n)
        case .connected(let n):    link = .connected(n)
        case .reconnecting:        link = .reconnecting
        case .pairingFailed:       link = .pairingFailed
        }
        menubar.setLink(link)
        let connected: Bool = { if case .connected = phase { return true } else { return false } }()
        if connected {
            menubar.setAlert(nil)   // device reachable again => clear any undeliverable-prompt alert.
        }
        claude?.setDeviceConnected(connected)
        codex?.setDeviceConnected(connected)
        omp?.setDeviceConnected(connected)
        poller.setDeviceConnected(connected)   // #64: back off the usage poll cadence while disconnected.

        // Drive the Settings connection checks from the SAME phase stream (no second CBCentralManager):
        // Bluetooth is bad only when powered-off/unauthorized/unavailable; paired tracks live .connected.
        switch phase {
        case .bluetoothOff, .unauthorized, .unavailable: checkBluetooth = .bad
        default:                                          checkBluetooth = .ok
        }
        checkPaired = connected ? .ok : .bad
        menubar.setBluetoothCheck(checkBluetooth)
        menubar.setPairedCheck(checkPaired)
        maybeMarkComplete()
    }

    private func handle(_ cmd: DeviceCommand) {
        switch cmd {
        case .permission(let id, let approve):
            // Ack the truth (issue #8): only ok:true when the decision actually applied. A late/
            // superseded decision => ok:false; an id we never minted => err.
            switch mux.resolve(shortId: id, approve: approve) {
            case .applied: central.send(HubAck.ack(id: id, ok: true))
            case .late:    central.send(HubAck.ack(id: id, ok: false))
            case .unknown: central.send(HubAck.err(id: id, reason: "unknown_prompt_id"))
            }
        case .pagesAck(let rev, let ok, let count, let err):
            // Stale acks are ignored for the same reason as configAck: a later edit already bumped the
            // rev we are tracking. The device restarts immediately after acking, so the link drops here.
            guard rev == UInt32(pageStore.current.rev) else { break }
            if ok {
                menubar.setPageSync("Applied \(count ?? 0) pages. The Beacon is restarting.")
            } else {
                menubar.setPageSync("The Beacon rejected the list: \(err ?? "unknown")")
            }
        case .configAck(let rev, let ok, let count, let err):
            // Ignore stale acks: a later edit already bumped our rev, so an ack for an older push no
            // longer reflects the desired state we're tracking (issue #92).
            guard rev == tickerStore.current.rev else { break }
            menubar.setTickerSync(ok ? .synced(count ?? tickerStore.current.rows.count)
                                     : .error(err ?? "rejected"))
        case .open(let id):
            // Route to the owning provider by short id; the provider focuses its own native session.
            guard let (pid, nativeKey) = mux.sessionRoute(shortId: id),
                  let p = providers.first(where: { $0.descriptor.id == pid }) else {
                FileHandle.standardError.write(Data("[beacon-hub] open id=\(id) -> unknown_session\n".utf8))
                central.send(HubAck.err(id: id, reason: "unknown_session"))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = p.focusSession(nativeKey: nativeKey)
                FileHandle.standardError.write(Data("[beacon-hub] open id=\(id) provider=\(pid) ok=\(ok)\n".utf8))
                DispatchQueue.main.async { self?.central.send(HubAck.ack(id: id, ok: ok)) }
            }
        case .report(_, _, _, _, _):
            switch reportAssembler.feed(cmd) {
            case .assembled(let rows): adoptDeviceReport(rows)
            case .pending, .dropped:   break
            }
        }
    }

    // --- poller ---

    private func startPoller() {
        poller = UsagePoller(providers: providers,
                             usageEnabled: { [weak self] id in self?.settings.enabled(for: id).usage ?? true })
        poller.onUpdate = { [weak self] results in Task { @MainActor in self?.onUsage(results) } }
        poller.setDeviceConnected(central.isConnected)
        poller.start()
    }

    // Per-provider poll results (#108). A provider absent from `results` was skipped this tick (gate /
    // disabled). Claude's authoritative statusline takes precedence over a late oauth poll, and when its
    // oauth poll is suppressed the retained value is still aged out so it can't pin stale past maxStale.
    private func onUsage(_ results: [String: ProviderResult]) {
        for id in registrationOrder where usageEnabled(id) {
            if id == "claude" {
                let age = statuslineClaudeAt.map { Date().timeIntervalSince($0) }
                let fresh = UsagePollDecision.statuslineFresh(age: age, interval: poller.pollInterval)
                if let r = results[id] {
                    if !fresh {
                        if case .transient(_, let reason) = r.outcome { claudeTransientReason = reason }
                        var outcome = r.outcome
                        if case .terminal(_, let kind) = outcome,
                           UsagePollDecision.providerInactive(kind: kind, statuslineAge: age,
                                                              threshold: inactiveThreshold) {
                            outcome = .inactive(reason: "Claude inactive")
                        }
                        reduce(id, outcome, r.usage)
                    }
                } else if !fresh, retentions[id]?.lastGood != nil {
                    reduce(id, .transient(retryAfter: nil,
                                          reason: claudeTransientReason ?? "Claude usage unavailable"), .unavailable)
                }
            } else if let r = results[id] {
                reduce(id, r.outcome, r.usage)
            }
        }
        pushMenubarUsage()
    }

    private func usageEnabled(_ id: String) -> Bool {
        (descriptors[id]?.supportsUsage ?? false) && settings.enabled(for: id).usage
    }

    // Liveness from Claude Code's statusline: fires on EVERY rate_limits POST (#93). A fresh POST means
    // the statusline is the live source, so re-affirm the cached value as LIVE -- clearing a stale
    // flag/note a prior oauth transient left even when the value callback was deduped (#59/#108).
    private func onStatuslineActivity() {
        statuslineClaudeAt = Date()
        guard usageEnabled("claude") else { return }
        guard let v = statuslineClaude else { return }
        var live = v; live.stale = nil
        if displays["claude"] != live {
            reduce("claude", .live, v); pushMenubarUsage()
        } else {
            retentions["claude"]?.lastGoodAt = Date()
        }
    }

    // Claude usage VALUE from the statusline rate_limits. Fed as a LIVE observation (becomes last-known-
    // good, survives a later 429). Deduped (#59).
    private func onStatuslineClaude(_ c: ProviderUsage) {
        guard c != statuslineClaude else { return }
        statuslineClaude = c
        guard usageEnabled("claude") else { return }
        reduce("claude", .live, c); pushMenubarUsage()
    }

    // Reduce one provider's observation into its retention/display/note, then feed the mux the display
    // value (the mux merges + dedups + emits the wire Usage; the BLE send rides mux.onUsage).
    private func reduce(_ id: String, _ outcome: ProviderOutcome, _ usage: ProviderUsage) {
        let prior = retentions[id] ?? ProviderRetention()
        let label = descriptors[id]?.label.capitalized ?? id
        let r = UsageReducer.reduceProvider(prior: prior, outcome: outcome, usage: usage,
                                            now: Date(), maxStale: maxStale, label: label)
        retentions[id] = r.next; displays[id] = r.display.usage
        if let note = r.display.note { notes[id] = note } else { notes.removeValue(forKey: id) }
        mux.provider(id, didUpdateUsage: r.display.usage)
    }

    // Push the merged usage + ordered notes to the menubar. The mux gates BLE frames on usage change;
    // menubar refresh is unconditional so a note-only change updates the UI without BLE traffic (#108).
    private func pushMenubarUsage() {
        let ordered = UsageReducer.visibleNotes(order: registrationOrder, notes: notes,
                                                enabled: usageEnabled)
        menubar.setUsage(usage, notes: ordered)
    }

    private func onBuddy(_ state: BuddyState) {
        guard state != buddy else { return }   // #59: the bridge already gates, but keep AppDelegate self-consistent.
        self.buddy = state
        sendFrame(StatusFrame(buddy: state))
    }

    // --- location ---

    private func startLocation() {
        location.onFix = { [weak self] fix in
            guard let self else { return }
            self.lastFix = fix
            // On-change push: a loc-only frame (the device keeps its usage/buddy). The provider only
            // fires on a meaningful change, so this is naturally throttled.
            self.sendFrame(StatusFrame(loc: fix))
        }
        location.start()
    }

    // --- frame send ---

    // `includeLocation` rides the cached fix on the (re)connect frame but is dropped on the heartbeat.
    private func sendFullFrame(includeLocation: Bool) {
        sendFrame(StatusFrame(usage: usage, buddy: buddy, loc: includeLocation ? lastFix : nil))
    }

    // --- ticker config (issue #92) ---

    // Wire the B4 editor: seed it with the persisted list, warm the Binance universe once for local
    // filtering, route the open action, and provide the merged search hook (Binance local + Yahoo live).
    private func startTickerEditor() {
        menubar.setTickerRows(tickerStore.current.rows)
        menubar.onOpenTickerEditor = { [weak self] in self?.tickerEditor.show() }
        menubar.setTickerSearch { [weak self] query, completion in self?.searchTickers(query, completion) }
        menubar.setTickerValidate { [weak self] row, completion in self?.tickerSearch.validate(row, completion: completion) }

        tickerSearch.fetchBinanceCatalog { [weak self] candidates in
            Task { @MainActor in self?.binanceCandidates = candidates }
        }
    }

    // Local Binance filter merged with a live Yahoo query: fire Yahoo, and in its completion unify it with
    // the already-cached Binance filter. Both deliver on the main actor so the editor mutates @State safely.
    private func searchTickers(_ query: String, _ completion: @escaping ([TickerCandidate]) -> Void) {
        let binance = BinanceCatalog.search(query, in: binanceCandidates)
        tickerSearch.searchYahoo(query) { yahoo in
            Task { @MainActor in completion(TickerMerge.unify(binance: binance, yahoo: yahoo)) }
        }
    }

    // Commit an edit from the menubar editor (B4): persist (bumps rev) then push the new snapshot. Mirror
    // the persisted list back to the view model so the editor reflects exactly what was saved.
    func applyTickerEdit(_ rows: [TickerRow]) {
        tickerStore.save(rows: rows)
        menubar.setTickerRows(tickerStore.current.rows)
        pushTickerConfig()
    }

    // Adopt the device's reported ticker list on a fresh pairing (issue #105): only when our store is
    // pristine (rev 0, no rows) -- otherwise the hub stays the source of truth and its onReady push
    // reconciles the device. Persist (rev 0 -> 1) + refresh the panel; do NOT push back (the device
    // already has this list -- pushing would be a pointless echo).
    private func adoptDeviceReport(_ rows: [TickerRow]) {
        guard tickerStore.current.isPristine else { return }
        tickerStore.save(rows: rows)
        menubar.setTickerRows(tickerStore.current.rows)
        menubar.setTickerSync(.synced(tickerStore.current.rows.count))
    }

    // Push the current desired list as ordered chunk frames. Skip when not connected or the list is empty
    // (the firmware rejects an empty assembled snapshot, and ConfigFrame.chunks returns [] for it).
    private func pushTickerConfig() {
        guard central.isConnected, !tickerStore.current.rows.isEmpty else { return }
        do {
            let frames = try ConfigFrame.chunks(rows: tickerStore.current.rows, rev: tickerStore.current.rev)
            for frame in frames { central.send(frame) }
            menubar.setTickerSync(.pending)
        } catch {
            FileHandle.standardError.write(Data("[beacon-hub] ticker config encode failed: \(error.localizedDescription)\n".utf8))
            menubar.setTickerSync(.error("encode failed"))
        }
    }

    // Push the chosen page list. No-ops while pristine (rev 0): applying a page list RESTARTS the device,
    // so an untouched hub must never reboot it just for connecting.
    private func pushPageConfig() {
        guard central.isConnected, let frame = pageStore.frame() else { return }
        guard frame.fitsFrame() else {
            FileHandle.standardError.write(Data("[beacon-hub] page config exceeds HUB_FRAME_MAX; not sent\n".utf8))
            return
        }
        do { central.send(try frame.encoded()) }
        catch {
            FileHandle.standardError.write(Data("[beacon-hub] page config encode failed: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Apply a new page order/selection from the UI: persist, bump the rev, push.
    func applyPageEdit(ids: [String], opts: [String: [String: String]] = [:]) {
        let before = pageStore.current
        let after = pageStore.set(ids: ids, opts: opts)
        guard after.rev != before.rev else { return }   // no-op edit: do not reboot the device for nothing
        menubar.setPages(ids: after.ids, opts: after.opts)   // the edit is now the applied baseline
        // Deliberately NOT reading a room out of `after.opts["sonos"]` here (that was the bug): the room is
        // PROVIDER state, and `opts` is filtered by `enabled` (HubViewModel.enabledPageOpts) before it ever
        // reaches this function -- disabling the Sonos page would silently drop the key, and a later save
        // would then read no room and clear SonosProvider's selection even though the user never touched
        // it. The Page Designer's room picker calls `onSetSonosRoom` (-> SonosProvider.setSelectedRoom)
        // directly and immediately on selection now, independent of Save & push and of page enablement.
        guard central.isConnected else {
            menubar.setPageSync("Saved. The Beacon picks this up next time it connects.")
            return
        }
        menubar.setPageSync("Sent - the Beacon is restarting…")
        // A page save that points the chart at a just-added ticker must land on the device BEFORE the
        // page push that restarts it -- otherwise the device could reboot with the chart id set but the
        // ticker row not yet persisted (design 2026-07-26-yahoo-symbol-search). The chart-instrument
        // picker already live-pushes the ticker config the moment a new symbol is chosen, but re-push here
        // unconditionally rather than trust that earlier push landed (BLE could have dropped in between);
        // it is a cheap idempotent re-sync, the same one that already runs on every (re)connect below in
        // central.onReady, which is what actually guarantees convergence if the device reboots mid-sync.
        pushTickerConfig()
        pushPageConfig()
    }

    private func sendFrame(_ frame: StatusFrame) {
        guard central.isConnected else { return }
        do {
            central.send(try frame.encoded())
        } catch {
            FileHandle.standardError.write(Data("[beacon-hub] frame encode failed: \(error.localizedDescription)\n".utf8))
        }
    }
}
