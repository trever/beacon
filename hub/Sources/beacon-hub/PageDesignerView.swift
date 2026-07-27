import SwiftUI
import AppKit
import BeaconHubKit

// The device's page set, laid out the way the device lays it out: a horizontal run of panels you scroll
// through, each one enable/disable-able and reorderable in place. Replaces the checkbox list that lived
// in Settings.
//
// Editing STAGES. Applying restarts the Beacon (~5 s), so "Save & push" is one deliberate action rather
// than a push per checkbox; the button is live only when the list actually differs from what the device
// is running.
struct PageDesignerView: View {
    @ObservedObject var model: HubViewModel
    @State private var selection: String?

    private let cardW: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            carousel
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { if selection == nil { selection = model.pageRows.first?.id } }
    }

    // --- header ---

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Device pages").font(.system(size: 15, weight: .semibold))
                Text("Scroll the pages as they appear on the Beacon. Toggle what shows, drag the arrows to reorder.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.enabledPageIDs.count) of \(model.pageRows.count)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // --- carousel ---

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                cards
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
            }
            // Single-parameter onChange: the package deploys to macOS 13, where the two-parameter
            // overload does not exist. Keeps the moved card in view when reordering pushes it past the fold.
            .onChange(of: model.pageRows.map(\.id)) { _ in
                if let sel = selection { withAnimation { proxy.scrollTo(sel, anchor: .center) } }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var cards: some View {
        HStack(spacing: 18) {
            ForEach(Array(model.pageRows.enumerated()), id: \.element.id) { pair in
                card(index: pair.offset, row: pair.element)
            }
        }
    }

    private func card(index: Int, row: PageRow) -> some View {
        PageCard(model: model, row: row, index: index, width: cardW, isSelected: selection == row.id)
            .id(row.id)
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = row.id } }
    }

    // --- footer ---

    private var footer: some View {
        HStack(spacing: 10) {
            statusIcon
            Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.pagesDirty {
                DeckButton(title: "Revert") { model.onRevertPages() }
            }
            DeckButton(title: "Save & push") { model.onApplyPages(model.enabledPageIDs, model.enabledPageOpts) }
                .disabled(!model.pagesDirty)
                .opacity(model.pagesDirty ? 1 : 0.4)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var statusIcon: some View {
        if model.pageSync != nil {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if model.pagesDirty {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        } else {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
        }
    }

    private var statusText: String {
        if let s = model.pageSync { return s }
        if model.pagesDirty { return "Unsaved changes. The Beacon restarts when you push (about 5 seconds)." }
        return "The Beacon is running this page set."
    }
}

// One page: its panel preview, name, enable switch and reorder arrows.
private struct PageCard: View {
    @ObservedObject var model: HubViewModel
    let row: PageRow
    let index: Int
    let width: CGFloat
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                DevicePreview(pageID: row.id, model: model, size: width - 30)
                    .saturation(row.enabled ? 1 : 0)
                    .opacity(row.enabled ? 1 : 0.32)
                if !row.enabled {
                    Text("hidden").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(8)
                }
            }
            .padding(.top, 4)

            HStack(spacing: 6) {
                Text(row.title).font(.system(size: 13, weight: .semibold))
                if row.pinned {
                    Text("always on").font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
            }
            Text(row.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(height: 26, alignment: .top)

            PageOptions(model: model, row: row)
                .padding(.horizontal, 10)

            HStack(spacing: 8) {
                arrow("chevron.left", enabled: index > 0) { move(-1) }
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { on in
                        guard let i = model.pageRows.firstIndex(where: { $0.id == row.id }) else { return }
                        model.pageRows[i].enabled = on
                        model.pageSync = nil
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(row.pinned)
                    .help(row.pinned ? "The Beacon always keeps Settings reachable" : "")
                arrow("chevron.right", enabled: index < model.pageRows.count - 1) { move(1) }
            }
            .padding(.bottom, 4)
        }
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18),
                              lineWidth: isSelected ? 2 : 1)
        )
    }

    private func arrow(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless).disabled(!enabled).opacity(enabled ? 0.75 : 0.2)
    }

    private func move(_ delta: Int) {
        let to = index + delta
        guard model.pageRows.indices.contains(index), model.pageRows.indices.contains(to) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { model.pageRows.swapAt(index, to) }
        model.pageSync = nil
    }
}

