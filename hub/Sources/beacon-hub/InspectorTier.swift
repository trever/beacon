import Foundation

// The inspector's own layout rule (design 2026-07-27-hub-visual-system SS5.2.1, plan WS-2 item 7): an
// inspector is a bounded-width, top-aligned pane that never stretches a control to fill height, and when
// it runs out of options it fills the remainder with THE THING IT CONFIGURES -- not with nothing, and not
// with an empty state. This is a pure function of "how many options does the selected page have," kept
// separate from PageDesignerView's SwiftUI body so the fix is unit-tested (InspectorTierTests) rather
// than only asserted by the human script in design SS8.3.

/// The three inspector layouts, keyed by option count (design SS5.2.1). `previewOnly` and
/// `optionsPlusPreview` both render the "What this page shows" block; `optionsOnly` drops it because the
/// carousel card above already shows the page, and repeating it would waste the column.
enum InspectorTier: Equatable {
    /// 0 options. Header, hairline, then "What this page shows" -- there is nothing to configure, so the
    /// device preview is the useful thing to look at. Never a "No options" string.
    case previewOnly
    /// 1-2 options. Header, hairline, the options, hairline, then the SAME "What this page shows" block.
    /// This is the Sonos case: a room `Menu` plus a picture of the page the room feeds, so the dropdown
    /// stops reading as one control alone in an otherwise empty column.
    case optionsPlusPreview
    /// 3+ options. Header, hairline, options fill the column; the preview drops out.
    case optionsOnly
}

enum InspectorLayout {
    /// design SS5.2.1's table, `0` / `1...2` / `3+`, as a total function. A negative count cannot occur
    /// from any real caller (option counts are array/dictionary sizes), but falls back to `.previewOnly`
    /// rather than crashing, since "nothing to configure" is the closest honest reading of it.
    static func tier(optionCount: Int) -> InspectorTier {
        switch optionCount {
        case ..<1: return .previewOnly
        case 1...2: return .optionsPlusPreview
        default: return .optionsOnly
        }
    }
}
