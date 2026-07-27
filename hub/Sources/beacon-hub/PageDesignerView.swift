import SwiftUI
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

    var body: some View {
        Group {
            if row.id == "chart" { chartInstrumentButton }
            else if row.id == "sonos" { sonosRoomField }
            else { none }
        }
        .frame(height: 24)
    }

    private var none: some View {
        Text("No options").font(.system(size: 10)).foregroundStyle(.secondary.opacity(0.6))
    }

    // The Sonos room this page follows (opts["room"]), same plumbing as chart.sym (CONTRACT.md §A2: "The
    // opts plumbing is generic and already end to end; only the Sonos room-picker UI is new"). Free text
    // rather than a resolved picker: SonosProvider does not expose its household/group topology today, and
    // building that lookup would mean sharing its poll-gate/backoff state (SonosGateTests) with a
    // UI-driven fetch -- a new provider surface, not wiring. The name matches the Sonos Control API's
    // room/group name (case-insensitive; SonosAPI.findGroup matches by group name or player name).
    private var sonosRoomField: some View {
        TextField("Room name", text: Binding(get: { row.opts["room"] ?? "" }, set: setRoom))
            .textFieldStyle(.plain).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .disabled(!row.enabled)
    }

    private func setRoom(_ value: String) {
        guard let i = model.pageRows.firstIndex(where: { $0.id == row.id }) else { return }
        model.pageRows[i].opts["room"] = value
        model.pageSync = nil
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