// Per-page settings. Only the chart has any today; the rest say so plainly rather than showing an empty
// well that reads like something failed to load.
private struct PageOptions: View {
    @ObservedObject var model: HubViewModel
    let row: PageRow

    @State private var showPicker = false
    @State private var capMessage: String?
    // Defect 2: the room picker's own async listing state -- separate from SonosRoomListResult (a
    // provider-vocabulary type with no notion of "in flight") so the popover can show a spinner between
    // opening and the first completion. Fetched fresh every time the popover opens (see sonosRoomButton
    // below) rather than cached, so a topology change (a speaker coming back online, a room renamed) shows
    // up without the user having to quit and reopen Beacon Hub.
    @State private var roomFetch: SonosRoomFetchState = .idle
    // The selected room, mirrored into local @State from model.onLoadSonosRoom() -- see the file-level
    // comment below on why this does NOT live in row.opts/PageConfigStore. Seeded on appear and updated
    // optimistically the instant a selection is made (onSetSonosRoom applies immediately; there is no
    // @Published to observe here since SonosRoomStore is a plain UserDefaults wrapper, not part of
    // HubViewModel's published state).
    @State private var currentRoom: String = ""

    var body: some View {
        Group {
            if row.id == "chart" { chartInstrumentButton }
            else if row.id == "sonos" { sonosRoomButton }
            else { none }
        }
        .frame(height: 24)
        .onAppear { if row.id == "sonos" { currentRoom = model.onLoadSonosRoom() ?? "" } }
        // PageDesignerWindowController builds this window once and reuses it across opens (same as
        // SettingsWindowController), so onAppear above only ever fires the first time. Nothing else in
        // this build mutates the room besides this exact picker (which already updates `currentRoom`
        // locally the instant a selection is made), so this is defense-in-depth rather than a fix for a
        // demonstrated bug here -- re-deriving on every refocus keeps this view honest the same way
        // SonosSettingsView does, in case that ever changes.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if row.id == "sonos" { currentRoom = model.onLoadSonosRoom() ?? "" }
        }
    }

    private var none: some View {
        Text("No options").font(.system(size: 10)).foregroundStyle(.secondary.opacity(0.6))
    }

    // --- Sonos room ---
    // Deliberately NOT `row.opts["room"]`/PageConfigStore, unlike chart.sym: a page-designer regression
    // found that HubViewModel.enabledPageOpts filters opts by `enabled` before AppDelegate.applyPageEdit
    // ever sees them, so a DISABLED Sonos page would silently drop its room the next time any page edit
    // was saved. The room is PROVIDER state (which room SonosProvider polls), not page-presentation state
    // (whether/what the device shows) -- so it is read from and written straight through SonosRoomStore via
    // model.onLoadSonosRoom/onSetSonosRoom (AppDelegate wires the write through SonosProvider.setSelectedRoom
    // so the group cache still invalidates), independent of Save & push and of whether this page is enabled.
    //
    // The WIDGET also changed, separately: a picker populated from the real household/group list, instead
    // of free text (previously deferred because listing meant either reusing fetchHouseholdIfNeeded/
    // fetchGroups -- which call noteOutcome and would have shared poll-gate/backoff state with
    // SonosGateTests -- or duplicating the fetch path). SonosProvider.fetchAvailableRooms (called here via
    // model.onFetchSonosRooms) resolves that: a separate, read-only listing that reuses the same HTTP calls
    // and SonosAPI parsers but never touches the gate. The name matches the Sonos Control API's GROUP name
    // (case-insensitive; SonosAPI.findGroup also falls back to a player name inside that group).

    /// The stored room when it is not in the freshly-fetched list -- mirrors `orphan` below for the chart
    /// instrument: an offline speaker or a room renamed in the Sonos app must not silently vanish from the
    /// picker just because this fetch does not currently see it. Nil (nothing to mark) while the fetch
    /// hasn't produced a room list yet, so this never contradicts a `.loading`/`.failed`/`.notAuthorized`
    /// state by claiming something is "not in the current groups" before groups were even fetched.
    private var roomOrphan: String? {
        guard !currentRoom.isEmpty, case .loaded(let names) = roomFetch, !names.contains(currentRoom)
        else { return nil }
        return currentRoom
    }

    private var roomLabel: String {
        currentRoom.isEmpty ? "Choose room" : currentRoom
    }

    private var sonosRoomButton: some View {
        Button {
            showPicker = true
            fetchRooms()
        } label: {
            HStack(spacing: 4) {
                Text(roomLabel).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            SonosRoomPopover(fetch: roomFetch, currentRoom: currentRoom, orphan: roomOrphan,
                             retry: fetchRooms, select: selectRoom)
        }
    }

    private func fetchRooms() {
        roomFetch = .loading
        model.onFetchSonosRooms { result in
            Task { @MainActor in
                switch result {
                case .notAuthorized: roomFetch = .notAuthorized
                case .failed(let reason): roomFetch = .failed(reason)
                case .rooms(let names): roomFetch = .loaded(names)
                }
            }
        }
    }

    // Applies immediately (unlike the chart's setSym, which only stages into pageRows.opts for Save &
    // push): a room change is meant to take effect on SonosProvider's very next poll tick, not wait for a
    // device restart -- see SonosProvider.setSelectedRoom's own doc comment. Optimistic local update first
    // so the button label reflects the pick without waiting on anything async.
    private func selectRoom(_ name: String) {
        currentRoom = name
        model.onSetSonosRoom(name.isEmpty ? nil : name)
        showPicker = false
    }

    // The chart follows a TICKER ID from the configured list, not a typed symbol: the device resolves
    // the Yahoo symbol and display name from that row, so there is nothing free-form to mistype. Picking
    // a symbol not yet in the list mints + pushes a new row first (see ChartInstrumentSelection).
    // Binance rows are excluded -- the chart fetch speaks the Yahoo API only.
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
    private var chartInstrumentButton: some View {
        Button {
            capMessage = nil
            showPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ChartInstrumentPopover(model: model, currentID: currentID, orphan: orphan,
                                   capMessage: capMessage, select: select)
        }
    }

    /// Resolve what picking `candidate` means (already in the list / a brand-new instrument / the list
    /// already at the device's cap) via the pure ChartInstrumentSelection, then apply it. Adding pushes
    /// the ticker config immediately -- model.onApplyTickerEdit persists + pushes, exactly like the
    /// standalone ticker editor's Add -- so one tap both adds the row and stages the chart option; the
    /// page card's own "Save & push" still gates the PAGE change (and re-pushes tickers first; see
    /// AppDelegate.applyPageEdit).
    private func select(_ candidate: TickerRow) {
        switch ChartInstrumentSelection.resolve(candidate: candidate, currentList: model.tickerRows) {
        case .setExisting(let sym):
            setSym(sym)
            showPicker = false
        case .addAndSet(let newRow):
            model.onApplyTickerEdit(model.tickerRows + [newRow])
            setSym(newRow.id)
            showPicker = false
        case .tooManyTickers:
            capMessage = "Ticker list is full (\(ChartInstrumentSelection.maxTickers)). Remove one to add another."
        }
    }

    private func setSym(_ id: String) {
        guard let i = model.pageRows.firstIndex(where: { $0.id == row.id }) else { return }
        model.pageRows[i].opts["sym"] = id
        model.pageSync = nil
    }
}

