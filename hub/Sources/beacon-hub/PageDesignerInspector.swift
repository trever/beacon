import SwiftUI
import AppKit
import BeaconHubKit

// Per-page settings shown in the inspector, plus the tier-driven "What this page shows" block (design
// 2026-07-27-hub-visual-system SS5.2.1, plan WS-2 item 7). `home` never reaches this view --
// PageDesignerView routes it straight to ComplicationEditorView instead.
//
// Tiering (InspectorTier.swift) replaces the old blanket "nothing configured" placeholder: a page with zero
// configurable options gets the device preview instead of an empty well that reads like something failed
// to load; a page with 1-2 options (chart, sonos, and today's agents count) gets the SAME preview below
// its options, so the lone control never floats alone in the column.
struct PageOptions: View {
    @ObservedObject var model: HubViewModel
    let row: PageRow

    @State private var chartPickerOpen = false
    @State private var capMessage: String?
    // Defect 2 (the room picker's own async listing state): SonosRoomListResult (SonosProvider.swift) is
    // a completed-outcome vocabulary with no notion of "request sent, no answer yet" -- that is purely a
    // UI concern, modeled here rather than growing the provider's type for a UI-only state.
    @State private var roomFetch: SonosRoomFetchState = .idle
    // The selected room, mirrored into local @State from model.onLoadSonosRoom() -- see the doc comment
    // on `sonosSection` below for why this does NOT live in row.opts/PageConfigStore.
    @State private var currentRoom: String = ""

