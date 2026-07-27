# Plan: search any Yahoo symbol when choosing the Chart instrument

**Status:** open. Written 2026-07-26. Self-contained — assumes no prior session context.

## Goal

The page designer's Chart card currently offers a `Picker` limited to Yahoo rows already in the user's
ticker list (8 by default). The user wants to select **any instrument available on Yahoo Finance**.

## What exists already (reuse, do not rebuild)

- **`hub/Sources/beacon-hub/TickerSearch.swift`** already does live Yahoo symbol lookup plus a cached
  Binance list. It was built for the ticker editor (issue #92 B4) and is the search backend to reuse.
- **`hub/Sources/beacon-hub/TickerEditorView.swift`** is the existing search-and-add UI; read it for the
  established interaction and result-row idiom before inventing another.
- **`hub/Sources/beacon-hub/PageDesignerView.swift`** holds `PageOptions`, the per-card options view with
  the current chart picker.
- **`TickerConfigStore`** owns the desired ticker list and a monotonic `rev`; pushing it to the device is
  `pushTickerConfig()` in `AppDelegate`.

## The design constraint that shapes this

The device's chart option is a **ticker id**, not a raw symbol — deliberately. `resolve_chart()` in
`firmware/src/fetch/series.cpp` looks the id up in the device's ticker table to get the Yahoo symbol and
display name, so there is no free-form text to escape or validate on the wire, and the device can fall
back cleanly when an id is unknown.

**Therefore: choosing an arbitrary Yahoo symbol means adding it to the ticker list.** The two are the same
operation. Searching Yahoo and picking a result must (a) add that row to `TickerConfigStore`, (b) push the
ticker config, and (c) set the chart page's `sym` option to the new id.

Do not shortcut this by sending a raw symbol in `opts` — that would bypass the device's table, duplicate
the symbol-encoding rules on both sides, and break the fallback behaviour.

## Steps

1. **Replace the `Picker` in `PageOptions` with a search control.** A button showing the current
   instrument that opens a popover containing a search field and results list, so the card stays compact.
2. **Wire the search** to `TickerSearch`'s Yahoo path, debounced. Show name + symbol + exchange so the
   user can tell `AAPL` apart from lookalikes.
3. **On selecting a result:**
   - If the symbol is already in the ticker list, just set `opts["sym"]` to its id.
   - Otherwise mint a row (id derivation must match the existing rule used by the ticker editor — do not
     invent a second scheme), add it to `TickerConfigStore`, and set `opts["sym"]` to it.
   - Mark the page list dirty so **Save & push** lights up.
4. **Push both** on Save: the ticker config (`pushTickerConfig`) *before* the page config, so the device
   has the row before it is told to chart it. Note the page push restarts the device; the ticker push does
   not. Verify the ordering actually holds across the restart — if the device reboots before persisting
   the ticker row, re-push on reconnect (the existing reconnect path already re-sends ticker config).
5. **Handle the orphan case.** `PageOptions.orphan` already surfaces a stored instrument that is no longer
   in the list as its own marked entry; keep that behaviour and make sure a search result cannot silently
   replace it.
6. **Cap awareness.** The ticker list has a device-side maximum (`MAX_TICKERS` in
   `firmware/src/config/ticker_table.h`); adding beyond it must report `too_many_tickers` rather than
   silently dropping. Check what the existing editor does and match it.

## Testing

- `TickerSearch` result → row mapping, and the "already in list" branch, in `BeaconHubKitTests` or
  `beacon-hubTests` (271 hub tests passing as of 2026-07-26).
- Keep pure logic out of the SwiftUI view so it is testable — the pattern used for
  `PageCatalog.editorRows` (pure function in `BeaconHubKit`, view just maps it) is the precedent.
- `swift build && swift test` in `hub/`.

## UI verification without clicking

`ImageRenderer` renders SwiftUI to PNG in a throwaway test, which is how the designer layout was checked.
Two caveats learned the hard way: it does **not** rasterize `ScrollView` content (renders blank), and it
draws interactive AppKit-backed controls (`Toggle`, `Picker`, `Button`) as yellow placeholder boxes.
Render the content without its scroll container to see the layout.

## Definition of done

- Any Yahoo-listed instrument can be chosen for the Chart page from the hub.
- Selecting one adds the ticker row and sets the page option in a single user action.
- The device charts it after one restart, with the header showing the right name.
- No raw symbols on the `pages` wire — the option stays a ticker id.

## Platform notes

- The package targets **macOS 13**: `onChange`'s two-parameter overload is macOS 14 and will not compile.
- Large SwiftUI bodies hit "unable to type-check this expression in reasonable time"; split into
  subexpressions or small `@ViewBuilder` members.