/// Search-and-pick surface for the Chart page's instrument. An empty query browses the user's current
/// Yahoo tickers (what the old Picker showed); typing switches to a live, debounced Yahoo search across
/// every instrument Yahoo Finance knows about. `select` is the only way this view affects anything --
/// it never mutates HubViewModel itself.
private struct ChartInstrumentPopover: View {
    @ObservedObject var model: HubViewModel
    let currentID: String
    let orphan: String?
    let capMessage: String?
    let select: (TickerRow) -> Void

    @State private var query = ""
    @State private var results: [TickerCandidate] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    private var eligible: [TickerRow] { model.tickerRows.filter { $0.src == .yahoo } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchField
            if let capMessage {
                Text(capMessage).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if let orphan {
                Text("Currently set to \(orphan), which is not in the ticker list.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            resultsList
        }
        .padding(10)
        .frame(width: 300, height: 320, alignment: .top)
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search any Yahoo symbol", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onChange(of: query) { runSearch($0) }
            if searching { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // Debounce ~300ms, same cadence as TickerEditorView's search: cancel the prior task, sleep, then call
    // the Yahoo hook and filter to Yahoo-only results (the chart fetch speaks the Yahoo API only).
    private func runSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; searching = false; return }
        guard let onSearchTickers = model.onSearchTickers else { return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            onSearchTickers(trimmed) { merged in
                Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    results = ChartInstrumentSearch.yahooOnly(merged)
                    searching = false
                }
            }
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if query.isEmpty { existingRows } else { searchRows }
            }
        }
    }

