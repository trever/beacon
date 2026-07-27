import SwiftUI
import BeaconHubKit

// Search-and-pick surface for the Chart page's instrument (design 2026-07-27-hub-visual-system SS3.4).
// This is the one picker in the Pages destination that KEEPS a popover rather than becoming a `Menu` --
// it searches every instrument Yahoo Finance knows about, not a bounded list, and design SS3.4 says so
// explicitly. An empty query browses the user's current Yahoo tickers (what the old Picker showed);
// typing switches to a live, debounced Yahoo search. `select` is the only way this view affects anything
// -- it never mutates HubViewModel itself.
struct ChartInstrumentPopover: View {
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
        VStack(alignment: .leading, spacing: HubSpace.s) {
            searchField
            if let capMessage {
                Text(capMessage).font(HubType.caption).foregroundStyle(HubColor.stateWarn)
            }
            if let orphan {
                Text("Currently set to \(orphan), which is not in the ticker list.")
                    .font(HubType.caption).foregroundStyle(HubColor.inkSecondary)
            }
            resultsList
        }
        .padding(HubSpace.m)
        .frame(width: 300, height: 320, alignment: .top)
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: HubSpace.s) {
            Image(systemName: "magnifyingglass").font(HubType.caption).foregroundStyle(HubColor.inkSecondary)
            TextField("Search any Yahoo symbol", text: $query)
                .textFieldStyle(.plain).font(HubType.control)
                .onChange(of: query) { runSearch($0) }
            if searching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, HubSpace.s).padding(.vertical, HubSpace.s)
        .background(HubColor.fillControl, in: HubShape.control)
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

    // design SS3.4 replaces the old `InstrumentRow` with the shared `ListRow`: primary is the instrument's
    // own name, secondary is a single middot-joined line (symbol, and an exchange tag when search supplies
    // one) -- the same "at least two fields where a second field exists" rule the Sonos room menu follows.
    @ViewBuilder private var existingRows: some View {
        if eligible.isEmpty {
            Text("No Yahoo tickers yet. Type to search Yahoo Finance.")
                .font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(HubSpace.s)
        } else {
            ForEach(eligible, id: \.id) { t in
                ListRow(primary: t.name.isEmpty ? t.sym : t.name, secondary: t.sym, isCurrent: t.id == currentID) {
                    select(t)
                }
                RowSeparator(hasLeadingIcon: false)
            }
        }
    }

    @ViewBuilder private var searchRows: some View {
        if results.isEmpty {
            Text(searching ? "Searching\u{2026}" : "No matches.")
                .font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(HubSpace.s)
        } else {
            ForEach(results, id: \.row.id) { c in
                ListRow(primary: c.row.name.isEmpty ? c.row.sym : c.row.name,
                        secondary: instrumentSecondary(sym: c.row.sym, exchange: c.exchange),
                        isCurrent: c.row.id == currentID) { select(c.row) }
                RowSeparator(hasLeadingIcon: false)
            }
        }
    }

    /// The symbol alone, or symbol-middot-exchange when search supplies one -- design SS3.4's own
    /// benchmark row ("S&P 500 / ^GSPC · NYSE"). `ListRow` takes one secondary string, so this is where
    /// the join happens, same as `SonosRoomList.secondary` joins the room's fields into one line.
    private func instrumentSecondary(sym: String, exchange: String?) -> String {
        guard let exchange, !exchange.isEmpty else { return sym }
        return "\(sym) \u{00B7} \(exchange)"
    }
}
