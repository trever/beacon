# Hub visual system

**Status:** design, not yet built. Written 2026-07-27.

**Authority.** `DESIGN.md` owns the **device's** visual system — theme tokens, the 7-theme catalog, the
safe area, the screen-state table. This document owns the **hub's**, and nothing else. The two are
deliberately different systems with a drawn boundary (§6); neither reads the other's tokens. Where this
doc and `DESIGN.md` disagree about something on the 466×466 panel, `DESIGN.md` wins. Where they disagree
about something in a Mac window, this doc wins.

**Constraint that shapes everything.** `hub/` is Swift 6, SwiftPM, **no third-party dependencies**
(`CLAUDE.md`). That is a project rule, not a preference, and it is not relitigated here. Everything below
is AppKit and SwiftUI. The one thing that would normally come from a library — a token layer — is about
150 lines of `enum` in one file.

---

## 0. Bottom line — the six calls

| | Call | Why |
|---|---|---|
| **1. Tokens** | One `HubStyle.swift`: 6 spacing steps (the *same* 4/8/12/16/24/32 ladder the device uses), **9 type roles mapped to macOS text styles**, 15 semantic colours, **2 corner radii**, 1 shadow. `.font(.system(size:))` becomes illegal in hub chrome. | 154 raw font-size call sites across 12 point sizes; 6 numeric corner radii across 7 files; 9 fill opacities. There is no system to violate, so every session invents one. |
| **2. Rows** | One `SettingsRow` / `StatusRow` / `ListRow` triad replaces **ten** row implementations. | No two of the ten agree on label size, padding, or separator inset — and two of them render *the same store* differently in the same window. |
| **3. Navigation** | `NSToolbar` in `.preference` style on the real `NSWindow`, not SwiftUI `TabView`. Dirty state = `window.isDocumentEdited` + a dot on the *unselected* dirty item. | The pill bar is a palette idiom, gives no window title, and its badge API does not render — which is why the code appends `"•"` to a tab title. Own the item view and the problem disappears. |
| **4. Density** | The inspector is a **fixed 280 pt column, top-aligned, shrink-wrapped**, and it fills its remaining height with *the page's own device preview*, not with nothing. | "This page has one option" is not a reason to show one dropdown in a lake. The honest thing to put under a page's options is a picture of the page. |
| **5. Two languages** | The panel edge is a **hard boundary with a drawn bezel**. Device tokens live in one file; nothing hub-styled is drawn inside the panel rect, and nothing device-styled leaks out of it. | A preview that adopts hub styling is lying about what the device shows. Today an SF Symbol renders inside the glass and a hub close-button sits on top of it. |
| **6. Dark mode** | Every fill is a **dynamic light/dark pair**, not one opacity. `Color.white` / `Color.black` are banned in chrome. Every component preview ships in both schemes. | A fixed 6% overlay that reads correctly on `#ECECEC` is nearly invisible on `#323232`. Three hard black/white decisions ship today. |

---

## 1. The audit

Read before proposing anything. Everything in this section is a count or a file reference, not an
adjective.

### 1.1 The numbers

| Dimension | Distinct values in `hub/Sources/beacon-hub/` | Should be |
|---|---|---|
| Font sizes (`.system(size:)`) | **12** — 8, 9, 10, 10.5, 11, 12, 13, 14, 15, 16, 21, + `size × k` | 9 named roles |
| `.font(.system(size:))` call sites | **154** | 0 in chrome |
| Semantic text styles (`.body`, `.headline`, …) | **0** | all of them |
| Corner radii | **6** numeric — 6, 7, 8, 10, 12, 13 — plus `size × 0.22` | 2 + capsule |
| Fill opacities | **9** — .06, .08, .10, .12, .14, .18, .25, .30, .55 | 4 dynamic pairs |
| Padding values | **19** distinct numbers, 1–20 | 6-step ladder |
| Separator leading insets | **3** — 11, 12, 42 — with no rule | 1 rule |
| Row implementations | **10** (§1.2) | 3 |
| Status-glyph vocabularies | **5** independent switch statements | 1 |
| Colours hardcoded past a semantic role | `Color.blue` ×4, `Color.black` ×3, `Color.white` ×2, `.green` ×10, `.orange` ×12, `.red` ×7 | roles only |

Corner radii by file: `DeckUI.swift` 7 and 13 · `HubPanel.swift` 13 · `PageDesignerView.swift` 6, 7, 10,
12 · `ComplicationEditorView.swift` 8 · `TickerEditorView.swift` (capsule only) · `DevicePreview.swift`
`size × 0.22`. Four radii in one file (`PageDesignerView.swift`) is the tell.

### 1.2 Ten ways to draw a row

| Row | File:line | Label | Secondary | H pad | V pad |
|---|---|---|---|---|---|
| `ToggleRow` | `DeckUI.swift:63` | 13 regular | 10 | 12 | 9 |
| `StatusRow` | `SettingsPanel.swift:21` | 13 regular | 11 | 13 | 12 |
| `ProviderRow` | `SourcesTab.swift:68` | 13 medium | 11 | 12 | 11 |
| `AgentProviderRow` | `PageDesignerView.swift:756` | **11 medium** | 10 | — | 4 |
| `InstrumentRow` | `PageDesignerView.swift:704` | 12 medium | 10 | 8 | 6 |
| `RoomRow` | `PageDesignerView.swift:901` | 12 medium | — | 8 | 6 |
| `ComplicationStackRow` | `ComplicationEditorView.swift:192` | 12 medium | 10 | 10 | 8 |
| `ResultRow` | `TickerEditorView.swift:191` | 12 medium | 10 | 11 | 8 |
| `CurrentRow` | `TickerEditorView.swift:223` | 12 medium | 10 | 11 | 8 |
| `WindowRow` | `HubPanel.swift:162` | 10 semibold | 10 | — | — |

Four label sizes. Five horizontal paddings. Six vertical paddings. None of it decided; all of it inherited
from whatever file the next feature landed in.

**The worst instance is not drift, it is divergence.** `SourcesTab.ProviderRow` and
`PageDesignerView.AgentProviderRow` are bound to the *same* `model.providers`, the *same*
`onSetProviderUsage` / `onSetProviderBuddy` / `onInstallProviderHooks`, and are visible in the *same
window* one tab apart. They render:

| | Sources tab | Agents page inspector |
|---|---|---|
| Provider name | 13 medium | 11 medium |
| Toggle | `.switch`, regular | `.switch`, **`.controlSize(.mini)`** |
| Toggle labels | column headers, 11 + icon | inline text, 10 secondary |
| "Ready" chip | `Label` + `checkmark.circle.fill`, 11 medium, green | `Text` only, **no glyph**, 10 medium, green |
| "Setting up…" | disabled `DeckButton` | plain secondary `Text` |
| Unsupported | `—` at default size | `—` at 10 |

The file comment at `PageDesignerView.swift:740` names the cause exactly: *"A visually distinct,
file-local rendering of the same store/intents"* — because `SourcesTab`'s version is `private` and was
off-limits to that workstream. That is the whole disease in one sentence. A shared component layer is the
cure, and it is the reason this document exists rather than a lint rule.

Five independent state→glyph→colour mappings: `SettingsPanel.swift:46`, `SonosSettingsView.swift:100`,
`SourcesTab.swift:101`, `PageDesignerView.swift:775`, `TickerEditorView.swift:289`. Three of them use
green for "ok"; two of them agree on the glyph.

