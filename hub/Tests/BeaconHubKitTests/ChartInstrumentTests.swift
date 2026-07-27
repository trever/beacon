import XCTest
@testable import BeaconHubKit

final class ChartInstrumentSearchTests: XCTestCase {
    func testYahooOnlyFiltersOutBinanceAndKeepsExchange() {
        let binanceRow = TickerRow(id: "b1", src: .binance, sym: "BTCUSDT", name: "BTC/USDT",
                                   kind: .crypto, cadence: 60, stale: 600, basis: .h24)
        let yahooRow = TickerRow(id: "y1", src: .yahoo, sym: "AAPL", name: "Apple Inc.",
                                 kind: .etf, cadence: 300, stale: 600, basis: .prevClose)
        let candidates = [
            TickerCandidate(row: binanceRow, sourceLabel: "Binance"),
            TickerCandidate(row: yahooRow, sourceLabel: "Yahoo", exchange: "NASDAQ"),
        ]

        let filtered = ChartInstrumentSearch.yahooOnly(candidates)
        XCTAssertEqual(filtered.map { $0.row.id }, ["y1"], "the chart fetch speaks Yahoo only")
        XCTAssertEqual(filtered.first?.exchange, "NASDAQ")
    }

    func testYahooOnlyOfEmptyIsEmpty() {
        XCTAssertTrue(ChartInstrumentSearch.yahooOnly([]).isEmpty)
    }
}

final class ChartInstrumentSelectionTests: XCTestCase {
    private func row(_ sym: String, id: String? = nil) -> TickerRow {
        TickerRow(id: id ?? TickerID.make(src: .yahoo, sym: sym), src: .yahoo, sym: sym, name: sym,
                  kind: .etf, cadence: 300, stale: 600, basis: .prevClose)
    }

    // "Already in list" branch (design step 3): picking a symbol that maps to an id already in the
    // desired list must only move the chart's sym option, never mint a duplicate row.
    func testCandidateAlreadyInListJustSetsSym() {
        let existing = row("AAPL")
        let outcome = ChartInstrumentSelection.resolve(candidate: existing, currentList: [existing])
        XCTAssertEqual(outcome, .setExisting(sym: existing.id))
    }

    // A search result whose id does not appear in the current list mints a new row -- this is the
    // TickerSearch-result -> row mapping the picker acts on.
    func testNewInstrumentIsMintedAndSet() {
        let existing = row("AAPL")
        let candidate = row("MSFT")
        let outcome = ChartInstrumentSelection.resolve(candidate: candidate, currentList: [existing])
        XCTAssertEqual(outcome, .addAndSet(row: candidate))
    }

    // Matching is by id (mirrors the standalone ticker editor's own dedup rule), not by symbol text, so a
    // candidate re-derived via the same TickerID.make from a different display name still matches.
    func testMatchingIsByIdNotDisplayName() {
        let existing = TickerRow(id: TickerID.make(src: .yahoo, sym: "AAPL"), src: .yahoo, sym: "AAPL",
                                 name: "Apple Inc.", kind: .etf, cadence: 300, stale: 600, basis: .prevClose)
        let candidate = TickerRow(id: TickerID.make(src: .yahoo, sym: "AAPL"), src: .yahoo, sym: "AAPL",
                                  name: "Apple", kind: .etf, cadence: 300, stale: 600, basis: .prevClose)
        let outcome = ChartInstrumentSelection.resolve(candidate: candidate, currentList: [existing])
        XCTAssertEqual(outcome, .setExisting(sym: existing.id))
    }

    // Cap awareness (design step 6): adding beyond MAX_TICKERS must report tooManyTickers rather than
    // silently dropping the pick or minting a row the device would reject as "too_many_tickers".
    func testCapReachedReportsTooManyTickersRatherThanDropping() {
        let existing = (0..<ChartInstrumentSelection.maxTickers).map { row("SYM\($0)") }
        let candidate = row("NEWSYM")
        let outcome = ChartInstrumentSelection.resolve(candidate: candidate, currentList: existing)
        XCTAssertEqual(outcome, .tooManyTickers)
    }

    // Re-selecting an instrument that's already in a full list must still work -- the cap only blocks
    // adding a NEW row, not pointing the chart at one that's already there.
    func testAlreadyInListStillWorksEvenAtCap() {
        let existing = (0..<ChartInstrumentSelection.maxTickers).map { row("SYM\($0)") }
        let candidate = existing[3]
        let outcome = ChartInstrumentSelection.resolve(candidate: candidate, currentList: existing)
        XCTAssertEqual(outcome, .setExisting(sym: candidate.id))
    }

    func testCustomCapIsHonored() {
        let existing = (0..<2).map { row("SYM\($0)") }
        let candidate = row("NEWSYM")
        XCTAssertEqual(ChartInstrumentSelection.resolve(candidate: candidate, currentList: existing, maxTickers: 2),
                       .tooManyTickers)
        XCTAssertEqual(ChartInstrumentSelection.resolve(candidate: candidate, currentList: existing, maxTickers: 3),
                       .addAndSet(row: candidate))
    }
}
