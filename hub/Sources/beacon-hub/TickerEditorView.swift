import SwiftUI
import BeaconHubKit

// Menubar ticker editor (issue #92 B4): search Binance + Yahoo, curate an ordered desired list (<= 16),
// and persist+push on every edit via the B3 path (model.onApplyTickerEdit). All search/merge/encoding
// logic is the tested B1/B2 layer; this view only debounces, displays, and mutates a local working copy.
// Shares HubViewModel with the popover panel so the sync badge reflects the live config_ack.
//
// WS-5 (docs/plans/2026-07-27-hub-visual-system-plan.md SS"WS-5") re-tokenises this file onto the
// shared component layer (HubStyle/HubRows/HubSurfaces): `Module`/`DeckButton` are gone, the private
// `ResultRow`/`CurrentRow`/`TickerRowIconButton`/`SourceChip` row types are gone in favour of shared
// leaf components (`Card`, `HubButton`, `IconButton`, `HubBadge`, `EmptyState`, `RowSeparator`) composed
// directly in this file's own row builders -- there is no single shared "row" shape that fits an
// Add-with-validation row and a reorder-with-trash row, so those two stay bespoke compositions built
// from shared tokens/leaf views rather than a hand-rolled duplicate abstraction (design SS9.2's private-
// helper allowance). `SyncBadge` now builds on `StatusLine` (HubRows.swift) in its `.compact` style --
// the shared component this workstream had to report as a gap when this file was converted -- instead of
// its own hand-rolled icon+text HStack, while still sourcing its glyph/tint from the one `HubState`
// vocabulary (design SS3.3).