### 1.3 The six named problems, diagnosed

**(1) The tab bar.** `SettingsTabs.swift:59` — SwiftUI `TabView` hosted inside a real `NSWindow`. On macOS
this renders a centered segmented control at the top of the content area. It is the `NSTabView` palette
idiom: correct for an inspector, wrong for a window that owns four top-level destinations. It gives no
per-tab window title, does not participate in the toolbar, cannot host a search field, and — per the
comment at `SettingsTabs.swift:80` — its `.badge(_:)` does not reliably render, which is why the dirty
state is communicated by appending `"\u{2022}"` to the string `"Pages"`. A design system that has to
concatenate a bullet into a title has lost the argument. See §4.

**(2) The Sonos room selector.** `PageDesignerView.swift:476` is a hand-built `Button` — an `HStack` with
a chevron, `Color.primary.opacity(0.06)`, `cornerRadius: 6` — that reinvents `Menu` badly (no native
disclosure, no keyboard nav, no native highlight, no automatic dark-mode treatment). It opens
`SonosRoomPopover` (`:830`), whose rows (`RoomRow`, `:901`) carry **one field**: a name. Twenty lines
below in the same file, `InstrumentRow` (`:704`) carries name, symbol and exchange in a two-line stack.
Same file, same week, two answers to "what is a pickable thing". The Sonos Control API's `groups`
response already carries `playerIds` and `coordinatorId`, so player count and coordinator are derivable
today. See §3.4 and §5.

**(3) The inspector's empty area.** `PageDesignerView.swift:148` — `.frame(maxWidth: .infinity, maxHeight:
.infinity, alignment: .topLeading)`. The inspector takes every pixel left over after a 300 pt grid, then
top-left-aligns a single 11 pt dropdown into it. With no options at all it renders the string `"No
options"` at `.secondary.opacity(0.6)` (`:441`) in the corner of a ~400 × 500 void. The layout has no
concept of "this pane has less content than height". See §5.

**(4) The carousel band.** `PageDesignerView.swift:83` — `Color(nsColor: .underPageBackgroundColor)`. That
system colour's documented role is *the area behind a document page* (the grey around a sheet in Preview
or Pages). Used as a full-bleed section band under a titled header, it reads as unfinished chrome because
it is chrome for something else. See §3.5.

**(5) The AVAILABLE tiles.** `PageDesignerView.swift:372` — three text lines at **12 medium / 9 secondary
/ 8 semibold green**, then `.opacity(row.enabled ? 0.55 : 1)` on the whole tile. So the least important
line ("on the Beacon") is the most saturated element, and it is simultaneously the brightest colour *and*
45 % faded. Title-to-caption ratio is 12:8 — a 1.5× step where `DESIGN.md` requires ≥ 1.25 *and* a weight
change to carry hierarchy. Status is competing as text when it should be a mark. See §3.7.

**(6) Dark appearance.** Never examined. Three hard-coded decisions ship: `Color.white` foreground on
`Color.blue` in `DeckUI.swift:49`; `Color.black.opacity(0.55)` behind the "hidden" capsule at
`PageDesignerView.swift:181`; the same behind the remove `x` at `:321`. Nine fill opacities are tuned for
`#ECECEC` and applied unchanged over `#323232`. Zero `#Preview` blocks set a `colorScheme`. See §7.

### 1.4 Things that are already right — copy these, don't rewrite them

- `MenubarController.applyBarIcon()` (`:270`) sets `contentTintColor` on **every** path and uses `nil`
  (adaptive) for connectivity states. That is the correct dark-mode discipline; it is the only place in
  the codebase that has it.
- `SonosSettingsSection`'s two `.alert` confirmations (`SonosSettingsView.swift:58`) name the object, say
  what is lost, *and* say what is kept. That is the destructive-confirmation pattern (§3.10).
- `HubPanel.ProviderCard` (`:147`) is the only view with `.accessibilityElement(children: .combine)` +
  label + a composed value. That is the VoiceOver pattern (§8).
- `CarouselCard.borderColor` as a computed `private var` rather than a ternary inline in the modifier —
  that is the shape every token accessor must take, for type-checker reasons (§9.2).
- `DevicePreview`'s file header ("HONEST SCOPE: this is a REPRESENTATION… treat it as a wireframe") is
  the right posture. §6 makes it visual instead of a comment.

---

## 2. Tokens

One file, `hub/Sources/beacon-hub/HubStyle.swift`. Stored constants and typed statics only — never
computed expressions inlined into a modifier (§9.2).

### 2.1 Spacing

The hub uses **the same ladder as the device** (`DESIGN.md`: "`space` 4/8/12/16/24/32 rhythm"). Two
spacing scales in one product is one too many, and the device's ladder is already load-bearing.

| Token | Value | Use |
|---|---|---|
| `space.xs` | 4 | A label to its own secondary line. Nothing else. |
| `space.s` | 8 | Element to element inside a row; button to button. |
| `space.m` | 12 | Row content inset; a section header to its content. |
| `space.l` | 16 | Card padding; grid gutter. |
| `space.xl` | 24 | Section to section; the window content gutter; footer horizontal inset. |
| `space.xxl` | 32 | Empty-state padding; the top of a pane above its first header. |

`2` survives as a single named exception, `space.hair`, for optical baseline nudges inside a text stack —
never as layout. Anything not on this ladder is a bug.

### 2.2 Type

**Nine roles, all mapped to macOS system text styles.** The point sizes below are what macOS resolves at
the default text size; they are documentation, not the API. Code writes `.font(.headline)`, never
`.font(.system(size: 13, weight: .semibold))` — that is the entire reason this table exists (§8, larger
text sizes).

| Token | Style | Weight | ≈ pt | Use |
|---|---|---|---|---|
| `type.pane` | `.title3` | semibold | 15 | The one title at the top of a pane. Max one per pane. |
| `type.figure` | `.title` | bold, `.monospacedDigit()` | 22 | The single big number on a surface (usage %). |
| `type.section` | `.headline` | semibold | 13 | Section header title. |
| `type.body` | `.body` | regular | 13 | Row labels, primary text, prose. |
| `type.bodyEmph` | `.body` | medium | 13 | The selected/current row's label. Only that. |
| `type.control` | `.callout` | regular | 12 | Button titles, field text, menu labels. |
| `type.secondary` | `.subheadline` | regular | 11 | Descriptions, hints, status lines, section subtitles. |
| `type.caption` | `.caption` | regular | 10 | Badge text, column headers, units. |
| `type.eyebrow` | `.caption` | semibold, `.tracking(0.6)`, uppercased | 10 | Group labels inside a pane ("AVAILABLE"). |

Rules, mirroring `DESIGN.md`'s typography rules rather than inventing new ones:

- **Hierarchy comes from a ≥ 1.25 size step *or* a weight step, never from colour.** Today the AVAILABLE
  tile tries to get a third level from green, and fails (§1.3).
- **Tabular numerals everywhere a figure changes** — `.monospacedDigit()` on usage percentages, ticker
  counts, slot counts, "n of m" labels. Values that jitter in width read as broken.
- **A pane never uses more than four roles.** If it needs five, it is two panes.
- **Prose is capped at 560 pt.** A hint that runs the full width of a resized window is unreadable.
- `.system(size:)` is legal in exactly one place: `DevicePreview` and its sketches, which scale off the
  panel size (§6). That file is device glass, not hub chrome.