    /// How many configurable options the selected page has -- the ONLY input to `InspectorLayout.tier`.
    /// `agents` is dynamic (one row per registered provider) rather than a fixed count, so a future third
    /// provider correctly promotes that page to `.optionsOnly` without this file changing.
    private var optionCount: Int {
        switch row.id {
        case "chart": return 1
        case "sonos": return 1
        case "agents": return model.providers.count
        default: return 0
        }
    }
    private var tier: InspectorTier { InspectorLayout.tier(optionCount: optionCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpace.l) {
            if tier != .previewOnly {
                optionsBody
            }
            if tier != .optionsOnly {
                if tier == .optionsPlusPreview { Divider() }
                previewBlock
            }
        }
        .padding(.horizontal, HubSpace.l).padding(.vertical, HubSpace.m)
        .onAppear { refreshSonosIfNeeded() }
        // PageDesignerWindowController builds this window once and reuses it across opens (same as
        // SettingsWindowController), so onAppear above only ever fires the first time this row was
        // selected. Re-deriving on refocus keeps this honest the same way SonosSettingsView does, and --
        // now that the room list itself is a `Menu` with no macOS-13 "did open" callback to hang a refetch
        // off of -- this is also the mechanism that keeps the room LIST fresh (a speaker coming back
        // online, a room renamed) without the user having to quit and reopen Beacon Hub.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshSonosIfNeeded()
        }
    }

    private func refreshSonosIfNeeded() {
        guard row.id == "sonos" else { return }
        currentRoom = model.onLoadSonosRoom() ?? ""
        fetchRooms()
    }

    @ViewBuilder private var optionsBody: some View {
        switch row.id {
        case "chart": chartSection
        case "sonos": sonosSection
        case "agents": agentsSection
        default: EmptyView()
        }
    }

    // --- "What this page shows" (design SS5.2.1): the page's own device preview plus one sentence. ---

    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: HubSpace.s) {
            Text("What this page shows").hubEyebrow().foregroundStyle(HubColor.inkSecondary)
            DeviceGlassPanel(size: 160) {
                DevicePreview(pageID: row.id, model: model, size: 160)
            }
            Text(row.detail).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
        }
    }

    // --- Sonos room (design SS3.4, plan WS-2 item 8) ---
    // Deliberately NOT `row.opts["room"]`/PageConfigStore, unlike chart.sym: a page-designer regression
    // found that HubViewModel.enabledPageOpts filters opts by `enabled` before AppDelegate.applyPageEdit
    // ever sees them, so a DISABLED Sonos page would silently drop its room the next time any page edit
    // was saved. The room is PROVIDER state (which room SonosProvider polls), not page-presentation state
    // (whether/what the device shows) -- so it is read from and written straight through SonosRoomStore
    // via model.onLoadSonosRoom/onSetSonosRoom (AppDelegate wires the write through
    // SonosProvider.setSelectedRoom so the group cache still invalidates), independent of Save & push and
    // of whether this page is enabled.

    @ViewBuilder private var sonosSection: some View {
        Menu {
            sonosMenuContent
        } label: {
            Text(roomLabel).font(HubType.control)
        }
        .disabled(!row.enabled)
    }

    private var roomLabel: String {
        currentRoom.isEmpty ? "Choose room" : currentRoom
    }

    /// The stored room when it is not in the freshly-fetched list -- an offline speaker or a room renamed
    /// in the Sonos app must not silently vanish from the menu just because this fetch does not currently
    /// see it. Nil (nothing to mark) while the fetch hasn't produced a room list yet, so this never
    /// contradicts a `.loading`/`.failed`/`.notAuthorized` state by claiming something is "not in the
    /// current groups" before groups were even fetched.
    private var roomOrphan: String? {
        guard !currentRoom.isEmpty, case .loaded(let rooms) = roomFetch,
              !rooms.contains(where: { $0.name == currentRoom })
        else { return nil }
        return currentRoom
    }

    // Async states live inside the menu as disabled informational items plus (where recoverable) a
    // "Retry" item -- design SS3.4: "a list of a known, bounded set is a Menu or Picker, not a hand-built
    // button + popover... async states live inside the menu as disabled items plus a Retry item."
    @ViewBuilder private var sonosMenuContent: some View {
        switch roomFetch {
        case .idle, .loading:
            Text("Loading rooms\u{2026}")
        case .notAuthorized:
            Text("Sonos is not connected.")
            Text("Authorize with Sonos in Settings to list your rooms.")
            if !currentRoom.isEmpty { Text("Currently set to \(currentRoom).") }
            // Retry (not just guidance text) so authorizing in Settings and coming straight back to this
            // menu has a way to re-check without closing and reopening the inspector (design SS8.3's human
            // script, H8b: "an explanatory disabled item plus Retry, never an empty menu").
            Button("Retry") { fetchRooms() }
        case .failed(let reason):
            Text("Could not load rooms.")
            Text(reason)
            if !currentRoom.isEmpty { Text("Currently set to \(currentRoom).") }
            Button("Retry") { fetchRooms() }
        case .loaded(let rooms):
            if rooms.isEmpty && roomOrphan == nil {
                Text("No rooms found in your Sonos household.")
            } else {
                if let roomOrphan {
                    roomMenuItem(title: "\(roomOrphan) (not in current groups)", isCurrent: true) {
                        selectRoom(roomOrphan)
                    }
                }
                // The row's content, not just the widget (plan WS-2 item 8's acceptance note):
                // `SonosRoomList.menuTitle` is called here, never re-derived -- it is the one place that
                // decides whether a room says anything beyond its own name, including the nil-playback
                // rule (a room whose state was never learned says nothing about playback, never "paused").
                ForEach(rooms, id: \.name) { room in
                    roomMenuItem(title: SonosRoomList.menuTitle(room), isCurrent: room.name == currentRoom) {
                        selectRoom(room.name)
                    }
                }
            }
        }
    }

    // A macOS `Menu` renders one label per item and AppKit flattens a `VStack` label to its first `Text`
    // (design SS3.4 trap) -- so the current room's mark is a `Label`'s icon, never a second text line.
    private func roomMenuItem(title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func fetchRooms() {
        roomFetch = .loading
        model.onFetchSonosRooms { result in
            Task { @MainActor in
                switch result {
                case .notAuthorized: roomFetch = .notAuthorized
                case .failed(let reason): roomFetch = .failed(reason)
                case .rooms(let rooms): roomFetch = .loaded(rooms)
                }
            }
        }
    }

    // Applies immediately (unlike the chart's setSym, which only stages into pageRows.opts for Save &
    // push): a room change is meant to take effect on SonosProvider's very next poll tick, not wait for a
    // device restart -- see SonosProvider.setSelectedRoom's own doc comment. Optimistic local update first
    // so the menu label reflects the pick without waiting on anything async.
    private func selectRoom(_ name: String) {
        currentRoom = name
        model.onSetSonosRoom(name.isEmpty ? nil : name)
    }

    // --- Chart instrument (design SS3.4: kept as a popover -- it searches every Yahoo symbol) ---
    // The chart follows a TICKER ID from the configured list, not a typed symbol: the device resolves the
    // Yahoo symbol and display name from that row, so there is nothing free-form to mistype. Picking a
    // symbol not yet in the list mints + pushes a new row first (see ChartInstrumentSelection). Binance
    // rows are excluded -- the chart fetch speaks the Yahoo API only.

    private var eligible: [TickerRow] { model.tickerRows.filter { $0.src == .yahoo } }

    /// The stored instrument, when it is no longer in the ticker list. Offered as its own (marked) entry
    /// so it round-trips: silently resolving it to a DIFFERENT instrument would make the picker read as
    /// though the user had chosen that one, and one Save & push later it would be true. A search pick
    /// never touches this on its own -- only an explicit tap in the popover changes `opts["sym"]`.
    private var orphan: String? {
        guard let sym = row.opts["sym"], !sym.isEmpty,
              !eligible.contains(where: { $0.id == sym }) else { return nil }
        return sym
    }

    /// Matches CHART_TICKER_ID in the firmware: what the device falls back to when no option is set.
    private var defaultSym: String {
        eligible.contains { $0.id == "sp500" } ? "sp500" : (eligible.first?.id ?? "")
    }

    private var currentID: String { row.opts["sym"] ?? defaultSym }

    private var currentLabel: String {
        if let orphan, orphan == currentID { return "\(orphan) (not in list)" }
        if let t = eligible.first(where: { $0.id == currentID }) { return t.name.isEmpty ? t.sym : t.name }
        return currentID.isEmpty ? "Choose instrument" : currentID
    }

    // A compact button (not a native Picker) so the card can open a popover with a search field instead of
    // being limited to the 8-ish rows already in the ticker list.
    @ViewBuilder private var chartSection: some View {
        Button {
            capMessage = nil
            chartPickerOpen = true
        } label: {
            HStack(spacing: HubSpace.xs) {
                Text(currentLabel).font(HubType.control).lineLimit(1)
                Spacer(minLength: HubSpace.xs)
                Image(systemName: "chevron.down").font(HubType.caption).foregroundStyle(HubColor.inkSecondary)
            }
            .padding(.horizontal, HubSpace.s).padding(.vertical, HubSpace.xs)
            .background(HubColor.fillControl, in: HubShape.control)
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .popover(isPresented: $chartPickerOpen, arrowEdge: .bottom) {
            ChartInstrumentPopover(model: model, currentID: currentID, orphan: orphan,
                                   capMessage: capMessage, select: selectChartInstrument)
        }
    }

    /// Resolve what picking `candidate` means (already in the list / a brand-new instrument / the list
    /// already at the device's cap) via the pure ChartInstrumentSelection, then apply it. Adding pushes
    /// the ticker config immediately -- model.onApplyTickerEdit persists + pushes, exactly like the
    /// standalone ticker editor's Add -- so one tap both adds the row and stages the chart option; the
    /// page card's own "Save & push" still gates the PAGE change (and re-pushes tickers first; see
    /// AppDelegate.applyPageEdit).
    private func selectChartInstrument(_ candidate: TickerRow) {
        switch ChartInstrumentSelection.resolve(candidate: candidate, currentList: model.tickerRows) {
        case .setExisting(let sym):
            setSym(sym)
            chartPickerOpen = false
        case .addAndSet(let newRow):
            model.onApplyTickerEdit(model.tickerRows + [newRow])
            setSym(newRow.id)
            chartPickerOpen = false
        case .tooManyTickers:
            capMessage = "Ticker list is full (\(ChartInstrumentSelection.maxTickers)). Remove one to add another."
        }
    }

    private func setSym(_ id: String) {
        guard let i = model.pageRows.firstIndex(where: { $0.id == row.id }) else { return }
        model.pageRows[i].opts["sym"] = id
        model.pageSync = nil
    }

    // --- Agents (design SS3.1/SS3.2): projected (not copied) provider rows, bound to the SAME
    // model.providers / model.onInstallProviderHooks / model.onSetProviderUsage / model.onSetProviderBuddy
    // the Sources tab renders. Coding-buddy-on holds real tool calls on your Mac whether or not any page
    // shows them, so hiding the Agents page must not read as disarming it -- the honesty line below says
    // so. ---

    @ViewBuilder private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.providers.enumerated()), id: \.element.id) { pair in
                if pair.offset > 0 { RowSeparator(hasLeadingIcon: false) }
                providerRows(pair.element)
            }
            Text("Also applies while this page is hidden.")
                .font(HubType.caption).foregroundStyle(HubColor.inkSecondary)
                .padding(.horizontal, HubSpace.m).padding(.top, HubSpace.xs)
        }
    }

    /// One provider's status row plus its two independent toggle rows -- `SettingsRow` carries exactly one
    /// trailing control (design SS3.2: "a row that needs two is two rows"), so Usage and Coding buddy are
    /// two separate rows rather than one crowded one.
    @ViewBuilder private func providerRows(_ provider: ProviderToggle) -> some View {
        StatusRow(state: providerState(provider), title: provider.label, hint: providerHint(provider)) {
            providerSetupTrailing(provider)
        }
        SettingsRow(title: "Usage") {
            providerToggle(supported: provider.supportsUsage, isOn: usageBinding(provider))
        }
        SettingsRow(title: "Coding buddy") {
            providerToggle(supported: provider.supportsBuddy, isOn: buddyBinding(provider))
        }
    }

    private func providerState(_ provider: ProviderToggle) -> HubState {
        provider.installing ? .checking : HubState(provider.hooks)
    }

    private func providerHint(_ provider: ProviderToggle) -> String? {
        if provider.installing { return "Setting up\u{2026}" }
        switch provider.hooks {
        case .ok:       return "Ready"
        case .checking: return nil
        case .bad:      return "Needs setup"
        }
    }

    @ViewBuilder private func providerSetupTrailing(_ provider: ProviderToggle) -> some View {
        if !provider.installing && provider.hooks == .bad {
            HubButton(title: "Set up", kind: .secondary) { model.onInstallProviderHooks(provider.id) }
        }
    }

    // ink.secondary, not ink.tertiary (design SS2.3: "ink.tertiary may not carry content... the
    // unsupported — markers... move to ink.secondary").
    @ViewBuilder private func providerToggle(supported: Bool, isOn: Binding<Bool>) -> some View {
        if supported {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        } else {
            Text("\u{2014}").font(HubType.body).foregroundStyle(HubColor.inkSecondary)
        }
    }

    private func usageBinding(_ provider: ProviderToggle) -> Binding<Bool> {
        Binding(get: { model.providers.first { $0.id == provider.id }?.usageOn ?? true },
                set: { on in
                    if let i = model.providers.firstIndex(where: { $0.id == provider.id }) { model.providers[i].usageOn = on }
                    model.onSetProviderUsage(provider.id, on)
                })
    }
    private func buddyBinding(_ provider: ProviderToggle) -> Binding<Bool> {
        Binding(get: { model.providers.first { $0.id == provider.id }?.buddyOn ?? true },
                set: { on in
                    if let i = model.providers.firstIndex(where: { $0.id == provider.id }) { model.providers[i].buddyOn = on }
                    model.onSetProviderBuddy(provider.id, on)
                })
    }
}

// The room picker's own in-flight state (Defect 2): SonosRoomListResult (SonosProvider.swift) is a
// completed-outcome vocabulary with no notion of "request sent, no answer yet" -- that is purely a UI
// concern, so it is modeled here rather than growing the provider's type for a UI-only state. Carries
// `[SonosRoomSummary]` directly (not `[String]`) -- WS-0b widened `SonosRoomListResult.rooms` to the same
// shape, so no adaptation is needed here.
private enum SonosRoomFetchState: Equatable {
    case idle
    case loading
    case notAuthorized
    case failed(String)
    case loaded([SonosRoomSummary])
}