struct TickerEditorView: View {
    @ObservedObject var model: HubViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var results: [TickerCandidate] = []
    @State private var working: [TickerRow] = []
    @State private var searchTask: Task<Void, Never>?
    // Per-row add gating (issue #92): the row whose test-fetch is in flight, and the last failure reason
    // keyed by row id (cleared when that row is retried). Keeps add async without blocking the UI.
    @State private var validatingID: String?
    @State private var addErrors: [String: String] = [:]
    // Trash no longer removes on tap (design SS3.10): it stages the row here and a destructive `.alert`
    // names it before `remove(_:)` actually runs.
    @State private var pendingRemoval: TickerRow?

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            header
            searchModule
            resultsModule
            currentListModule
        }
        .padding(HubSpace.m)
        // Width is this view's external frame contract (embedded by DeviceTab.tickerSection, WS-4) and
        // stays fixed. Height converts from a hard `height: 520` to ideal+min (design SS8.3) so larger
        // system text sizes can grow the rows without clipping; DeviceTab hosts this inside its own
        // ScrollView, so a taller editor just scrolls rather than overflowing a fixed popover.
        .frame(width: 420, alignment: .top)
        .frame(minHeight: 420, idealHeight: 520)
        // Seed from the persisted list; re-seed if it changes underneath us (e.g. a push edit elsewhere).
        .onAppear { working = model.tickerRows }
        .onChange(of: model.tickerRows) { working = $0 }
        .alert("Remove \(pendingRemoval?.name ?? "ticker")?",
               isPresented: Binding(get: { pendingRemoval != nil },
                                    set: { if !$0 { pendingRemoval = nil } }),
               presenting: pendingRemoval) { row in
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) { remove(row); pendingRemoval = nil }
        } message: { row in
            Text("This removes \(row.sym) from the shared ticker list; Markets and Chart both stop " +
                 "showing it. You can add it back any time from search.")
        }
    }

    // MARK: - Header / sync badge

    private var header: some View {
        HStack {
            Text("Tickers").font(HubType.pane).foregroundStyle(HubColor.inkPrimary)
            Spacer()
            syncBadge
        }
    }

    private var syncBadge: some View {
        StatusLine(state: model.tickerSync.hubState, title: model.tickerSync.hubLabel, style: .compact)
    }

    // MARK: - Search

    private var searchModule: some View {
        Card {
            HStack(spacing: HubSpace.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(HubColor.inkSecondary)
                    .font(HubType.control)
                TextField("Search Binance + Yahoo", text: $query)
                    .textFieldStyle(.plain)
                    .font(HubType.control)
                    .onChange(of: query) { runSearch($0) }
                if !query.isEmpty {
                    IconButton(systemImage: "xmark.circle.fill", label: "Clear search") {
                        query = ""; results = []
                    }
                }
            }
        }
    }

    // Debounce ~300ms: cancel the prior task, sleep, then call the merged search hook. A cancelled sleep
    // throws, which silently ends the task (no stale query fires).
    private func runSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            model.onSearchTickers?(trimmed) { merged in
                Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    results = merged
                }
            }
        }
    }

    // MARK: - Results

    private var resultsModule: some View {
        Card(padding: .rows) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty {
                        EmptyState(systemImage: "magnifyingglass",
                                   title: query.isEmpty ? "Type to search symbols." : "No matches.",
                                   message: query.isEmpty
                                       ? "Search Binance and Yahoo Finance by name or symbol."
                                       : "Try a different symbol or name.")
                    } else {
                        ForEach(results, id: \.row.id) { candidate in
                            resultRow(candidate)
                            RowSeparator(hasLeadingIcon: false)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 200)
    }

    // Name / symbol-middot-exchange is design SS3.4's own row-depth benchmark (the same join
    // PageDesignerChartPopover.instrumentSecondary uses for the chart's instrument search) -- applied
    // here too so a Yahoo result stays distinguishable from a same-named lookalike, plus the source chip
    // so a symbol that exists on both Binance and Yahoo is never ambiguous about which one "Add" wires up.
    @ViewBuilder
    private func resultRow(_ candidate: TickerCandidate) -> some View {
        VStack(alignment: .leading, spacing: HubSpace.xs) {
            HStack(spacing: HubSpace.s) {
                VStack(alignment: .leading, spacing: HubSpace.hair) {
                    Text(candidate.row.name)
                        .font(HubType.bodyEmph).foregroundStyle(HubColor.inkPrimary).lineLimit(1)
                    HStack(spacing: HubSpace.s) {
                        Text(resultSecondary(candidate))
                            .font(HubType.caption).foregroundStyle(HubColor.inkSecondary).lineLimit(1)
                        HubBadge(candidate.sourceLabel)
                    }
                }
                Spacer(minLength: HubSpace.s)
                if validatingID == candidate.row.id {
                    ProgressView().controlSize(.small)
                } else {
                    HubButton(title: "Add", kind: .primary, isEnabled: canAdd(candidate.row)) {
                        add(candidate.row)
                    }
                }
            }
            // A failed test-fetch is retryable (add again once the device is reachable), so it is `warn`,
            // not `error` (design SS3.3: "TickerEditorView uses red for a failed test-fetch ... miscast").
            // Text stays `inkPrimary` at `type.secondary`; the glyph alone carries the state colour.
            if let error = addErrors[candidate.row.id] {
                HStack(spacing: HubSpace.xs) {
                    Image(systemName: HubState.warn.glyph)
                        .foregroundStyle(HubState.warn.tint).font(HubType.caption)
                    Text(error).font(HubType.secondary).foregroundStyle(HubColor.inkPrimary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, HubSpace.m).padding(.vertical, HubSpace.s)
    }

    private func resultSecondary(_ candidate: TickerCandidate) -> String {
        guard let exchange = candidate.exchange, !exchange.isEmpty else { return candidate.row.sym }
        return "\(candidate.row.sym) \u{00B7} \(exchange)"
    }

    private func canAdd(_ row: TickerRow) -> Bool {
        working.count < ChartInstrumentSelection.maxTickers && !working.contains { $0.id == row.id }
    }

    // MARK: - Current list

    private var isFull: Bool { working.count >= ChartInstrumentSelection.maxTickers }

    private var currentListModule: some View {
        Card(padding: .rows) {
            VStack(spacing: 0) {
                HStack {
                    Text("Current list").font(HubType.section).foregroundStyle(HubColor.inkPrimary)
                    Spacer()
                    // "list is full" affordance (device caps at MAX_TICKERS): the counter used to recolour
                    // via the shared `state.warn` token at capacity, which is exactly the "state colour
                    // alone" pattern design SS2.3 bans -- there is no glyph here to offload the colour
                    // onto, and the WS-8 arithmetic contrast tests measure `state.warn` as `type.caption`
                    // text at ~2.1-2.3:1 in light appearance, below the 4.5:1 floor (worse than the plain
                    // `ink.secondary` count it replaced). `ink.primary` at capacity is both legible and
                    // more insistent than the everyday `ink.secondary` tally.
                    Text("\(working.count) / \(ChartInstrumentSelection.maxTickers)")
                        .font(HubType.caption.monospacedDigit())
                        .foregroundStyle(isFull ? HubColor.inkPrimary : HubColor.inkSecondary)
                }
                .padding(.horizontal, HubSpace.m).padding(.top, HubSpace.m).padding(.bottom, HubSpace.s)

                if working.isEmpty {
                    EmptyState(systemImage: "list.bullet",
                               title: "No tickers yet.",
                               message: "Add symbols from the search above.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(working.enumerated()), id: \.element.id) { idx, row in
                                currentRow(row, index: idx)
                                RowSeparator(hasLeadingIcon: false)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func currentRow(_ row: TickerRow, index: Int) -> some View {
        HStack(spacing: HubSpace.s) {
            VStack(alignment: .leading, spacing: HubSpace.hair) {
                Text(row.name).font(HubType.bodyEmph).foregroundStyle(HubColor.inkPrimary).lineLimit(1)
                Text(row.sym).font(HubType.caption).foregroundStyle(HubColor.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: HubSpace.s)
            // Labelled "earlier"/"later" (not "up"/"down" or "previous"/"next") naming the ticker moved --
            // design SS8.2's own phrasing for this exact reorder-chevron pattern.
            IconButton(systemImage: "chevron.up", label: "Move \(row.name) earlier", isEnabled: index > 0) {
                move(index, by: -1)
            }
            IconButton(systemImage: "chevron.down", label: "Move \(row.name) later",
                       isEnabled: index < working.count - 1) {
                move(index, by: 1)
            }
            IconButton(systemImage: "trash", label: "Remove \(row.name)") {
                pendingRemoval = row
            }
        }
        .padding(.horizontal, HubSpace.m).padding(.vertical, HubSpace.s)
    }

    // MARK: - Mutations (each commits via B3: persist + push)

    // Test-fetch the device's data endpoint before adding (issue #92): only a row that returns live data
    // joins the list. While validating, the row's Add button shows a spinner; on failure the reason is
    // surfaced inline and the row is NOT added. Ignore re-taps while a validation is already in flight.
    private func add(_ row: TickerRow) {
        guard working.count < ChartInstrumentSelection.maxTickers, !working.contains(where: { $0.id == row.id }), validatingID == nil
        else { return }
        addErrors[row.id] = nil
        guard let validate = model.onValidateTicker else {
            working.append(row); commit(); return   // no hook (bare dev build): keep the prior add behavior
        }
        validatingID = row.id
        validate(row) { ok, reason in
            validatingID = nil
            guard ok else { addErrors[row.id] = reason ?? "No live data for \(row.sym)"; return }
            guard working.count < ChartInstrumentSelection.maxTickers, !working.contains(where: { $0.id == row.id }) else { return }
            working.append(row)
            commit()
        }
    }

    private func remove(_ row: TickerRow) {
        // Keep at least one ticker: an empty list bumps rev but pushTickerConfig() no-ops (the firmware
        // rejects an empty snapshot), so hub + device would silently diverge with no ack (#92). The user
        // replaces the last ticker by adding another first, or removing then adding.
        guard working.count > 1 else { return }
        working.removeAll { $0.id == row.id }
        commit()
    }

    // Same reorder-chevron pattern as PageDesignerView.moveEnabled (design §8.2) -- gated the same way,
    // wrapped in `withAnimation` so a live reorder is not just correct but reads as one, and degrading to
    // instant under `accessibilityReduceMotion` (design §8.4).
    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard working.indices.contains(index), working.indices.contains(target) else { return }
        withAnimation(HubMotion.animation(HubMotion.normal, reduceMotion: reduceMotion)) {
            working.swapAt(index, target)
        }
        commit()
    }

    private func commit() { model.onApplyTickerEdit(working) }
}

// MARK: - Sync status vocabulary

private extension TickerSyncStatus {
    // Routes the sync indicator through the one shared status vocabulary (design SS3.3) instead of an
    // independent switch-based glyph/colour mapping -- this file was one of the five call sites SS3.3
    // names for consolidation into `HubState` (HubRows.swift).
    var hubState: HubState {
        switch self {
        case .idle:    return .notSetUp
        case .pending: return .checking
        case .synced:  return .ok
        case .error:   return .error
        }
    }

    var hubLabel: String {
        switch self {
        case .idle:            return "Not synced"
        case .pending:         return "Syncing\u{2026}"
        case .synced(let n):   return "Synced \(n)"
        case .error(let msg):  return "Error: \(msg)"
        }
    }
}