### 2.3 Colour

Fifteen roles. System colours wherever one exists — a Mac app that hard-codes greys is the tell. The hex
column is for contrast checking (§8), not for typing into code.

| Token | Light | Dark | Implementation |
|---|---|---|---|
| `surface.window` | ≈ `#ECECEC` | ≈ `#323232` | `NSColor.windowBackgroundColor` |
| `surface.content` | ≈ `#FFFFFF` | ≈ `#1E1E1E` | `NSColor.controlBackgroundColor` — scrollable content panes |
| `fill.card` | `primary` @ **4 %** | `primary` @ **7 %** | dynamic (below) |
| `fill.control` | `primary` @ **7 %** | `primary` @ **10 %** | dynamic |
| `fill.controlPressed` | `primary` @ **12 %** | `primary` @ **16 %** | dynamic |
| `fill.selected` | `accent` @ **12 %** | `accent` @ **20 %** | dynamic |
| `ink.primary` | `#000` @ 85 % | `#FFF` @ 85 % | `NSColor.labelColor` |
| `ink.secondary` | `#000` @ 50 % | `#FFF` @ 55 % | `NSColor.secondaryLabelColor` |
| `ink.tertiary` | `#000` @ 26 % | `#FFF` @ 26 % | `NSColor.tertiaryLabelColor` — **decorative only** |
| `line.hairline` | ≈ `#000` @ 10 % | ≈ `#FFF` @ 13 % | `NSColor.separatorColor`, 1 px |
| `accent` | user's | user's | `Color.accentColor` — never `Color.blue` |
| `state.ok` | | | `NSColor.systemGreen` + `checkmark.circle.fill` |
| `state.warn` | | | `NSColor.systemOrange` + `exclamationmark.triangle.fill` |
| `state.error` | | | `NSColor.systemRed` + `xmark.octagon.fill` |
| `state.pending` | | | `ink.secondary` + `circle.dashed` |

**Dynamic fills.** The four `fill.*` tokens differ by appearance because a fixed opacity that reads
correctly over `#ECECEC` is nearly invisible over `#323232`. Implement with
`NSColor(name: nil) { appearance in … }` rather than an `@Environment(\.colorScheme)` branch: an
`NSColor` dynamic provider resolves correctly inside `NSHostingController`, inside an `NSPopover`'s
vibrancy material, and in a live appearance switch, with no SwiftUI plumbing and no per-view state.

**State is never colour alone.** Directly inherited from `DESIGN.md`'s finance rule ("paired with sign +
glyph, never color alone"). Every `state.*` token is a triple — glyph, colour, and a word — and the word
is `ink.primary`, not the state colour. `state.ok` green at 11 pt on a card is ≈ 2.3:1 in light
appearance; as a *glyph* beside black text it is decoration and the contrast requirement falls on the
text, which passes. This is a legibility fix, not only a consistency one.

**`accent` is the user's system accent, everywhere.** Not `Color.blue` (4 sites today), not the device's
`#ff4a2b`. A Mac app that ignores the accent colour looks like a web page. The cost — the hub and the
device share no colour identity — is real and raised in §11.

**`ink.tertiary` may not carry content.** At 26 % it is ≈ 2.8:1 against `surface.content` in both
appearances: below the 4.5:1 floor (§8). Today it carries "Not reported by this firmware build"
(`DeviceTab.swift:90`) and the unsupported `—` markers; `PageDesignerView.swift:441` goes further with
`.secondary.opacity(0.6)` ≈ 30 %. All of those are content. They move to `ink.secondary`.

### 2.4 Radius, stroke, separator, shadow

| Token | Value | Use |
|---|---|---|
| `radius.control` | **6** | Buttons, fields, chips, menu labels, small tap targets. |
| `radius.card` | **10** | Cards, modules, tiles, popover content blocks. |
| `radius.pill` | `Capsule()` | Badges only — text-in-a-capsule, never a container. |

Two numbers. Everything currently at 7, 8, 12 or 13 rounds to one of them. All rounded shapes use
`style: .continuous`.

**Stroke.**

- `stroke.hairline` = **1 px**, `line.hairline`. Cards, separators, tile borders — all of them.
- **Selection never changes stroke width.** Today `CarouselCard` (`:349`) and `AvailableTile` (`:391`) go
  1 px → 2 px on selection, which moves the card's content box by 1 px on every edge — a visible jump
  when you click. Selection changes the stroke *colour* to `accent` and adds `fill.selected` behind. If
  more emphasis is needed, a second 2 px `accent` ring is drawn **outside** the shape's bounds via
  `.overlay` + `.padding(-3)`, so layout never moves.

**Separator inset.** One rule, replacing three ad-hoc values (11, 12, 42):

> A separator's leading inset equals the x-position of the row's **first text column**.

So a plain row insets 12; a row with a 20 pt leading icon column plus `space.m` insets 44. It is derived,
never typed as a literal.

**Shadow.** Exactly one, and only on cards that represent a physical object (device previews, §6):

| Token | Light | Dark |
|---|---|---|
| `shadow.card` | black @ 12 %, y 1, blur 3 | black @ 40 %, y 1, blur 4 |

Every other card is flat. Shadows on flat settings rows are an iOS habit.

### 2.5 Control sizing

| Token | Value | Notes |
|---|---|---|
| `control.size` | `.regular` | `.small` allowed **only** inside an `NSPopover`. **`.mini` is banned** — it is why the same switch has two sizes today. |
| `control.height` | 22 | Text button, popup button, text field. |
| `control.heightProminent` | 28 | Footer primary action only. |
| `control.hitMin` | **28 × 28** | Every icon-only button's frame. Today: 20×18 (`PageDesignerView.swift:363`) and 22×22 (`TickerEditorView.swift:254`). |
| `control.iconColumn` | 20 | Fixed **width** only. Never a fixed height (§8). |
| `control.fieldMinWidth` | 180 | Text fields never shrink below this. |

**Disabled state uses SwiftUI's own dimming.** `DeckButton` currently applies `.disabled(!enabled)` *and*
`.opacity(enabled ? 1 : 0.5)`, and `PageDesignerView`'s footer then applies `.opacity(0.4)` on top of the
result — three multiplied dimmings on "Save & push". Remove both manual opacities.

### 2.6 Motion

Borrowed wholesale from `DESIGN.md` so the two halves of the product feel related:

| Token | Value |
|---|---|
| `dur.fast` | 120 ms — hover, press, selection |
| `dur` | 220 ms — reorder, disclosure, tab content swap |
| `dur.slow` | 400 ms — nothing today; reserved |

Easing: ease-out, no bounce, no spring. **Every animation checks
`@Environment(\.accessibilityReduceMotion)` and degrades to instant.** The device is required to have a
reduced-motion path; the hub does not get to be laxer than the device.

---

## 3. Components

Eleven. Each is buildable from this section alone.

### 3.1 Section header

```
Providers                              ← type.section
Toggle what each agent sends           ← type.secondary, optional
```

- `VStack(alignment: .leading, spacing: space.xs)`. Today `SectionHeader` uses `spacing: 1`
  (`SettingsPanel.swift:13`), which crowds 13 pt over 11 pt.