    @ViewBuilder private var existingRows: some View {
        if eligible.isEmpty {
            Text("No Yahoo tickers yet. Type to search Yahoo Finance.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } else {
            ForEach(eligible, id: \.id) { t in
                InstrumentRow(name: t.name.isEmpty ? t.sym : t.name, sym: t.sym, tag: nil,
                             isCurrent: t.id == currentID) { select(t) }
                Divider()
            }
        }
    }

    @ViewBuilder private var searchRows: some View {
        if results.isEmpty {
            Text(searching ? "Searching…" : "No matches.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } else {
            ForEach(results, id: \.row.id) { c in
                InstrumentRow(name: c.row.name.isEmpty ? c.row.sym : c.row.name, sym: c.row.sym,
                             tag: c.exchange, isCurrent: c.row.id == currentID) { select(c.row) }
                Divider()
            }
        }
    }
}

private struct InstrumentRow: View {
    let name: String
    let sym: String
    let tag: String?
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(sym).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        if let tag, !tag.isEmpty {
                            Text(tag).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 6)
                if isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// The room picker's own in-flight state (Defect 2): SonosRoomListResult (SonosProvider.swift) is a
// completed-outcome vocabulary with no notion of "request sent, no answer yet" -- that is purely a UI
// concern, so it is modeled here rather than growing the provider's type for a UI-only state.
private enum SonosRoomFetchState: Equatable {
    case idle
    case loading
    case notAuthorized
    case failed(String)
    case loaded([String])
}

/// Room-picker popover for the Sonos page (Defect 2): replaces the old free-text field. Every state the
/// requirements call for gets its own inline explanation rather than an empty/blank-looking popover --
/// "not yet authorized," "fetching," "fetch failed" (with Retry), and "zero rooms" are each handled
/// explicitly so the user is never looking at a mysteriously empty list wondering if something broke.
private struct SonosRoomPopover: View {
    let fetch: SonosRoomFetchState
    let currentRoom: String
    let orphan: String?
    let retry: () -> Void
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(width: 260, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch fetch {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading rooms\u{2026}").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(10)
        case .notAuthorized:
            VStack(alignment: .leading, spacing: 6) {
                Text("Sonos is not connected.").font(.system(size: 11, weight: .medium))
                Text("Open Settings and authorize with Sonos to list your rooms.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                // Not the same check as `orphan` (that compares against a fetched list, which does not
                // exist in this state) -- just surfacing whatever is already saved so the user is never
                // left wondering whether picking a room earlier "took."
                if !currentRoom.isEmpty { storedRoomNotice(currentRoom) }
            }
            .padding(10)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text("Could not load rooms.").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                Text(reason).font(.system(size: 10)).foregroundStyle(.secondary)
                Button("Retry", action: retry).font(.system(size: 11)).buttonStyle(.link)
                if !currentRoom.isEmpty { storedRoomNotice(currentRoom) }
            }
            .padding(10)
        case .loaded(let names):
            if names.isEmpty && orphan == nil {
                Text("No rooms found in your Sonos household.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // The stored room always sorts first when it is not part of the fetched list, so
                        // picking it back (or picking something else instead) is one visible tap either way.
                        if let orphan {
                            RoomRow(name: "\(orphan) (not in current groups)", isCurrent: true) { select(orphan) }
                            Divider()
                        }
                        ForEach(names, id: \.self) { name in
                            RoomRow(name: name, isCurrent: name == currentRoom) { select(name) }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private func storedRoomNotice(_ room: String) -> some View {
        Text("Currently set to \(room).").font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

private struct RoomRow: View {
    let name: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                if isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
