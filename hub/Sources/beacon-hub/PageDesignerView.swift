import SwiftUI
import AppKit
import BeaconHubKit

// The device's page set, laid out as composition (design §3.2, plan §6): an ordered carousel of what's
// ON the Beacon up top, the full catalog as a grid below it, a right-hand inspector for the selected
// page's own options -- and, when Home is selected, the six-slot complication editor.
//
// Editing STAGES for pages (applying restarts the Beacon, ~5 s) and for complications (applying is live,
// no restart) independently, but one "Save & push" button commits both: complications first, pages
// second (design §7's push order -- so if the page push restarts the device, the complication blob is
// already persisted and the device boots correct). The footer shows a line per dirty channel so neither
// verb is silently folded into the other (design §10.3).
struct PageDesignerView: View {
    @ObservedObject var model: HubViewModel
    @State private var selection: String?
    @State private var targetedCardIndex: Int?

    private let cardW: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            enabledCarousel
            Divider()
            HStack(spacing: 0) {
                availableGrid
                Divider()
                inspector
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 620)
        .onAppear {
            if selection == nil {
                selection = model.pageRows.first(where: \.enabled)?.id ?? model.pageRows.first?.id
            }
        }
    }

    // --- header ---

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On the Beacon").font(.system(size: 15, weight: .semibold))
                Text("Drag to reorder or add pages. Select a page to edit its options on the right.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.enabledPageIDs.count) of \(model.pageRows.count) enabled")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // --- the enabled carousel: device order, draggable, reorderable ---

    private var enabledRows: [PageRow] { model.pageRows.filter(\.enabled) }

    private var enabledCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(enabledRows.enumerated()), id: \.element.id) { pair in
                        carouselCard(index: pair.offset, row: pair.element)
                    }
                    appendDropZone
                }
                .padding(.horizontal, 18).padding(.vertical, 18)
            }
            // Single-parameter onChange: the package deploys to macOS 13, where the two-parameter
            // overload does not exist.
            .onChange(of: enabledRows.map(\.id)) { _ in
                if let sel = selection { withAnimation { proxy.scrollTo(sel, anchor: .center) } }
            }
        }
        .frame(height: 230)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func carouselCard(index: Int, row: PageRow) -> some View {
        CarouselCard(model: model, row: row, index: index, width: cardW, isSelected: selection == row.id,
                     isTargeted: targetedCardIndex == index,
                     onSelect: { selection = row.id },
                     onMove: { delta in moveEnabled(id: row.id, delta: delta) },
                     onDisable: { disablePage(row.id) })
            .id(row.id)
            .draggable(row.id)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first else { return false }
                placeOnCarousel(id: id, atEnabledIndex: index)
                return true
            } isTargeted: { targeted in
                targetedCardIndex = targeted ? index : (targetedCardIndex == index ? nil : targetedCardIndex)
            }
    }

    private var appendDropZone: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(width: 60, height: 150)
            .overlay(Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(.secondary))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first else { return false }
                placeOnCarousel(id: id, atEnabledIndex: nil)
                return true
            }
    }

    // --- the available grid: the full catalog, greyed where already enabled ---

    private var availableGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("AVAILABLE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(model.pageRows) { row in
                        availableTile(row)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 300)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            disablePage(id)
            return true
        }
    }

    private func availableTile(_ row: PageRow) -> some View {
        AvailableTile(row: row, isSelected: selection == row.id)
            .onTapGesture {
                selection = row.id
                if !row.enabled { placeOnCarousel(id: row.id, atEnabledIndex: nil) }
            }
            .draggable(row.id)
    }

    // --- inspector ---

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = selection, let row = model.pageRows.first(where: { $0.id == id }) {
                inspectorHeader(row)
                Divider()
                if row.id == CompLimits.homeFace {
                    ComplicationEditorView(model: model)
                } else {
                    PageOptions(model: model, row: row)
                }
                Spacer(minLength: 0)
            } else {
                Spacer()
                Text("Select a page").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inspectorHeader(_ row: PageRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.title).font(.system(size: 13, weight: .semibold))
                if row.pinned {
                    Text("always on").font(.system(size: 9)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                if !row.enabled {
                    Text("hidden").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
            }
            Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // --- footer: two independent staging channels, one commit button (design §10.3, plan §13 item 4) ---

    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) { footerLines }
            Spacer()
            if model.pagesDirty || model.compsDirty {
                DeckButton(title: "Revert") { revertAll() }
            }
            DeckButton(title: "Save & push") { saveAll() }
                .disabled(!(model.pagesDirty || model.compsDirty))
                .opacity((model.pagesDirty || model.compsDirty) ? 1 : 0.4)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var footerLines: some View {
        if pagesLine == nil && compsLine == nil {
            statusLine("The Beacon is running this configuration.", dirty: false)
        }
        if let pagesLine { statusLine(pagesLine, dirty: model.pagesDirty && model.pageSync == nil) }
        if let compsLine { statusLine(compsLine, dirty: model.compsDirty && model.compSync == nil) }
    }

    // A live sync message (post-action confirmation, e.g. "Sent…"/"Saved…") always wins over the dirty
    // preview text for its own channel -- mirrors the single-channel footer this replaces.
    private var pagesLine: String? {
        if let s = model.pageSync { return s }
        if model.pagesDirty { return "Pages changed \u{00B7} the Beacon restarts (~5 s)." }
        return nil
    }
    private var compsLine: String? {
        if let s = model.compSync { return s }
        if model.compsDirty { return "Complications updated \u{00B7} applies immediately." }
        return nil
    }

    private func statusLine(_ text: String, dirty: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dirty ? Color.orange : Color.clear).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Comps first, pages second (design §7 / plan §13 item 4): the cheap non-restarting push lands
    // before the one that restarts the device, so if the page push reboots it, the complication blob is
    // already persisted and the device boots showing the right assignment.
    private func saveAll() {
        if model.compsDirty { model.onApplyComps(model.compSlots) }
        if model.pagesDirty { model.onApplyPages(model.enabledPageIDs, model.enabledPageOpts) }
    }

    private func revertAll() {
        model.onRevertComps()
        model.onRevertPages()
    }

    // --- page mutations (mirrors the array-level move(_:) the old carousel used; not pure-kit material --
    // BeaconHubKit.ComplicationEditor owns the RULES that actually need host-testing, per the brief) ---

    /// Enable `id` (if it wasn't already) and move it to `targetIndex` among the ENABLED subset (nil =
    /// append at the end). `targetIndex` is a position in the enabled list AS CURRENTLY DISPLAYED -- i.e.
    /// it may still include the dragged row itself, when this is a reorder rather than a fresh enable.
    /// Resolving it to a stable id BEFORE removing anything avoids an off-by-one: removing the dragged
    /// row first would shift every subsequent index down by one, corrupting a numeric target index.
    /// Disabled rows elsewhere in `model.pageRows` keep their relative position -- they don't appear in
    /// the enabled-filtered carousel, so where they sit in the backing array doesn't matter beyond
    /// preserving `enabledPageIDs`'s order for the rows that DO show.
    private func placeOnCarousel(id: String, atEnabledIndex targetIndex: Int?) {
        guard let sourceIndex = model.pageRows.firstIndex(where: { $0.id == id }) else { return }
        let enabledBefore = model.pageRows.filter(\.enabled)
        let targetID: String? = targetIndex.flatMap { enabledBefore.indices.contains($0) ? enabledBefore[$0].id : nil }

        var row = model.pageRows[sourceIndex]
        row.enabled = true
        model.pageRows.remove(at: sourceIndex)

        let insertion: Int
        if let targetID, targetID == id {
            insertion = min(sourceIndex, model.pageRows.count)   // dropped on itself: restore its own spot
        } else if let targetID, let idx = model.pageRows.firstIndex(where: { $0.id == targetID }) {
            insertion = idx
        } else {
            insertion = model.pageRows.count
        }
        model.pageRows.insert(row, at: insertion)
        model.pageSync = nil
        selection = id
    }

    private func disablePage(_ id: String) {
        guard let i = model.pageRows.firstIndex(where: { $0.id == id }), !model.pageRows[i].pinned else { return }
        model.pageRows[i].enabled = false
        model.pageSync = nil
    }

    /// The chevron buttons' path: swap `id` with its enabled-subset neighbour. Kept as the keyboard/
    /// accessibility equivalent to dragging (design §3.3) -- drag-and-drop with no non-pointer equivalent
    /// is a regression.
    private func moveEnabled(id: String, delta: Int) {
        let ids = enabledRows.map(\.id)
        guard let idx = ids.firstIndex(of: id) else { return }
        let target = idx + delta
        guard ids.indices.contains(target) else { return }
        guard let a = model.pageRows.firstIndex(where: { $0.id == id }),
              let b = model.pageRows.firstIndex(where: { $0.id == ids[target] }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { model.pageRows.swapAt(a, b) }
        model.pageSync = nil
    }
}

// One enabled page: its panel preview, name, and reorder/remove controls. `settings` is pinned (no
// remove affordance, no drag-out) -- `PageLimits.alwaysID` already encodes this and the device
// force-appends it regardless, so showing it as removable would be a lie.
private struct CarouselCard: View {
    @ObservedObject var model: HubViewModel
    let row: PageRow
    let index: Int
    let width: CGFloat
    let isSelected: Bool
    let isTargeted: Bool
    let onSelect: () -> Void
    let onMove: (Int) -> Void
    let onDisable: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                DevicePreview(pageID: row.id, model: model, size: width - 30)
                if !row.pinned {
                    Button(action: onDisable) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Remove from the Beacon")
                }
            }
            .padding(.top, 4)

            HStack(spacing: 5) {
                Text(row.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if row.pinned {
                    Text("always on").font(.system(size: 8)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
            }

            HStack(spacing: 6) {
                arrow("chevron.left", enabled: index > 0) { onMove(-1) }
                arrow("chevron.right", enabled: true) { onMove(1) }
            }
            .padding(.bottom, 4)
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: (isSelected || isTargeted) ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var borderColor: Color {
        if isTargeted { return Color.accentColor }
        if isSelected { return Color.accentColor.opacity(0.7) }
        return Color.secondary.opacity(0.18)
    }

    private func arrow(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless).disabled(!enabled).opacity(enabled ? 0.75 : 0.2)
    }
}

// One catalog entry in the "AVAILABLE" grid: greyed + marked when already on the Beacon (design §3.2).
// Tapping a disabled tile enables it (appends to the end of the carousel) -- the accessible/no-drag
// equivalent of dragging it up. Tapping an already-enabled tile just selects it in the inspector.
private struct AvailableTile: View {
    let row: PageRow
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(row.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
            if row.enabled {
                Text("on the Beacon").font(.system(size: 8, weight: .semibold)).foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10).padding(.horizontal, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18),
                              lineWidth: isSelected ? 2 : 1)
        )
        .opacity(row.enabled ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

// Per-page settings shown in the inspector. Only chart/sonos/agents have anything today; everything else
// (including pinned `settings`) says so plainly rather than showing an empty well that reads like
// something failed to load. `home` never reaches this view -- PageDesignerView routes it straight to
// ComplicationEditorView instead.
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
            else if row.id == "agents" { AgentProviderRows(model: model) }
            else { none }
        }
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
        Text("No options").font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.6))
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

// Projected (not copied) provider rows for the Agents inspector (design §3.1): bound to the SAME
// model.providers / model.onInstallProviderHooks / model.onSetProviderUsage / model.onSetProviderBuddy
// the Sources tab renders. Coding-buddy-on holds real tool calls on your Mac whether or not any page
// shows them, so hiding the Agents page must not read as disarming it -- the honesty line below says so.
// (A visually distinct, file-local rendering of the same store/intents: SettingsPanel.swift's ProviderRow
// is `private` to that file, and it is off-limits to edit for this workstream.)
private struct AgentProviderRows: View {
    @ObservedObject var model: HubViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.providers.enumerated()), id: \.element.id) { pair in
                if pair.offset > 0 { Divider() }
                AgentProviderRow(model: model, provider: pair.element)
            }
            Text("Also applies while this page is hidden.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

private struct AgentProviderRow: View {
    @ObservedObject var model: HubViewModel
    let provider: ProviderToggle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.label).font(.system(size: 11, weight: .medium))
                Spacer()
                setupChip
            }
            HStack(spacing: 16) {
                toggleRow("Usage", supported: provider.supportsUsage, isOn: usageBinding)
                toggleRow("Coding buddy", supported: provider.supportsBuddy, isOn: buddyBinding)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var setupChip: some View {
        switch (provider.installing, provider.hooks) {
        case (true, _):
            Text("Setting up\u{2026}").font(.system(size: 10)).foregroundStyle(.secondary)
        case (false, .ok):
            Text("Ready").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
        case (false, .checking):
            EmptyView()
        case (false, .bad):
            DeckButton(title: "Set up") { model.onInstallProviderHooks(provider.id) }
        }
    }

    private func toggleRow(_ label: String, supported: Bool, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            if supported {
                Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            } else {
                Text("\u{2014}").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var usageBinding: Binding<Bool> {
        Binding(get: { model.providers.first { $0.id == provider.id }?.usageOn ?? true },
                set: { on in
                    if let i = model.providers.firstIndex(where: { $0.id == provider.id }) { model.providers[i].usageOn = on }
                    model.onSetProviderUsage(provider.id, on)
                })
    }
    private var buddyBinding: Binding<Bool> {
        Binding(get: { model.providers.first { $0.id == provider.id }?.buddyOn ?? true },
                set: { on in
                    if let i = model.providers.firstIndex(where: { $0.id == provider.id }) { model.providers[i].buddyOn = on }
                    model.onSetProviderBuddy(provider.id, on)
                })
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