- `space.m` below, before its content group. `space.xl` above, except as the first element in a pane.
- **Never inside a card.** A header labels a group; putting it in the group is circular.
- Subtitle is a sentence fragment, no terminal period, ≤ 80 characters.

### 3.2 Settings row

The workhorse. Replaces `ToggleRow`, `ProviderRow`, `AgentProviderRow`.

```
┌───────────────────────────────────────────────────────────┐
│ [icon]  Start at login                          ( ●——— )  │  36 min height
│  20pt   Approve in Login Items                            │  52 when 2-line
└───────────────────────────────────────────────────────────┘
  12      space.m                                        12
```

| Slot | Token | Notes |
|---|---|---|
| Leading icon | `control.iconColumn` (20) wide, `ink.secondary` | Optional. Present or absent **per group**, never per row. |
| Label | `type.body` | |
| Secondary line | `type.secondary`, `ink.secondary`, `space.xs` below the label | Optional. |
| Trailing | exactly **one** control | Two controls means it is two rows. |
| Height | `minHeight` 36 / 52 | Never `height` (§8). |
| Inset | `space.m` leading and trailing | |

- Rows stack inside a card with `padding: 0`, separated by `line.hairline` at the derived inset (§2.4).
- **The row is not a tap target.** A switch row toggles on the switch. Whole-row tapping is an iOS idiom;
  on macOS it produces accidental toggles when the user meant to select text.
- A row whose control is unsupported shows `—` in `ink.secondary` at `type.body` — same size as the label
  it aligns with, not 10 pt (`PageDesignerView.swift:794`).

### 3.3 Status row

A settings row whose leading column is a **state glyph** from one fixed vocabulary, replacing the five
independent mappings in §1.2. This is the hub's analogue of `DESIGN.md`'s screen-state table, and it is
the same idea: enumerate the non-happy states once, centrally, so no surface invents its own.

| State | Glyph | Colour | Title | Trailing |
|---|---|---|---|---|
| `checking` | `circle.dashed` | `ink.tertiary` | "Checking…" | none |
| `notSetUp` | `circle` | `ink.secondary` | the thing's name | the fix button, which names the action |
| `ok` | `checkmark.circle.fill` | `state.ok` | "Ready" / "Connected" | none |
| `warn` | `exclamationmark.triangle.fill` | `state.warn` | terse cause | "Retry" / the fix |
| `error` | `xmark.octagon.fill` | `state.error` | terse cause | "Retry" / the fix |

- `checking` never renders as `notSetUp`. `SettingsPanel.swift:46` and `MenubarHooksHint` already get this
  right, deliberately; the vocabulary makes it structural.
- **`warn` vs `error`:** recoverable-by-the-user is `warn`; recoverable-only-by-changing-something-else is
  `error`. Today `SonosSettingsView` uses orange for "you have not set a Client ID yet" (a normal first-run
  state, which should be `notSetUp`) and `TickerEditorView` uses red for a failed test-fetch (retryable,
  so `warn`). Both are miscast.
- Titles are `ink.primary` even in `warn`/`error`; the glyph carries the colour (§2.3).
- The glyph column is `control.iconColumn` wide so status rows and settings rows share a text baseline
  when stacked in one card.

### 3.4 List row with selection

For pickable things — popovers, menus, search results. Replaces `InstrumentRow`, `RoomRow`, `ResultRow`,
`CurrentRow`, `ArgPickerList`'s inline button.

```
┌──────────────────────────────────────────────┐
│ S&P 500                                    ✓ │  ← type.bodyEmph when current
│ ^GSPC · NYSE                                 │  ← type.caption, ink.secondary
└──────────────────────────────────────────────┘
```

- Primary `type.body` (`type.bodyEmph` when current); secondary is a single `·`-joined line at
  `type.caption`.
- **Every list row carries at least two fields where a second field exists.** This is the rule that fixes
  problem 2: a room is not just a name. Sonos groups carry a coordinator and a player count, so the row is
  `Kitchen` / `2 players · playing`. If a second field genuinely does not exist, the row is one line — but
  that must be a fact about the data, not about who wrote the view.
- Current: `fill.selected` at `radius.control`, `accent` `checkmark`. Never a hard-coded `.blue`
  checkmark (`PageDesignerView.swift:725`, `:912`).
- Selected + hover: `fill.controlPressed` composited over.
- **A list of a known, bounded set is a `Menu` or `Picker`, not a hand-built button + popover.** The
  chart instrument needs search (every Yahoo symbol), so it keeps a popover. The room list is < 12 items:
  it becomes a `Menu`, which gets native disclosure, keyboard navigation, highlight and dark mode for
  free, and deletes `SonosRoomPopover`'s hand-rolled chrome. Async states live inside the menu as
  disabled items plus a "Retry" item.

### 3.5 Card

- `fill.card` at `radius.card`, `stroke.hairline` border, `space.l` padding — or **zero** padding when it
  hosts rows, which own their own inset.
- **A card never contains a card.** One nesting level. The current `Module` is close to right; it lacks
  the border, which is what makes a 4 % fill legible in light appearance.
- **A card is never full-bleed.** A card that touches its container's edges is a background, and a
  background should be a background. This is problem 4: `underPageBackgroundColor` full-bleed under the
  carousel is a background pretending to be a section.

  **The carousel band takes no fill at all** — `surface.window`, bounded by `line.hairline` top and
  bottom, exactly like a toolbar-adjacent band. The device-preview cards carry the visual weight. This is
  `DESIGN.md`'s Editorial instinct ("type carries hierarchy; no boxes/cards") applied to the hub's own
  chrome, and it is the single cheapest fix in this document.

### 3.6 Empty state

`ContentUnavailableView` is macOS 14; the deployment target is 13 (§9.1), so this is hand-built.

```
              [ SF Symbol, 24 pt, ink.tertiary ]
                          space.m
        Chart has no options on this Beacon.      ← type.body, ink.primary
                          space.xs
    Its instrument is set from the ticker list.   ← type.secondary, optional
                          space.l
                   [ optional action ]
```

- Centered in its container, `space.xxl` padding, prose ≤ 280 pt wide.
- **The sentence names what is absent and, where possible, what would fill it.** `"No options"` at 60 %
  opacity in a corner is not an empty state; it is a shrug.
- Used by: an inspector with no options (but see §5 — the inspector prefers *context* to an empty state),
  an empty ticker list, an empty room list, an empty complication stack.

### 3.7 Catalog tile

The AVAILABLE grid entry — problem 5.

```
┌──────────────────────┐
│                   ✓  │  ← accent checkmark.circle.fill when enabled
│      Markets         │  ← type.bodyEmph — the ONLY 13 pt in the tile
│  Ticker list, live   │  ← type.caption, ink.secondary, 2 lines max
└──────────────────────┘
   110 × 92, fill.card, radius.card, stroke.hairline
```

- **Two text levels, not three.** Status becomes a mark in the top-trailing corner, not a competing line.
- Enabled: `fill.card` stays, title drops to `ink.secondary`, `accent` checkmark appears. **No blanket
  `.opacity(0.55)`** — dimming a whole tile dims its border and its status mark too, which is why the
  current tile is both the greenest and the faintest thing on screen.
- Selected: `fill.selected` + `accent` border at constant 1 px (§2.4).
- Fixed height (92) so the grid is a grid; the detail line truncates rather than reflowing the row.

### 3.8 Loading state

