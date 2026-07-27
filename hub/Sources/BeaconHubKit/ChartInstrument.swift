import Foundation

// Pure logic backing the page designer's Chart-instrument search (design 2026-07-26-yahoo-symbol-search):
// let the user pick ANY instrument Yahoo Finance knows about, not just the rows already in the ticker
// list. Kept out of PageDesignerView (SwiftUI) so the branching is host-tested, mirroring the precedent
// set by PageCatalog.editorRows.
//
// The device's chart option is a TICKER ID, not a raw symbol (resolve_chart() in
// firmware/src/fetch/series.cpp looks the id up in the device's ticker table) -- so choosing an arbitrary
// Yahoo symbol for the chart means adding it to the ticker list first. These two are the same operation.

public enum ChartInstrumentSearch {
    /// The chart page's device-side fetch speaks the Yahoo API only -- Binance rows have no meaning here.
    /// A merged Binance+Yahoo search hook (the one the standalone ticker editor uses) needs this filter
    /// before its results are valid choices for the chart instrument.
    public static func yahooOnly(_ candidates: [TickerCandidate]) -> [TickerCandidate] {
        candidates.filter { $0.row.src == .yahoo }
    }
}

public enum ChartInstrumentSelection {
    /// Firmware bound (MAX_TICKERS in firmware/src/config/tickers.h); mirrors what the standalone ticker
    /// editor (TickerEditorView) already enforces client-side, so this search cannot silently exceed it.
    public static let maxTickers = 16

    public enum Outcome: Equatable {
        /// The candidate's ticker id is already in the desired list: only the chart's `sym` option moves.
        case setExisting(sym: String)
        /// A brand-new instrument: this row must be added to the ticker list (persisted + pushed) before
        /// the chart option can point at it.
        case addAndSet(row: TickerRow)
        /// The list is already at the device's cap and the candidate is not already in it -- report this
        /// rather than silently dropping the pick.
        case tooManyTickers
    }

    /// Decide what picking `candidate` for the chart page means, given the CURRENT desired ticker list.
    /// Matching is by ticker id (same rule the standalone editor uses for its own dedup), so a candidate
    /// re-derived from the same (src, sym) via TickerID.make always lands on the same row.
    public static func resolve(candidate: TickerRow, currentList: [TickerRow],
                                maxTickers: Int = ChartInstrumentSelection.maxTickers) -> Outcome {
        if let existing = currentList.first(where: { $0.id == candidate.id }) {
            return .setExisting(sym: existing.id)
        }
        guard currentList.count < maxTickers else { return .tooManyTickers }
        return .addAndSet(row: candidate)
    }
}