- **Inline** (a value that will land in a known place): `ProgressView().controlSize(.small)` +
  `type.secondary` label, left-aligned in the row that will hold the result. Never a bare spinner.
- **Block** (a whole pane): the same pair, centered.
- **Nothing renders for the first 150 ms.** A room fetch that resolves in 40 ms currently produces a
  visible spinner flash. Implement as a `Task.sleep` guard before setting the loading flag, cancelled on
  completion.
- The label says what is being fetched — "Loading rooms…", not "Loading…".

### 3.9 Error state

- Uses §3.3's `warn` / `error` vocabulary, inline in the surface that failed — never a modal.
- **The cause is the provider's own words.** `SonosSettingsView.describe(_ e: SonosAuthError)` is already
  exactly this and is the model: every case produces a specific sentence, and the loopback-bind case even
  names the port. Nothing in this system may render "An error occurred."
- Always paired with a retry affordance, or with a sentence saying why there is none.
- Error text is `ink.primary` at `type.secondary`. Red 10 pt text (`TickerEditorView.swift:216`) fails
  contrast and reads as decoration.

### 3.10 Destructive confirmation

`.alert` with `role: .destructive`. `SonosSettingsView.swift:58` is the pattern; generalise it:

- **Title is a question naming the object**: "Disconnect Sonos?", not "Are you sure?".
- **Message states exactly what is lost and what is kept.** "This clears the stored authorization. You can
  reconnect any time; the client secret stays saved." Both halves matter — the second half is what stops
  the user cancelling out of a safe action.
- Buttons: `Cancel` (`.cancel`) then the destructive verb, which repeats the title's verb.
- Applies to: Disconnect Sonos, Clear secret, Forget device, Remove the last ticker, Discard staged page
  edits (§4).

### 3.11 Footer action bar

```
├──────────────────────────────────────────── divider ────────┤
│ ● Pages changed · the Beacon restarts (~5 s).               │
│   Complications updated · applies immediately.  [Revert] [Save & push] │
└──────────────────────────────────────────────────────────────┘
   space.xl horizontal, space.m vertical
```

- Pinned below a `Divider()` at the bottom of the pane. Never scrolls.
- **Left: status lines, one per independent channel**, `type.secondary`, with a 6 pt `state.warn` dot when
  that channel is dirty. The existing two-channel footer is correct behaviour and stays; it only needs
  tokens.
- **Right: secondary action, then primary**, `space.s` apart. Primary is `.borderedProminent` with the
  system accent (not `Color.blue`); secondary is `.bordered`.
- Disabled uses the system's rendering only (§2.5).
- Primary is `control.heightProminent` (28); secondary matches it so they share a baseline.

---

## 4. The Settings window's navigation

### 4.1 The decision

**An `NSToolbar` in `.preference` style on the real `NSWindow`, with selectable items.** Four items —
Pages · Sources · Device · General — icon over label, centered, `NSWindow.toolbarStyle = .preference`
(macOS 11+). The four tab *bodies* stay pure SwiftUI; only the chrome becomes AppKit.
`SettingsWindowController` owns `selectedItemIdentifier` and writes through to the existing
`BeaconSettingsTab` UserDefaults key, so `MenubarController.openSettingsOnSources()` keeps working
unchanged.

### 4.2 Why, and what was rejected

**SwiftUI `TabView` (current) — rejected.** On macOS it renders the `NSTabView` palette bar: a centered
segmented control inside the content area. That control's job is switching an inspector's facets, not
switching a window's top-level destinations. Concretely it costs: no per-destination window title; no
participation in the toolbar (so no room for a future search field or overflow); no `⌘1`–`⌘4`; and a
badge API that does not render on macOS, which is why the shipped code concatenates `"\u{2022}"` into the
string `"Pages"` (`SettingsTabs.swift:83`). That workaround is not a bug to fix — it is the correct
response to an API that does not work, and the right conclusion is that the API was the wrong choice.

**`NSSplitViewController` sidebar — rejected, but it is the real competitor.** The brief's premise (that
System Settings uses a toolbar) is true of System *Preferences*; Ventura and later use a source-list
sidebar, and that is the modern idiom. It loses here on one hard number: the Pages tab is *already* a
three-pane layout inside the content area — a 150 pt-card carousel across the top, a 300 pt catalog grid,
and a 280 pt inspector (§5). A 200 pt sidebar makes that four columns and pushes the window's minimum
width past 1000 pt for a settings window with four destinations. A sidebar is the right answer at eight
or more destinations, or if any destination grows sub-pages. It is the wrong answer at four with a
three-pane child. This is recorded as an open question (§11.1) because it turns on a roadmap fact I do
not have.

**`SwiftUI.Settings` scene — rejected**, for the reason the previous design already recorded: it forces
the fixed-size, non-resizable preferences look.

### 4.3 The dirty indicator

Two mechanisms, deliberately:

1. **`window.isDocumentEdited = model.pagesDirty || model.compsDirty`.** This is macOS's own answer to
   "this window has unsaved changes": a dot in the close button. It is visible from every tab, it costs
   one line, and users already read it. It is strictly better than any badge we could draw.
2. **A 6 pt `state.warn` dot on a toolbar item — only when that item is *not* selected.** With `NSToolbar`
   you own the item's view, so this is a `NSView` subclass drawing a dot in its top-trailing corner, not a
   string concatenation. It is suppressed on the selected item because a badge on the pane you are
   staring at — which already has a footer bar naming exactly what changed and offering Revert — is noise.

**Consequence that must be signed off (§11.2).** `SettingsWindowController.windowWillClose` currently
*silently reverts* staged page and complication edits. Once `isDocumentEdited` is set, that is a visible
data-loss path: the platform has just told the user there is unsaved work, and closing throws it away
without asking. The call is to add a three-button sheet on close-with-dirty — **Save & push / Discard /
Cancel** — using §3.10's wording rules. That is a behaviour change, not a visual one, which is why it is
flagged rather than assumed.

### 4.4 Window chrome details

- `w.title` follows the selected destination: "Pages", "Sources", "Device", "General" — a real window
  title, which `TabView` cannot give.
- `⌘1`–`⌘4` select destinations; `⌘,` opens the window (already wired).
- The window opens with **no text field as first responder**. A settings window that opens with a cursor
  blinking in the Sonos Client ID field is wrong, and the Sources tab will do exactly that today once
  focus lands.
- `frameAutosaveName` and `contentMinSize` stay; the minimum grows (§11.7).

---

## 5. Density, and what an inspector does with empty space

The rule that answers problem 3.

### 5.1 The rule

> **An inspector is a fixed-width, top-aligned, shrink-wrapped column. It never stretches a control to
> fill height. When it runs out of options, it fills the remainder with *the thing it configures* — not
> with nothing, and not with an empty state.**

Concretely, replacing `PageDesignerView.swift:148`'s `maxWidth: .infinity, maxHeight: .infinity`:

- Inspector column: **fixed 280 pt**. It does not absorb slack; the catalog grid does.
- Content: `VStack(alignment: .leading, spacing: space.l)`, top-aligned, terminated by
  `Spacer(minLength: 0)`.
- No control has `maxHeight: .infinity`. Only a scrollable list may grow.

### 5.2 Three tiers by option count

| Options | Layout |
|---|---|
| **0** | Inspector header, hairline, then **"What this page shows"**: the page's own `DevicePreview` at 160 pt (framed per §6), and one `type.secondary` sentence describing what it renders. No "No options" string — the absence of options is evident, and the preview is the useful thing to look at. |
| **1–2** | Header, hairline, the options, hairline, then the same **"What this page shows"** block. This is the Sonos case: a room `Menu` *plus a picture of the page the room feeds*. The dropdown stops being one control in a lake because the lake is now the page. |
| **3+** | Header, hairline, options fill the column. The preview block drops out — the carousel card above is already showing it, and repeating it wastes the column. |

The block is a genuine improvement, not filler: while choosing a Sonos room you are looking at the Sonos
page; while the chart's instrument is unset you are looking at the chart. It also does §6's job for free —
it puts the device's visual language in front of the user at the moment they are configuring the device.

### 5.3 Corollaries

- **Nothing in a pane is centered vertically except an empty state.** Top-aligned by default.
- **Whitespace below content is correct and needs no treatment.** The failure today is not that space
  exists; it is that a lone 11 pt control was scaled into it by `maxWidth: .infinity` and then abandoned.
- **A pane with less content than height does not grow its content.** It grows the gap after it.
- **The catalog grid absorbs horizontal slack**, because a grid of fixed tiles genuinely improves with
  more columns. That is the one pane in the window that should take `.infinity`.

---

## 6. Two visual languages, one window

`DevicePreview.swift` renders miniature device screens inside hub chrome. The device has its own design
system (`DESIGN.md`) — black canvas, `#f4f3ef` ink, `#74726c` dim, `#ff4a2b` accent, Space Grotesk /
JetBrains Mono, hairline rules, no cards, a ≥ 40 px safe inset on a 466 px panel. **A preview that adopts
hub styling is lying about what the device shows**, and the lie is load-bearing: this preview is how the
user decides what to put on their Beacon.

### 6.1 The boundary is the panel edge, and it is a file boundary

`BeaconPalette` (`DevicePreview.swift:16`) is already correct and already carries the right hexes. Make it
structural:

- Move it and the sketch primitives into **`DeviceGlass.swift`**, which owns the device's colour and type
  roles as the hub sees them.
- **Nothing outside that file may read a device token.** No `BeaconPalette.accent` in a hub view.
- **Nothing inside that file may read a hub token.** No `.secondary`, no `Color.accentColor`, no
  `radius.card`, no `space.*`. Device geometry is proportional to `size`, as it already is.
- `.font(.system(size:))` is legal there and only there (§2.2) — the device's faces are not text styles
  and must not respond to the Mac's text-size setting. The panel is 466 px whatever the user's Mac is
  set to.

Type inside the glass currently uses eyeballed multipliers (`size * 0.042`, `* 0.135`, `* 0.05`, `* 0.038`,
`* 0.036`, `* 0.032`, `* 0.044`…). Derive them from `DESIGN.md`'s actual device scale instead —
`eyebrow` mono-15, `body` 18, `display` 30, `hero` 84, all ÷ 466 — so the preview's proportions are the
device's proportions rather than a designer's guess. That is four constants, and it makes the preview
verifiable against the firmware's `env:capture` output.

### 6.2 The frame is real chrome

The panel gets a bezel, and the hub's card gets out of the way.

```
        ┌────────────────────────────┐   ← accent selection ring, OUTSIDE, 3 pt gap
        │  ╔══════════════════════╗  │   ← glass.bezel, 3 pt, radius.card + 3
        │  ║ ▓▓▓▓ device glass ▓▓ ║  │   ← BeaconPalette.bg, corner = size × 0.22
        │  ╚══════════════════════╝  │
        └────────────────────────────┘
             Markets          [×]        ← hub chrome: type.bodyEmph, BELOW the glass
             ‹  ›                         ← reorder controls, BELOW the glass
```

- **The preview *is* the card.** Today it is a black square sitting on a `controlBackgroundColor` card
  with a 1 px stroke — in light appearance a black rectangle on near-white with no transition, which
  reads as a hole punched in the window. Replace the surrounding card entirely: panel, `glass.bezel`
  ring, `shadow.card`. A bezel says "this is a screen".
- `glass.bezel`: `#101010` in light appearance, **`#2E2E2E` in dark**. Note the inversion — the bezel goes
  *lighter* than the glass in dark appearance, because a black-on-near-black panel with a darker frame
  disappears. This is one of the few places the hub deliberately does not use a system colour: the frame's
  job is separating the glass from the window, which is an appearance-dependent problem.
- **Selection ring sits outside the bezel** at `radius.card + 3`, never touching the glass. Hub state is
  drawn around device content, never on it.
- Title, reorder chevrons and remove button sit **below** the glass on the window background. Today the
  remove `x` is a `ZStack(alignment: .topTrailing)` white-on-`Color.black.opacity(0.55)` circle drawn
  **on top of the panel** (`PageDesignerView.swift:316`) — hub chrome painted onto device glass, which is
  precisely the lie this section exists to prevent.

### 6.3 What may not cross the boundary

| Never inside the panel rect | Why |
|---|---|
| SF Symbols | The device has a lucide glyph subset, not SF Symbols. `UnknownSketch` (`:325`) draws `questionmark.square.dashed` inside the glass today. |
| The system accent | The device's accent is `#ff4a2b`. A blue highlight inside the panel is not a thing the device can do. |
| `.primary` / `.secondary` / `.tertiary` | They resolve to hub ink and follow the Mac's appearance. Device ink does not. |
| Hub radii, hub spacing | The panel's corner is `size × 0.22` because the panel's corner is ~90/466. It is not `radius.card`. |
| Hub disclaimers | See below. |

**The honesty-string rule.** There are two kinds of text in a sketch and they belong on opposite sides of
the bezel:

- **Placeholder dashes (`—.——`) stay inside the glass.** The device genuinely renders those when it has no
  data — `DESIGN.md`'s screen-state table requires exactly this. They are device language.
- **Disclaimers move out.** "sample shape · live on device" (`:207`), "live on device" (`:233`), "sample ·
  live once connected" (`:293`) are the *hub* talking about the device, rendered in device ink inside the
  panel — which makes a hub caveat look like device content, the exact inversion of the problem. They
  become one `type.caption` line under the carousel band: *"Previews are approximations — the Beacon
  renders these itself."* Once, not per card.

### 6.4 Fidelity: bundle the device's fonts

**Call: yes.** Ship Space Grotesk and JetBrains Mono in the app bundle and register them with
`CTFontManagerRegisterFontsForURL` at launch, so `DeviceGlass` draws in the device's actual faces instead
of SF Pro at device proportions.

- Both are SIL Open Font License — redistributable, and already in the firmware's font pipeline.
- Cost is roughly 300–400 KB of bundle for a subset, and one call in `main.swift`.
- **This is not a dependency.** The no-third-party-deps rule (`CLAUDE.md`) is about libraries linked into
  the build; a font file is a bundle resource with no code, no build-system involvement and no API
  surface. Noted explicitly so nobody reads this as relitigating the rule.
- It is the single change with the largest effect on whether the preview is honest, because typeface is
  the most recognisable thing about the device's Editorial look, and it is also why the preview currently
  reads as "a Mac app's idea of the device" rather than the device.

Phased to migration step 3 (§10), because it is the one item here that touches `build-app.sh`.

---

## 7. Dark mode

First-class, not a pass at the end. The rules are in §2.3; this section is the enforcement.

**Banned outright in hub chrome:**

- `Color.white`, `Color.black` — three sites today (`DeckUI.swift:49`, `PageDesignerView.swift:181`,
  `:321`), all light-appearance decisions. White-on-accent is wrong for any user whose accent is yellow
  or graphite; use `Color.white` only via `.foregroundStyle(.white)` on `.borderedProminent`, which
  AppKit resolves per accent.
- A single opacity applied to both appearances. Every `fill.*` is a dynamic pair.
- `Color.blue` — it does not track the accent, and its contrast against `surface.content` differs by
  appearance.

**Required:**

- Every fill via the `NSColor(name:dynamicProvider:)` helper (§2.3), so it resolves correctly on a window,
  inside an `NSPopover`'s vibrancy material, and across a live appearance switch.
- Every state-bearing SF Symbol uses `.symbolRenderingMode(.hierarchical)` or an explicit palette. A
  `.fill` glyph in a saturated system colour becomes a solid blob against a dark card at 11 pt.
- **Every component's `#Preview` ships twice**, `.preferredColorScheme(.light)` and `.dark`. Six previews
  exist today; none sets a scheme, which is a precise statement of how dark mode got missed.
- The `NSPopover` panel is verified separately from the window: `fill.card` over vibrancy composites
  differently than over `surface.window`, and `HubPanel` is the most-used surface in the product.

**Explicit exception:** the device glass (§6) is black in both appearances, because the device has no
light mode. The bezel token inverts (§6.2) so the panel does not vanish into a dark window. That is the
only single-appearance surface in the hub, and it is single-appearance by contract, not by neglect.

---

## 8. Accessibility

### 8.1 Contrast

| Content | Minimum | Notes |
|---|---|---|
| `type.body` and smaller | **4.5:1** against its own background | Includes text over `fill.card`, `fill.selected`, and the popover material. |
| `type.pane`, `type.figure` (≥ 17 pt, or ≥ 14 pt bold) | **3:1** | |
| Icons that carry meaning | **3:1** | And never *only* the icon — §2.3. |
| `ink.tertiary` | exempt — **decorative only** | ≈ 2.8:1. May not carry content (§2.3). |

Three current failures, all content on tertiary or coloured ink: `DeviceTab.swift:90` ("Not reported by
this firmware build"), `PageDesignerView.swift:441` ("No options" at ≈ 30 %), and every `Text("Ready")` in
`state.ok` green at 10–11 pt. The last is fixed structurally: colour moves to the glyph, the word goes
`ink.primary`.

### 8.2 VoiceOver

- **Every row is one element**: `.accessibilityElement(children: .combine)`, label = the row's title,
  value = its state or its control's state, hint only where the action is not obvious from the label.
  `HubPanel.ProviderCard` (`:147`) is the only view that does this today; it is the template.
- **Every icon-only button has an `.accessibilityLabel`.** Today the reorder chevrons
  (`PageDesignerView.swift:361`), the remove `x` (`:319`, `ComplicationEditorView.swift:204`) and the trash
  button (`TickerEditorView.swift:240`) have none. `.help()` is a tooltip, **not** a VoiceOver label —
  which means the codebase has two tooltips and zero labels on eleven icon buttons.
- **Drag-and-drop must have a labelled non-pointer equivalent.** The chevron path exists by design
  (`PageDesignerView.swift:286`) and is the right decision — but unlabelled, it is present and unusable.
  Label them "Move Markets earlier" / "Move Markets later", not "Previous" / "Next".
- Status rows announce state as a **value**, not by reading a glyph name: label "Bluetooth", value
  "Connected".
- The dirty toolbar dot is decorative; the accessible signal is the window's document-edited state, which
  AppKit already announces.

### 8.3 Larger text

The whole point of §2.2's text-style mapping. Raw `.system(size:)` does not respond to the system text
size; `.body` does. With 154 raw call sites, the hub currently does not scale at all.

That only pays off if layout permits growth:

- **No fixed `.frame(height:)` on anything containing text.** Today: `arrow(...)` `20 × 18`
  (`PageDesignerView.swift:363`), `IconButton` `22 × 22` (`TickerEditorView.swift:254`), `StatusRow`'s
  icon `frame(width: 18)` — the last is fine (width only), the first two clip.
- Rows use `minHeight`, never `height` (§3.2).
- Fixed container heights become `idealHeight` + `minHeight`: the carousel's `frame(height: 230)`
  (`:82`), the ticker editor's `frame(width: 420, height: 520)` (`:29`), the instrument popover's
  `frame(width: 300, height: 320)` (`:630`), the room popover's `maxHeight: 240` (`:891`).
- Icon columns get a fixed **width**; heights come from content.
- The `NSPopover` panel keeps one fixed width (340) because `sizingOptions = [.preferredContentSize]`
  drives its size from SwiftUI intrinsics — but its height must remain free (§9.3).

### 8.4 Motion and keyboard

- `@Environment(\.accessibilityReduceMotion)` gates the carousel's reorder animation
  (`PageDesignerView.swift:295`) and its `scrollTo` (`:79`), degrading to instant.
- Every action reachable without a pointer. `⌘1`–`⌘4` for destinations (§4.4); Return commits a text
  field; Escape dismisses a popover.
- Focus ring is the system's. Never suppressed.

---

## 9. Platform constraints

These bound what is buildable. Ignoring them produces either a compile failure or a build that takes
minutes and then fails.

### 9.1 Deployment target is macOS 13

`Package.swift`: `platforms: [.macOS(.v13)]`. Things that do **not** exist:

| API | Available | Consequence |
|---|---|---|
| `onChange(of:) { old, new in }` | 14 | Single-parameter overload only. Already documented at `PageDesignerView.swift:76`; the token layer must not reintroduce the two-param form. |
| `ContentUnavailableView` | 14 | §3.6's empty state is hand-built. This is why it is specified in detail. |
| `HierarchicalShapeStyle.quinary` | 14 | Only `.tertiary` / `.quaternary` are available, which is one reason the fill tokens are explicit opacity pairs rather than hierarchical styles. |
| `.scrollBounceBehavior`, `.contentMargins` | 14 | Scroll insets are padding. |
| `Observable` macro | 14 | `HubViewModel` stays `ObservableObject`. Unchanged by this document. |

`NSWindow.toolbarStyle = .preference` (§4.1) **is** available — macOS 11+.

### 9.2 The type checker

Large SwiftUI bodies hit *"unable to type-check this expression in reasonable time."* `SonosSettingsView`
exists as a separate file for exactly this reason (its header says so). Rules that keep the token layer
from making it worse:

- **Tokens are stored constants or typed `static let`s**, never computed expressions inlined into a
  modifier argument. `static let card = Color(nsColor: …)` — not a `var` returning a ternary.
- **Every subview is a `private var … : some View` or a `private struct`.** The `borderColor` computed-var
  pattern in `CarouselCard` (`:355`) is the shape; copy it.
- **No more than ~6 siblings in one `ViewBuilder`.** Beyond that, split.
- **No ternaries inside modifier arguments.** Lift them to a named computed property with an explicit type.
- Custom `ViewModifier`s over long modifier chains: `.cardStyle()` is one type-check, not seven.
- A view file crossing ~250 lines is a signal to split — `PageDesignerView.swift` is 920 lines and holds
  nine view types, four of which belong in the shared component layer.

### 9.3 Window and activation

- `SettingsWindowController` takes `.regular` while the window is open and `.accessory` on close
  (`:28`, `:63`). Three visual consequences:
  1. The window gets a real menu bar and title bar — so §4's toolbar is available and free.
  2. **A Dock icon appears and disappears every time Settings opens.** The app icon is now a visible
     surface, on a schedule, and it must look finished (§11.5).
  3. `NSApp.activate` + `makeKeyAndOrderFront` means the window is key on open, so first responder and
     focus ring matter (§4.4).
- The `NSPopover` uses `sizingOptions = [.preferredContentSize]` (`MenubarController.swift:127`) with a
  note that a stale size clips the header. **Rule: popover content declares exactly one fixed width (340)
  at the root, and no descendant declares `.infinity` width or any fixed height.** Height must stay
  intrinsic or the panel mispositions.
- The Settings window is reused across opens (`isReleasedWhenClosed = false`), so `onAppear` fires once
  per app lifetime. Every surface that reads external truth already compensates via
  `NSWindow.didBecomeKeyNotification` (`SonosSettingsView.swift:57`, `PageDesignerView.swift:435`). Any
  new component that reads Keychain/UserDefaults must do the same; a component that assumes `onAppear`
  runs on each open will show stale state forever.

### 9.4 No third-party UI

Restated because it constrains the shape of the answer, not just the dependency list: there is no
component library, no icon set beyond SF Symbols, no colour library. The token layer is hand-written and
must therefore be small enough to hold in your head — which is why §2 is 6 spacing steps, 9 type roles,
15 colours and 2 radii, and not 40 of each.

---

## 10. Migration

Four phases. **Phase 1 is shippable alone and visibly fixes both named complaints.**

### Phase 1 — the tokens, the shared components, and the Pages tab

Files: **new** `HubStyle.swift`; **rewritten** `DeckUI.swift`; **edited** `SettingsTabs.swift`,
`SettingsWindowController.swift`, `PageDesignerView.swift`.

1. `HubStyle.swift` — §2 in full. ~150 lines. No view changes yet; it compiles alone.
2. Rebuild `DeckUI.swift` on it: `Module` → `Card` (§3.5), `DeckButton` → token-driven with both manual
   opacity dimmings removed (§2.5), `ToggleRow` → `SettingsRow` (§3.2). Add `StatusRow` (§3.3),
   `ListRow` (§3.4), `EmptyState` (§3.6), `SectionHeader` (§3.1). These are used by every surface, so one
   edit propagates to all four tabs and the popover without touching them.
3. **The window chrome** — `NSToolbar` `.preference` + `isDocumentEdited` + the unselected-item dot
   (§4). Deletes the pill bar and the `"•"` hack. Highest visible improvement per line changed in the
   whole document.
4. **The Pages tab** — the carousel band de-greyed to hairlines-and-nothing (§3.5); the carousel card
   reframed as device glass with the remove button moved off the panel (§6.2); the AVAILABLE tile
   hierarchy fixed (§3.7); the inspector fixed at 280 pt with the density rule and the "What this page
   shows" block (§5), which is what stops the Sonos inspector floating.
5. Dark-mode pass over exactly these surfaces, with both-scheme previews (§7).

**Why this set.** It is precisely the two complaints the owner named — the tab bar and the Sonos
inspector — plus the two they did not name but will see immediately (the grey band, the tile hierarchy).
It touches no file in `BeaconHubKit`, so **none of the 416 tests move**, and it touches no BLE, Keychain,
hooks or provider code.

### Phase 2 — the remaining surfaces

`SourcesTab`, `DeviceTab`, `GeneralTab`, `SonosSettingsView`, `TickerEditorView`, `ComplicationEditorView`,
`HubPanel`. Mechanical once Phase 1's components exist: delete the ten local row types, adopt the three
shared ones; collapse the five status vocabularies into §3.3's one; replace the hand-built Sonos room
button with a `Menu` (§3.4). This is where `SourcesTab.ProviderRow` and
`PageDesignerView.AgentProviderRow` become the same component — the divergence in §1.2 disappears by
construction rather than by discipline.

### Phase 3 — device-glass fidelity

`DeviceGlass.swift` extracted (§6.1); sketch proportions re-derived from `DESIGN.md`'s type scale; the
honesty strings moved out of the glass (§6.3); Space Grotesk + JetBrains Mono bundled and registered
(§6.4). Touches `build-app.sh`, which is why it is not in Phase 1.

### Phase 4 — accessibility sweep

Labels on all eleven icon-only buttons; the fixed-height audit (§8.3); reduce-motion gating; a contrast
verification pass over both appearances; VoiceOver walkthrough of each destination.

**Not scheduled:** any change to `HubViewModel`'s shape, any change to the four-tab IA (it just shipped
and it is right), any change to the staging model or the two-channel footer semantics.

---

## 11. Open questions

1. **Toolbar or sidebar for the Settings window.** §4.2 calls toolbar, on the argument that a sidebar
   costs ~200 pt of width the three-pane Pages tab cannot spare at four destinations. That flips if a
   fifth destination is coming, or if any destination grows sub-pages. **Do you expect the Settings window
   to grow past four top-level destinations?**

2. **Close-with-unsaved-edits.** `window.isDocumentEdited` (§4.3) makes the current silent revert-on-close
   visible as data loss, so the call is to add a Save & push / Discard / Cancel sheet. **This is a
   behaviour change, not a visual one — confirm before it is built.** The alternative is to skip
   `isDocumentEdited` and rely on the toolbar dot alone, which is weaker but changes nothing.

3. **Bundling the device's fonts.** §6.4 calls yes: ~300–400 KB of OFL-licensed Space Grotesk + JetBrains
   Mono so the device preview draws in the device's real faces. It is the single biggest fidelity win
   available and it is not a third-party dependency in the sense the project rule means. **Is the bundle
   size / build-script change acceptable?**

4. **Does the hub adopt any of the device's colour identity?** §2.3 chose the user's system accent
   everywhere, because a Mac app that ignores the accent colour reads as a web app. The cost is that the
   hub and the device share no colour — the `#ff4a2b` signal orange appears only inside the device
   preview. **Is that right, or should the hub use signal orange somewhere deliberate (the menubar
   glyph's alert tint, the dirty dot, the primary action) so the two halves look like one product?**

5. **The app icon.** The `.regular` activation policy puts a Dock icon on screen every time Settings is
   opened and removes it on close (§9.3). That makes the icon a recurring visible surface. **Is there a
   designed Beacon Hub icon, or does one need to be made?**

6. **The menu-bar popover.** `HubPanel` is a Control-Center-style stack of cards. After the tab bar it is
   the least Mac-native surface in the hub — but it is also by far the most-used one, and restyling it is
   the most disruptive thing in this document. Phase 2 currently only re-tokenises it, preserving its
   shape. **Should it stay a card stack, or become a plain grouped list?**

7. **Window minimum width.** §5's density rule fixes the inspector at 280 pt and the catalog grid at
   300 pt; with a 150 pt carousel card and `space.xl` gutters, the Pages tab wants roughly **820 pt**
   minimum width, up from today's 720. **Acceptable?** If not, the inspector narrows to 240 and the
   "What this page shows" preview drops from 160 pt to 120 pt.
