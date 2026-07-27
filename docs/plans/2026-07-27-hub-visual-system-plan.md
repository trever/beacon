# Plan: the hub's visual system

**Status:** open. Written 2026-07-27. Every workstream below assumes **no prior session context** and is
written to be lifted into a subagent brief almost verbatim.

**Design (source of truth — read it completely before touching anything):**
`docs/specs/2026-07-27-hub-visual-system-design.md`. It is decision-complete.

**Settled by the owner. Do not relitigate, do not "improve":**

- Navigation is a **source-list sidebar** (`NavigationSplitView`), not a toolbar and not a `TabView` —
  a fifth destination (Firmware) is already committed in the OTA plan.
- Closing with unsaved edits presents a **Save & push / Discard / Cancel** sheet.
- **System accent only.** `#ff4a2b` stays inside the device glass and never appears in hub chrome.
- `HubPanel` keeps its card-stack shape; it is **re-tokenised, not redesigned**.
- The device's fonts **get bundled**.
- Minimum window **820 × 560**.
- **Firmware is a flat fifth sidebar row**, not a child of Device.
- **No inspector collapse toggle** in Phase 1.
- The sidebar dirty dot **shows regardless of selection**.

**Not in scope, and owned by another track — do not open these files:**
`docs/specs/2026-07-27-ota-updates-design.md`, `docs/plans/2026-07-27-ota-updates-plan.md`,
`DESIGN.md` (the device's system), and anything under `firmware/`.

---

## 0. The failure this plan exists to prevent

`hub/Sources/beacon-hub/PageDesignerView.swift:740` carries this comment:

> *A visually distinct, file-local rendering of the same store/intents: `SettingsPanel.swift`'s
> `ProviderRow` is `private` to that file, and it is off-limits to edit for this workstream.*

That one sentence produced `SourcesTab.ProviderRow` and `PageDesignerView.AgentProviderRow`: the same
`model.providers`, the same three intent closures, rendered at 13 pt and 11 pt one destination apart in
the same window. It is also the root of the other counts in the audit — **ten** row implementations
across six files, **five** status-glyph vocabularies, **154** `.font(.system(size:))` sites across 11
distinct point sizes. None of it was a taste failure. There was no shared vocabulary to draw from, and
`private` made inventing one locally the path of least resistance.

**Therefore:**

> **Wave 0 is sequential, single-owner, and every type it lands is `internal` or better. A `private`
> or `fileprivate` declaration anywhere in the component layer recreates the exact disease this whole
> effort exists to cure, and is a hard failure of that workstream's acceptance gate.**

The gate is not a code review. Wave 0 ships `HubComponentTests.swift`, which constructs **every**
shared component and reads **every** token from the test target. A `private` type does not compile
there. The rule is enforced by the compiler, not by discipline.

And the escalation rule that closes the loop, pasted into every brief below:

> **If you believe you need a component the shared layer does not provide, you do not build a local
> one. You stop and report it.** The orchestrator either amends the component layer (sequentially,
> single owner) or authorises a file-local view — which must then carry a
> `// LOCAL BY DECISION (<date>):` comment naming the decision. An undocumented file-local row, card,
> tile, chip or badge is a failed gate, not a style nit.

---

## 1. Wave order and file ownership

| Wave | ID | Workstream | Parallel? | Design phase |
|---|---|---|---|---|
| 0 | **WS-0** | Tokens + shared components + the glass frame | **No** — single owner, sequential | Phase 1 steps 1–2 |
| 1 | **WS-1** | Window chrome: sidebar, titles, dirty state, close sheet | yes | Phase 1 step 3 |
| 1 | **WS-2** | Pages destination: merge, band, tiles, inspector, Sonos `Menu` | yes | Phase 1 step 4 |
| 1 | **WS-3** | Home's complication inspector, re-laid-out for a 260 pt column | yes | Phase 1 step 4 (see §1.2) |
| 2 | **WS-4** | The other three destinations + Sonos settings | yes | Phase 2 |
| 2 | **WS-5** | Ticker editor | yes | Phase 2 |
| 2 | **WS-6** | Menu-bar popover | yes | Phase 2 |
| 3 | **WS-7** | Device-glass extraction, proportions, fonts | yes | Phase 3 |
| 3 | **WS-8** | Dark-appearance + contrast verification pass | yes | Phase 1 step 5 / Phase 4 |
| 4 | **WS-9** | Convergence: delete the compat layer, docs, final QA | **No** — sequential | — |

Wave *n* starts only when every workstream in wave *n−1* is merged into the integration branch.

### 1.1 Files, by exclusive owner

No two workstreams in the same wave may open the same file. This table is the collision guard; each
brief repeats its own row plus an explicit "files NOT to touch" list.

| Path | Owner |
|---|---|
| `hub/Sources/beacon-hub/HubStyle.swift` *(new)* | **WS-0** creates; nobody edits after |
| `hub/Sources/beacon-hub/HubRows.swift` *(new)* | **WS-0** creates; nobody edits after |
| `hub/Sources/beacon-hub/HubSurfaces.swift` *(new)* | **WS-0** creates; nobody edits after |
| `hub/Sources/beacon-hub/DeviceGlass.swift` *(new)* | **WS-0** creates the frame, **WS-7** fills it |
| `hub/Sources/beacon-hub/DeckUI.swift` | **WS-0** rewrites as the compat layer, **WS-9** deletes |
| `hub/Sources/beacon-hub/SettingsPanel.swift` | **WS-0** deletes (see §10.4) |
| `hub/Tests/beacon-hubTests/HubStyleTests.swift` *(new)* | **WS-0** |
| `hub/Tests/beacon-hubTests/HubComponentTests.swift` *(new)* | **WS-0** |
| `hub/Sources/beacon-hub/SettingsTabs.swift` | **WS-1** |
| `hub/Sources/beacon-hub/SettingsWindowController.swift` | **WS-1** |
| `hub/Sources/beacon-hub/SettingsCloseDecision.swift` *(new)* | **WS-1** |
| `hub/Tests/beacon-hubTests/SettingsTabTests.swift` | **WS-1** |
| `hub/Tests/beacon-hubTests/SettingsCloseTests.swift` *(new)* | **WS-1** |
| `hub/Sources/beacon-hub/PageDesignerView.swift` | **WS-2** |
| `hub/Sources/beacon-hub/InspectorTier.swift` *(new)* | **WS-2** |
| `hub/Tests/beacon-hubTests/InspectorTierTests.swift` *(new)* | **WS-2** |
| `hub/Sources/beacon-hub/ComplicationEditorView.swift` | **WS-3** |
| `hub/Sources/beacon-hub/SourcesTab.swift`, `DeviceTab.swift`, `GeneralTab.swift`, `SonosSettingsView.swift` | **WS-4** |
| `hub/Sources/beacon-hub/TickerEditorView.swift` | **WS-5** |
| `hub/Sources/beacon-hub/HubPanel.swift` | **WS-6** |
| `hub/Sources/beacon-hub/DevicePreview.swift` | **WS-7** |
| `hub/Resources/fonts/`, `hub/build-app.sh`, `hub/Sources/beacon-hub/main.swift` | **WS-7** |
| every view file (labels + reduce-motion only) | **WS-8**, and only after wave 2 is merged |
| `docs/codemap.md`, `docs/recipes.md` | **WS-9** |

**Nothing in this plan touches `firmware/`, `hub/Sources/BeaconHubKit/`, `AppDelegate.swift`,
`MenubarController.swift`, `HubViewModel.swift`, or any provider/BLE/Keychain/hooks file.** That is a
hard boundary, and it is what makes the whole effort low-risk: `BeaconHubKit` contains no view type,
so all **308** of its tests are untouched by construction.

### 1.2 Why WS-3 exists as its own workstream

`ComplicationEditorView` is rendered *inside* the Pages inspector (`PageDesignerView.swift:154`). The
design bounds that inspector at 260–320 pt (§5.1); today it gets whatever is left over after a 300 pt
grid — roughly 400 pt. So Phase 1's inspector bounding **squeezes a file the design scheduled for
Phase 2**: the complication palette is a `LazyVGrid(.adaptive(minimum: 92))` and its header puts a
two-line title beside a capsule chip on one row. At 228 pt of usable width that header wraps badly and
the grid drops to two columns.

Folding it into WS-2 would make the largest workstream larger. Leaving it in Phase 2 ships a visibly
broken Home inspector for a whole wave. So it becomes its own small, file-exclusive workstream in the
same wave, under one written contract: **lay out for 228 pt of content.**

---

## 2. Shared invariants — paste into every brief

### 2.1 Step 0 is mandatory. Do this before reading any other instruction.

Worktrees are created from the commit HEAD was at when the dispatching session started, **not from
current HEAD**. On this repo that gap is not cosmetic: `main` at `54366a7` does not contain
`SettingsTabs.swift`, `SourcesTab.swift`, `DeviceTab.swift`, `GeneralTab.swift`,
`ComplicationEditorView.swift`, or any Sonos file. A worktree cut from it is missing the entire
four-destination IA this design is written against, and you would be redesigning a UI that no longer
exists.

```bash
# 0.1 — where am I?
cd <worktree>
git log --oneline -1
git status --short          # must be clean before you start

# 0.2 — is the integration branch present? (the orchestrator states the exact ref at dispatch;
#        as of writing it is feat/sonos-page-and-yahoo-symbol-search @ ae75772)
git merge <integration-ref>          # or: git rebase <integration-ref>

# 0.3 — marker files. EVERY line must print the path, not "No such file".
ls hub/Sources/beacon-hub/SettingsTabs.swift \
   hub/Sources/beacon-hub/SourcesTab.swift \
   hub/Sources/beacon-hub/DeviceTab.swift \
   hub/Sources/beacon-hub/GeneralTab.swift \
   hub/Sources/beacon-hub/ComplicationEditorView.swift \
   hub/Sources/beacon-hub/SonosSettingsView.swift \
   docs/specs/2026-07-27-hub-visual-system-design.md
# Waves 1+ additionally:
ls hub/Sources/beacon-hub/HubStyle.swift \
   hub/Sources/beacon-hub/HubRows.swift \
   hub/Sources/beacon-hub/HubSurfaces.swift

# 0.4 — YOUR OWN baseline, measured before you change one character.
cd hub
swift build 2>&1 | grep -c "is deprecated"          # record this number
swift test  2>&1 | grep -E "^Executed [0-9]+ tests" | tail -1
grep -c "\.system(size:" Sources/beacon-hub/<each file you own>
```

**If a marker file is missing, or `git merge` conflicts, stop and report. Do not proceed.**

### 2.2 Acceptance gate — every workstream, before claiming done

```bash
cd <worktree>/hub
swift build                                          # 0 errors
swift test 2>&1 | grep -E "^Executed [0-9]+ tests"   # >= your stated floor, 0 failures
```

- **Floors: hub 416 tests total, 308 of them in `BeaconHubKitTests`.** Never go below either. A
  workstream that adds tests but leaves the total unchanged has deleted coverage and must explain it.
- `git diff --name-only <base> | grep '^firmware/'` must return **nothing**.
- `git diff --name-only <base> | grep 'BeaconHubKit'` must return **nothing**.
- Firmware is untouched by this plan; its baseline (**295 tests**, `pio run -e beacon` SUCCESS) is
  recorded here only so a workstream that somehow breaks it notices.
- Your deprecation-warning count must be **strictly lower** than your step-0.4 baseline (§7.2).
- Every file you own must end at **0** matches for `\.system(size:` — the sole exceptions are
  `DevicePreview.swift` and `DeviceGlass.swift`, where the count must stay **> 0** by contract (§6.1
  of the design: the device's faces are not text styles and must not scale with the Mac's text size).

### 2.3 Rules of the road

- **Read `HubStyle.swift`, `HubRows.swift` and `HubSurfaces.swift` in full before writing a line.**
  They are ~450 lines total. The §3.1 "do not redefine" table is not a summary of them; it is a
  promise about what already exists.
- **Deployment target is macOS 13.** No `onChange(of:) { old, new in }`, no
  `ContentUnavailableView`, no `.inspector(_:)`, no `Observable` macro, no `.quinary`, no
  `.scrollBounceBehavior`, no `.contentMargins`. `NavigationSplitView`, `List(selection:)` with
  `.listStyle(.sidebar)` and `HSplitView` are all available and are what §4 is built on.
- **The type checker is a real constraint.** Tokens are stored constants or typed `static let`s, never
  computed expressions inlined into a modifier argument. Every subview is a
  `private var …: some View` or a `private struct`. No ternaries inside modifier arguments — lift them
  to a named computed property with an explicit type. No more than ~6 siblings in one `ViewBuilder`.
  `SonosSettingsView.swift` exists as a separate file solely because of this; do not make it worse.
  (`private` is correct and expected for a view's *own* internal subviews. The `internal` mandate in
  §0 is about the **shared component layer**, not about every helper you write.)
- **Never `Color.white`, `Color.black`, or `Color.blue` in hub chrome.** `.foregroundStyle(.white)` on
  a `.borderedProminent` button is the one legal white, because AppKit resolves it per accent.
- **The Settings window is reused across opens** (`isReleasedWhenClosed = false`), so `onAppear` fires
  once per app lifetime. Anything reading Keychain/UserDefaults must also observe
  `NSWindow.didBecomeKeyNotification`, as `SonosSettingsView.swift:57` and
  `PageDesignerView.swift:435` already do.
- **ASCII only** in source and comments. **No secrets, ever** — this repo is public.
- Conventional Commits, scope `hub` (or `docs`); branch `<type>/<kebab-summary>`. No linked issue
  required in this fork.
- Docs state current reality; edit the statement, never append a changelog.

---

## 3. WS-0 — the substrate

**Sequential. Single owner. Nothing else starts until this is merged.** This is Phase 0 in the sense
the effort actually needs: not "the first slice of UI work" but *the vocabulary every later workstream
consumes*.

### Goal

Land the token layer, the shared component layer, and the device-glass frame, all `internal`, with
every existing call site still compiling and every legacy entry point still working — so that no
downstream workstream ever has a reason to invent a component locally, and no wave ever produces a
tree that does not build.

### Files to touch

**New:**

- `hub/Sources/beacon-hub/HubStyle.swift` — design §2 in full. ~200 lines.
- `hub/Sources/beacon-hub/HubRows.swift` — design §3.1–3.4.
- `hub/Sources/beacon-hub/HubSurfaces.swift` — design §3.5–3.11.
- `hub/Sources/beacon-hub/DeviceGlass.swift` — **frame only** (see "what NOT to build" below).
- `hub/Tests/beacon-hubTests/HubStyleTests.swift`
- `hub/Tests/beacon-hubTests/HubComponentTests.swift`

**Rewritten:** `hub/Sources/beacon-hub/DeckUI.swift` → the deprecation compat layer.

**Deleted:** `hub/Sources/beacon-hub/SettingsPanel.swift` — its two surviving types (`SectionHeader`,
`StatusRow`) move into `HubRows.swift`. **Check §10.4 before deleting.**

### Files NOT to touch

`SettingsTabs.swift`, `SettingsWindowController.swift`, `PageDesignerView.swift`,
`ComplicationEditorView.swift`, `SourcesTab.swift`, `DeviceTab.swift`, `GeneralTab.swift`,
`SonosSettingsView.swift`, `TickerEditorView.swift`, `HubPanel.swift`, `DevicePreview.swift`,
`AppDelegate.swift`, `MenubarController.swift`, `HubViewModel.swift`, `main.swift`, anything under
`Sources/BeaconHubKit/`, anything under `firmware/`.

**You do not convert a single call site.** Your diff outside the six files above and `DeckUI.swift` is
zero. That is the point: the layer must exist and be provably consumable before anyone consumes it.

### What already exists vs what to build

| Exists today | Where | What happens to it |
|---|---|---|
| `Module` | `DeckUI.swift:8` | Becomes a deprecated wrapper over `Card`. Signature preserved. |
| `DeckButton` / `DeckButtonKind` | `DeckUI.swift:20` | Becomes a deprecated wrapper over `HubButton`. Both manual opacity dimmings deleted (§2.5). |
| `ToggleRow` | `DeckUI.swift:63` | Becomes a deprecated wrapper over `SettingsRow`. |
| `SectionHeader` | `SettingsPanel.swift:9` | **Moves** to `HubRows.swift`, re-tokenised (`spacing: 1` → `space.xs`). Keep the `(title:subtitle:)` non-optional-String initializer so `DeviceTab`/`GeneralTab`/`SourcesTab`/`SonosSettingsView` compile unchanged; add a `String?` overload. |
| `StatusRow` | `SettingsPanel.swift:21` | **Moves** to `HubRows.swift` on the new five-state vocabulary, **plus** a convenience initializer taking the existing `CheckState` so `DeviceTab.swift:31,37` compile unchanged. |
| `CheckState` | `HubViewModel.swift:15` | **Untouched.** You may not edit `HubViewModel.swift`. Map it into `HubState` inside `HubRows.swift`. |
| `BeaconPalette` | `DevicePreview.swift:16` | **Untouched by you.** WS-7 moves it. |

**To build — the roster.** Names are frozen here because §3.1's table is pasted into six later briefs.

`HubStyle.swift`:

- `enum HubSpace` — `hair`(2) `xs`(4) `s`(8) `m`(12) `l`(16) `xl`(24) `xxl`(32), all `static let CGFloat`.
- `enum HubType` — `pane` `figure` `section` `body` `bodyEmph` `control` `secondary` `caption`
  `eyebrow`, all `static let Font`, all built from a macOS text style (`.title3`, `.title`,
  `.headline`, `.body`, `.callout`, `.subheadline`, `.caption`). **Never `.system(size:)`.**
  `figure` carries `.monospacedDigit()`. `eyebrow` is `.caption` semibold; its `.tracking(0.6)` and
  uppercasing are applied by a `.hubEyebrow()` modifier, since `Font` cannot carry tracking.
- `enum HubColor` — the 15 roles of §2.3, all `static let Color`.
- `enum HubDynamic` — `static func color(light:dark:) -> Color`, implemented with
  `NSColor(name: nil) { appearance in … }`. Every `fill.*` goes through it. Resolve
  `NSColor.controlAccentColor` **inside** the provider closure, never outside it.
- `enum HubRadius` — `control`(6) `card`(10); `enum HubShape` — `control` `card` `pill`, all
  `.continuous`.
- `enum HubStroke` — `hairline`(1).
- `enum HubControlMetrics` — `height`(22) `heightProminent`(28) `hitMin`(28) `iconColumn`(20)
  `fieldMinWidth`(180) `proseMax`(560).
- `enum HubMotion` — `fast`(0.12) `normal`(0.22) `slow`(0.40), plus
  `static func animation(_ d: Double, reduceMotion: Bool) -> Animation?` returning `nil` when reduced.
- `ViewModifier`s: `.hubCard()`, `.hubCardShadow()`, `.hubProse()`, `.hubEyebrow()`. One type-check
  each, per §9.2.

`HubRows.swift`:

- `enum HubState` — `checking` `notSetUp` `ok` `warn` `error`; `var glyph: String`, `var tint: Color`.
  **One** vocabulary, replacing the five at `SettingsPanel.swift:46`, `SonosSettingsView.swift:100`,
  `SourcesTab.swift:101`, `PageDesignerView.swift:775`, `TickerEditorView.swift:289`.
- `struct SectionHeader` (§3.1)
- `struct SettingsRow` (§3.2) — leading icon optional, `minHeight` 36 / 52, never `height`. **The row
  is not a tap target.**
- `struct StatusRow` (§3.3) — glyph column `iconColumn` wide; titles are `inkPrimary` even in
  `warn`/`error`.
- `struct ListRow` (§3.4) — primary / optional `·`-joined secondary / `isCurrent` / action.
- `struct RowSeparator` — takes `hasLeadingIcon: Bool` and **derives** the inset (§2.4). This exists
  specifically so nobody types `.padding(.leading, 42)` again.

`HubSurfaces.swift`:

- `struct Card` (§3.5), padding mode `.content` (`space.l`) or `.rows` (0).
- `struct EmptyState` (§3.6) — hand-built, because `ContentUnavailableView` is macOS 14.
- `struct LoadingState` (§3.8) with `style: .inline | .block`, **including the 150 ms guard** so a
  40 ms room fetch never flashes a spinner. Implement as a cancellable `Task.sleep` before the flag is
  set. The label names what is loading.
- `struct CatalogTile` (§3.7) — **two** text levels, status as a corner mark, fixed height 92, no
  blanket `.opacity`.
- `struct HubButton` + `HubButtonKind` — `.borderedProminent` / `.bordered`, system disabled
  rendering only.
- `struct IconButton` — 28 × 28 hit target, and **`label: String` is a non-optional parameter** that
  becomes `.accessibilityLabel`. This makes design §8.2's eleven unlabelled icon buttons impossible to
  reintroduce, and shrinks WS-8 to almost nothing.
- `struct HubBadge` — capsule, `type.caption`. Badges only, never a container.
- `struct FooterBar` (§3.11) — status lines with a per-channel 6 pt dirty dot on the left, secondary
  then primary on the right.

`DeviceGlass.swift` — **frame only:**

- `enum GlassMetric` — `bezel`(3), `cornerRatio`(0.22), `safeInsetRatio`(40.0/466.0).
- `enum GlassColor` — `bezel`, a dynamic pair: `#101010` light, **`#2E2E2E` dark**. Note the
  inversion; it is deliberate (§6.2).
- `struct DeviceGlassPanel<Content: View>` — draws bezel, `shadow.card`, the rounded clip, and an
  **outside** accent selection ring at `radius.card + 3` via `.overlay` + `.padding(-3)`. Content is
  supplied by the caller. Selection never changes stroke width; layout never moves.

**What NOT to build in WS-0:** do not move `BeaconPalette`, do not touch the sketches, do not
re-derive the type multipliers, do not bundle fonts. All of that is WS-7. You are building the frame
so WS-2 has something to put a preview inside during wave 1.

### Acceptance gate

```bash
cd <worktree>/hub

# 1. Builds and tests.
swift build
swift test 2>&1 | grep -E "^Executed [0-9]+ tests"     # >= 428 (416 + >=12 new), 0 failures

# 2. THE INTERNAL MANDATE. All four must print 0.
grep -c "private\|fileprivate" Sources/beacon-hub/HubStyle.swift
grep -c "private\|fileprivate" Sources/beacon-hub/HubRows.swift
grep -cE "^(private|fileprivate) (struct|enum|func|let|var)" Sources/beacon-hub/HubSurfaces.swift
grep -cE "^(private|fileprivate) (struct|enum)" Sources/beacon-hub/DeviceGlass.swift

# 3. No raw font sizes in the new layer. Must print 0.
grep -c "\.system(size:" Sources/beacon-hub/HubStyle.swift Sources/beacon-hub/HubRows.swift \
                         Sources/beacon-hub/HubSurfaces.swift

# 4. No banned colours in the new layer. Must print 0.
grep -cE "Color\.white|Color\.black|Color\.blue" Sources/beacon-hub/Hub*.swift

# 5. The compat layer is announcing itself. Must be > 0 and is the wave-1 baseline.
swift build 2>&1 | grep -c "is deprecated"

# 6. SettingsPanel.swift is gone.
test ! -f Sources/beacon-hub/SettingsPanel.swift && echo "deleted"
```

Note on gate 2: `HubSurfaces.swift` and `DeviceGlass.swift` use the anchored form because a component
may legitimately have `private var` helpers *inside* a `struct` (§9.2 requires them). What must never
be private is a **top-level declaration**.

**Tests to write (floor: +12, target ~20).** All pure values, no rendering:

- `HubStyleTests`: the spacing ladder is exactly `{2,4,8,12,16,24,32}` and nothing else; there are
  exactly two numeric radii; every `fill.*` token **resolves to a different sRGB value under
  `.aqua` vs `.darkAqua`** (`NSColor.resolvedColor(with:)`) — this one mechanically catches the
  "one opacity for both appearances" bug that produced the whole of design §7; `HubMotion.animation`
  returns `nil` when `reduceMotion` is true.
- `HubContrastTests`: compute the WCAG 2.1 contrast ratio from resolved sRGB components and assert
  `ink.primary` and `ink.secondary` each clear **4.5:1** over `surface.content` and over `fill.card`,
  in **both** appearances. Additionally assert `ink.tertiary` is **below** 4.5:1 — pinning the known
  value so nobody quietly promotes it to carrying content (§2.3, §8.1).
- `HubRowsTests`: `HubState` glyph/tint mapping is total; `CheckState` → `HubState` maps
  `.bad` → `.notSetUp` (**not** `.error` — a pending setup step is not an error, and
  `SettingsPanel.swift:44`'s comment already says so); `RowSeparator` inset is 12 without an icon and
  44 with one (12 + 20 + 12), derived rather than typed.
- `HubComponentTests`: construct **every** shared component and read **every** token from the test
  target. This test's job is to fail to compile if anything is `private`. It asserts almost nothing;
  say so in a comment so a later reader does not "improve" it away.

### Traps

1. **`SectionHeader` and `StatusRow` already exist as internal types.** Declaring new ones in
   `HubRows.swift` without deleting `SettingsPanel.swift` in the same commit is a redeclaration error.
   Move, don't copy.
2. **`StatusRow`'s existing call sites pass `CheckState`, not your new `HubState`.** `DeviceTab.swift`
   is not yours to edit. Ship the convenience initializer or you break the build for a file you do not
   own.
3. **`SectionHeader(title:subtitle:)` takes a non-optional `String` today.** Four files call it that
   way. Adding a `String?` parameter with a default changes overload resolution and can break them.
   Keep the existing signature and *add* an overload.
4. **`@available(*, deprecated)` on a `View` struct warns at every call site — including inside
   `DeckUI.swift` itself** if the wrapper's body uses the deprecated type. Build the wrapper on the
   *new* component, not on the old body.
5. **`Color.accentColor` inside a dynamic provider.** `NSColor(name:dynamicProvider:)`'s closure must
   resolve `NSColor.controlAccentColor` *inside* itself; capturing a resolved value outside freezes
   the accent at process start and the token stops tracking a live accent change.
6. **The 150 ms loading guard leaks a `Task` if not cancelled.** Cancel on `onDisappear` and on
   completion, or a fast popover open/close cycle spawns orphans.
7. **Do not add a `SettingsRow` "whole-row tap" gesture.** It is an iOS idiom and on macOS it produces
   accidental toggles when the user meant to select text (design §3.2).

### Rollback

`git revert` the single WS-0 commit. Nothing else in the tree depends on it yet — that is the entire
reason it ships alone. If only one component is wrong, delete that component and its test; the layer
is additive and nothing consumes it during wave 0.

### 3.1 What downstream imports — DO NOT REDEFINE

**This table is pasted verbatim into every brief from WS-1 onward.** Everything in it is `internal`
and reachable from any file in the `beacon-hub` target. If your surface needs one of these things,
you import it. You do not write a file-local version, you do not "adapt" it by copying, and you do not
add a parameter to it — if it does not fit, you stop and report (§0).

| Need | Use | Defined in | Replaces |
|---|---|---|---|
| Any spacing number | `HubSpace.xs/.s/.m/.l/.xl/.xxl` (`.hair` only for optical nudges) | `HubStyle.swift` | 19 distinct padding literals |
| Any font | `HubType.pane/.figure/.section/.body/.bodyEmph/.control/.secondary/.caption/.eyebrow` | `HubStyle.swift` | **154** `.system(size:)` sites, 11 sizes |
| Any colour | `HubColor.<role>` (15 roles) | `HubStyle.swift` | `Color.blue`×4, `.black`×3, `.white`×2, `.green`×10, `.orange`×12, `.red`×7 |
| A light/dark fill | `HubDynamic.color(light:dark:)` | `HubStyle.swift` | 9 single opacities |
| Any corner | `HubRadius.control/.card`, `HubShape.control/.card/.pill` | `HubStyle.swift` | radii 6, 7, 8, 10, 12, 13 |
| Any animation | `HubMotion.animation(_:reduceMotion:)` | `HubStyle.swift` | ad-hoc `.easeInOut(duration: 0.18)` |
| A section title | `SectionHeader` | `HubRows.swift` | `SettingsPanel.SectionHeader` |
| A settings/toggle row | `SettingsRow` | `HubRows.swift` | `ToggleRow`, `ProviderRow`, `AgentProviderRow` |
| A status/check row | `StatusRow` + `HubState` | `HubRows.swift` | 5 independent glyph switches |
| A pickable row | `ListRow` | `HubRows.swift` | `InstrumentRow`, `RoomRow`, `ResultRow`, `CurrentRow`, `ArgPickerList`'s inline button |
| A row separator | `RowSeparator(hasLeadingIcon:)` | `HubRows.swift` | insets 11, 12, 42 |
| A grouped surface | `Card` | `HubSurfaces.swift` | `Module` |
| "Nothing here" | `EmptyState` | `HubSurfaces.swift` | `"No options"` at 60 % opacity |
| "Loading…" | `LoadingState` | `HubSurfaces.swift` | 4 bare `ProgressView`s |
| A catalog tile | `CatalogTile` | `HubSurfaces.swift` | `AvailableTile`, `paletteTile` |
| A button | `HubButton` | `HubSurfaces.swift` | `DeckButton` |
| An icon-only button | `IconButton` (label required) | `HubSurfaces.swift` | `arrow(...)` 20×18, `IconButton` 22×22 |
| A small capsule label | `HubBadge` | `HubSurfaces.swift` | 4 hand-rolled capsules |
| A pinned action bar | `FooterBar` | `HubSurfaces.swift` | `PageDesignerView.footer` |
| A framed device panel | `DeviceGlassPanel` | `DeviceGlass.swift` | `CarouselCard`'s `controlBackgroundColor` card |

**Deprecated but still compiling** (`DeckUI.swift`): `Module`, `DeckButton`, `ToggleRow`. Every use
emits a warning naming its replacement. Your gate requires your deprecation count to drop; WS-9
deletes the file when the global count reaches zero.

---

## 4. Wave 1 — the two named complaints

All three run in parallel over disjoint files. **Three written contracts between them:**

- **C1 — the window/pane seam.** WS-1 sets `contentMinSize` to **820 × 560**. WS-2 **deletes**
  `PageDesignerView.swift:35`'s `.frame(minWidth: 780, minHeight: 620)` and instead declares
  per-pane minimums *inside* the destination (composition ≥ 380, inspector 260–320). Neither is
  correct without the other; both are stated in both briefs.
- **C2 — the destination body seam is frozen and stays frozen.** The Pages destination's body is
  exactly `PageDesignerView(model: model)`, as `SettingsTabs.swift:56` already records. WS-1 does not
  wrap it, pad it, or put a header on it; WS-2 does not reach out of it.
- **C3 — the disclaimer line.** WS-2 adds the single line *"Previews are approximations — the Beacon
  renders these itself."* under the carousel band. The three in-glass disclaimer strings in
  `DevicePreview.swift` are deleted by **WS-7** in wave 3. There is therefore a wave-2 window where
  both are visible. That is accepted, and it is written down here so nobody "fixes" it by reaching
  into a file they do not own.

### WS-1 — window chrome: the sidebar, the title, the dirty state, the close sheet

**Goal.** Delete the pill tab bar and the `"\u{2022}"` string hack; land a two-column
`NavigationSplitView` with a source-list sidebar; give the window a real per-destination title, macOS's
own document-edited dot, a sidebar dirty dot, and a Save & push / Discard / Cancel sheet on close.

**Files to touch.** `SettingsTabs.swift`, `SettingsWindowController.swift`, **new**
`SettingsCloseDecision.swift`, `Tests/beacon-hubTests/SettingsTabTests.swift`, **new**
`Tests/beacon-hubTests/SettingsCloseTests.swift`.

**Files NOT to touch.** `PageDesignerView.swift`, `ComplicationEditorView.swift`, every other view
file, `AppDelegate.swift`, `MenubarController.swift`, `HubViewModel.swift`, anything in `HubStyle.swift`
/ `HubRows.swift` / `HubSurfaces.swift` / `DeviceGlass.swift`, anything under `BeaconHubKit/` or
`firmware/`.

**What already exists.**

- `SettingsTab` (`SettingsTabs.swift:6`) — a 4-case `String`/`CaseIterable`/`Identifiable`/`Hashable`
  enum with `title` and `systemImage`. **Keep it.** It is already the right shape to drive a `List`.
- `SettingsTabPersistence` (`:38`) — a plain `UserDefaults` key, `"BeaconSettingsTab"`, read via
  `@AppStorage`. Two external callers pre-seed it: `MenubarController.swift:170`
  (`openSettingsOnSources`) and `AppDelegate.swift:815` (`.device`). **Both must keep working
  unchanged** — you may not edit either file, so the key, its type and its semantics are frozen.
- `SettingsWindowController` (`SettingsWindowController.swift`) — builds the window, sets
  `contentMinSize` 720 × 520 (`:48`), `frameAutosaveName`, `isRestorable`,
  `isReleasedWhenClosed = false`, and flips activation policy `.regular` ⇄ `.accessory`.
- `windowWillClose` (`:60`) — **silently reverts** staged page and complication edits today.

**What to build.**

1. `SettingsRootView.body` becomes `NavigationSplitView { sidebar } detail: { destination }`.
   The sidebar is `List(selection:)` + `.listStyle(.sidebar)` over `SettingsTab.allCases`, each row a
   `Label` plus a trailing `Circle().frame(width: 6, height: 6)` filled `HubColor.stateWarn` when
   `model.pagesDirty || model.compsDirty`. **The dot shows regardless of selection.** Do **not** use
   `.badge(_:)` — it now renders, but a badge communicates a count and this is a boolean.
   `.navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)` on the sidebar.
2. The detail column switches on the selection. **The Pages case is exactly
   `PageDesignerView(model: model)`** (contract C2).
3. `w.title` follows the selection. The window controller observes the same `@AppStorage` key —
   simplest correct route on macOS 13 is a small `onChange(of:)` **single-parameter** overload in
   `SettingsRootView` calling a closure the controller installs. Do not reach for the two-parameter
   overload; it is macOS 14.
4. `w.isDocumentEdited = model.pagesDirty || model.compsDirty`, kept in sync the same way.
5. **The close sheet.** Move the logic from `windowWillClose` to **`windowShouldClose`**, returning
   `false` when either channel is dirty and presenting an `NSAlert` as a sheet with three buttons —
   **Save & push**, **Discard**, **Cancel** — worded per design §3.10 (title is a question naming the
   object; the message says what is lost *and* what is kept).
6. **New `SettingsCloseDecision.swift`** — the pure policy, so this behaviour change is tested rather
   than eyeballed:
   ```swift
   enum CloseIntent { case saveAndPush, discard, cancel }
   enum CloseEffect: Equatable { case applyComps, applyPages, revertComps, revertPages, close, stayOpen }
   enum SettingsClosePolicy {
       static func needsConfirmation(pagesDirty: Bool, compsDirty: Bool) -> Bool
       static func effects(for intent: CloseIntent, pagesDirty: Bool, compsDirty: Bool) -> [CloseEffect]
       static func documentEdited(pagesDirty: Bool, compsDirty: Bool) -> Bool
   }
   ```
   `effects(for: .saveAndPush, …)` must emit **`.applyComps` before `.applyPages`** — the live,
   non-restarting push lands before the one that reboots the device, matching
   `PageDesignerView.saveAll()` (design §7). This is the only place in the codebase that ordering will
   exist twice; the test is what keeps them the same.
7. `⌘1`–`⌘4` select destinations. Attach `.keyboardShortcut` to hidden buttons inside the sidebar
   view — **do not** try to add main-menu items, because that would require editing
   `MenubarController.swift`, which you do not own. (Firmware's `⌘5` arrives with the OTA workstream;
   see §10.2.)
8. `contentMinSize` → **820 × 560** (contract C1). `setContentSize` default rises to at least that.
9. The window opens with **no text field as first responder** (design §4.4).
10. **Rename** `testAllFourTabsRoundTripThroughRawValue` → `testEveryTabRoundTripsThroughRawValue` and
    `testAllFourTabsHaveDistinctTitles` → `testEveryTabHasADistinctTitle`. **No assertion changes, no
    test deleted.** They are already `allCases`-driven and keep passing when a fifth case lands.
    `testSaveWritesTheDocumentedKeyToStandardDefaults` is untouched.

**Acceptance gate.** §2.2, plus:

```bash
cd <worktree>/hub
grep -c "TabView"            Sources/beacon-hub/SettingsTabs.swift   # 0
grep -c 'u{2022}'            Sources/beacon-hub/SettingsTabs.swift   # 0
grep -c "tabItem"            Sources/beacon-hub/SettingsTabs.swift   # 0
grep -c "NavigationSplitView" Sources/beacon-hub/SettingsTabs.swift  # >= 1
grep -c "\.system(size:"     Sources/beacon-hub/SettingsTabs.swift Sources/beacon-hub/SettingsWindowController.swift  # 0
grep -c "820\|560"           Sources/beacon-hub/SettingsWindowController.swift  # >= 2
grep -c "testAllFourTabs"    Tests/beacon-hubTests/SettingsTabTests.swift       # 0
swift test 2>&1 | grep -E "^Executed [0-9]+ tests"   # >= 436 (WS-0's 428 + >=8)
```

Test floor **+8**, all pure: clean close needs no confirmation and reverts nothing; pages-only dirty
needs it; comps-only dirty needs it; discard emits exactly the two reverts then `.close`; save emits
`.applyComps` then `.applyPages` then `.close`, in that order; cancel emits exactly `[.stayOpen]` and
no revert; `documentEdited` is the disjunction.

Plus the human script in §8.3, items H1–H4.

**Traps.**

1. **`windowWillClose` cannot cancel.** It fires after the decision is made. You must move to
   `windowShouldClose` and call `w.close()` yourself from the sheet's completion handler.
2. **Save & push does not clear the dirty flags synchronously.** `pagesDirty` is derived from
   `enabledPageIDs != appliedPageIDs`, and `appliedPageIDs` only updates when `AppDelegate`
   acknowledges the push. So "Save & push" must close the window **without** re-checking dirtiness, or
   `windowShouldClose` re-presents the sheet forever. Set an `isClosing` latch.
3. **`NSApp.setActivationPolicy(.accessory)`** currently lives in `windowWillClose`. It must still run
   exactly once on a real close — including the close you now trigger programmatically.
4. **The `frameAutosaveName` frame may be smaller than the new 820 × 560 minimum** for anyone who has
   run this build before. AppKit clamps to `contentMinSize` on restore; verify by hand, because a
   window that opens 720 pt wide with a sidebar is the first thing the owner will see.
5. **The sidebar show/hide toggle is not automatic on macOS 13 without a toolbar.** Design §5.1 leans
   on it as the sub-820 escape hatch. Verify it appears. If it does not, report — do **not** silently
   add an `NSToolbar` (it changes the title bar's whole look and is a design decision, not an
   implementation detail). See §10.6.
6. **`@AppStorage` + `List(selection:)` wants an `Optional` binding.** `SettingsTab?` selection with a
   non-optional persisted raw value needs a small adapter; keep it as a typed computed `Binding`, not
   an inline ternary (§9.2).
7. **Do not change `SettingsTabPersistence.key` or its value semantics.** Two files you cannot edit
   write to it.

**Rollback.** Revert the WS-1 commit. `PageDesignerView` is untouched by you, so wave 1's other two
workstreams survive intact — the window falls back to the pill bar with a correctly re-laid-out Pages
destination inside it. Ugly, shippable, not broken.

### WS-2 — the Pages destination

**Goal.** Land the merge that pays for the sidebar, de-grey the band, fix the tile hierarchy, bound
the inspector and fill it with the page's own preview, reframe the carousel card as device glass, and
replace the hand-built Sonos room button with a native `Menu`. This is the workstream that has to make
the owner's second named complaint visibly go away.

**Files to touch.** `PageDesignerView.swift` (920 lines, 49 raw font sites, 9 view types), **new**
`InspectorTier.swift`, **new** `Tests/beacon-hubTests/InspectorTierTests.swift`.

**Files NOT to touch.** `SettingsTabs.swift`, `SettingsWindowController.swift`,
`ComplicationEditorView.swift` (WS-3 owns it — you only *call* `ComplicationEditorView(model:)`),
`DevicePreview.swift` (WS-7 owns it — you only *call* `DevicePreview(pageID:model:size:)`, wrapped in
`DeviceGlassPanel`), `SourcesTab.swift`, `TickerEditorView.swift`, `HubPanel.swift`, the component
layer, `HubViewModel.swift`, `AppDelegate.swift`, `SonosProvider.swift`, anything under `BeaconHubKit/`
or `firmware/`.

**What already exists.** All of these are correct behaviour and must survive:

- `placeOnCarousel` / `disablePage` / `moveEnabled` (`:257`–`:297`) — the drag/insert index arithmetic,
  including the off-by-one note. **Do not rewrite this logic.** Re-layout only.
- The two-channel footer and `saveAll`'s comps-then-pages order (`:236`).
- The chart's `orphan` / `defaultSym` / `ChartInstrumentSelection` path (`:530`–`:596`) and the
  search-backed `ChartInstrumentPopover` — the chart **keeps** a popover because it searches every
  Yahoo symbol (design §3.4).
- The Sonos room's deliberate bypass of `PageRow.opts` in favour of `SonosRoomStore`
  (`:444`–`:459`) and its `didBecomeKeyNotification` re-read (`:435`). **Keep both.** The widget
  changes; the storage route does not.
- The chevron reorder path (`:285`) — the non-pointer equivalent of dragging. Keep it, and now it gets
  real labels for free from `IconButton`.

**What to build.**

1. **Delete `.frame(minWidth: 780, minHeight: 620)` (`:35`)** — contract C1.
2. **Merge the carousel and the catalog into one elastic column.** Layout becomes
   `HSplitView { composition; inspector }` with composition ≥ 380 elastic and inspector
   `minWidth: 260, idealWidth: 280, maxWidth: 320`. Inside composition: the ON THE BEACON strip
   (horizontal scroll, still draggable, still reorderable), a `RowSeparator`-style hairline, then the
   AVAILABLE grid. Drag between them becomes a short vertical gesture in one column.
3. **The band takes no fill.** Delete `Color(nsColor: .underPageBackgroundColor)` (`:83`) — the strip
   sits on `surface.window` bounded by hairlines top and bottom. Single cheapest fix in the document.
4. **`AvailableTile` → `CatalogTile`.** Two text levels. Status becomes an `accent`
   `checkmark.circle.fill` in the top-trailing corner. **Delete `.opacity(row.enabled ? 0.55 : 1)`
   (`:393`)** — it dims the border and the status mark, which is why the current tile is both the
   greenest and the faintest thing on screen. Enabled dims the *title* to `ink.secondary`; nothing
   else. Fixed height 92. Selection changes stroke **colour**, never width (delete the
   `lineWidth: isSelected ? 2 : 1` at `:391`, and the same at `:349`).
5. **`CarouselCard` becomes device glass.** Wrap `DevicePreview` in `DeviceGlassPanel`; delete the
   `controlBackgroundColor` card at `:346`. **Move the remove `x` off the panel** — today it is a
   `ZStack(alignment: .topTrailing)` white-on-`Color.black.opacity(0.55)` circle drawn *on top of the
   device glass* (`:316`–`:321`), which is hub chrome painted onto device content. Title, reorder
   chevrons and remove button all sit **below** the glass on the window background.
6. **The inspector rule.** Delete
   `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)` (`:166`). Content is a
   top-aligned `VStack(alignment: .leading, spacing: HubSpace.l)` terminated by
   `Spacer(minLength: 0)`. Nothing gets `maxHeight: .infinity`.
7. **New `InspectorTier.swift`** — the three tiers of design §5.2.1 as a **pure function**, so the
   fix is unit-tested rather than asserted:
   ```swift
   enum InspectorTier: Equatable { case previewOnly, optionsPlusPreview, optionsOnly }
   enum InspectorLayout { static func tier(optionCount: Int) -> InspectorTier }   // 0, 1-2, 3+
   ```
   Tier `.previewOnly` and `.optionsPlusPreview` render a **"What this page shows"** block: the
   page's own `DevicePreview` at 160 pt inside a `DeviceGlassPanel`, plus one `type.secondary`
   sentence. **Delete `"No options"` at `.secondary.opacity(0.6)` (`:441`).**
8. **The Sonos room selector becomes a `Menu`** (design §3.4), deleting `SonosRoomPopover` (`:830`),
   `RoomRow` (`:901`) and the hand-built button at `:476`. Async states live inside the menu as
   disabled items plus a "Retry" item. **Read §10.5 before starting** — whether a room row can carry
   a second field is an open question, and the answer changes your scope. If it is unresolved at
   dispatch, ship one-line rows and record the exception in your report.
9. **`AgentProviderRows` / `AgentProviderRow` (`:741`–`:813`) are deleted** and replaced with
   `SettingsRow`s bound to the same `model.providers` / `onSetProviderUsage` / `onSetProviderBuddy` /
   `onInstallProviderHooks`, and `StatusRow`'s one vocabulary for the setup chip. **`.controlSize(.mini)`
   is banned.** When WS-4 does the same to `SourcesTab.ProviderRow`, the divergence disappears by
   construction. Delete the `:740` comment — it describes a constraint that no longer exists.
10. **The disclaimer line** (contract C3): one `type.caption` line under the strip.
11. Footer → `FooterBar`. **Delete the triple dimming** at `:198`–`:199` (`.disabled` +
    `.opacity(0.4)` on top of `DeckButton`'s own `.opacity(0.5)`).
12. Gate the reorder animation (`:295`) and the `scrollTo` (`:79`) on
    `@Environment(\.accessibilityReduceMotion)` via `HubMotion.animation(_:reduceMotion:)`.
13. **Split the file.** 920 lines holding nine view types is past every threshold in §9.2. Land the
    popovers/menus as their own file(s) if that helps you stay under the type-checker limit — you own
    the whole area, so new files here are yours. Name them `PageDesigner*.swift` so ownership stays
    obvious.

**Acceptance gate.** §2.2, plus:

```bash
cd <worktree>/hub
grep -c "\.system(size:"            Sources/beacon-hub/PageDesigner*.swift   # 0  (from 49)
grep -c "underPageBackgroundColor"  Sources/beacon-hub/PageDesigner*.swift   # 0
grep -c "SonosRoomPopover\|struct RoomRow" Sources/beacon-hub/PageDesigner*.swift  # 0
grep -c "AgentProviderRow"          Sources/beacon-hub/PageDesigner*.swift   # 0
grep -c "controlSize(.mini)"        Sources/beacon-hub/PageDesigner*.swift   # 0
grep -c "No options"                Sources/beacon-hub/PageDesigner*.swift   # 0
grep -c "maxHeight: .infinity"      Sources/beacon-hub/PageDesigner*.swift   # 0
grep -c "minWidth: 780"             Sources/beacon-hub/PageDesigner*.swift   # 0
grep -cE "Color\.white|Color\.black|Color\.blue" Sources/beacon-hub/PageDesigner*.swift   # 0
grep -cE "cornerRadius: (6|7|8|10|12|13)"        Sources/beacon-hub/PageDesigner*.swift   # 0
grep -cE "^(private )?struct .*(Row|Tile|Card|Chip|Badge): View"  Sources/beacon-hub/PageDesigner*.swift
#   ^ must be 0 or exactly the names in your report's "new types" line, with a reason each
swift test 2>&1 | grep -E "^Executed [0-9]+ tests"   # >= 434 (WS-0's 428 + >=6)
```

Test floor **+6**: `InspectorLayout.tier` for 0 / 1 / 2 / 3 / 8 options; and that the tier a Sonos page
with one option resolves to is `.optionsPlusPreview` — the machine-checkable half of complaint 2.

Plus the human script in §8.3, items H5–H9.

**Traps.**

1. **`LazyVGrid`'s `.adaptive(minimum: 110)` at 380 pt gives exactly three columns** —
   `110×3 + 10×2 + 16×2 = 382`. One extra point of padding and it silently drops to two and the grid
   looks broken at the stated minimum. Verify at exactly 820 pt window width.
2. **`dropDestination` inside a `ScrollView` inside an `HSplitView`** — the drop target geometry
   changes when the carousel stops being full-bleed. Re-test every drag path: catalog→strip,
   strip→strip reorder, strip→catalog (disable), and the append zone.
3. **`.draggable` + `.onTapGesture` on the same view** is already load-bearing here and is easy to
   break when the card's view tree changes. Both must still work.
4. **`ComplicationEditorView` is rendered by your `inspector` but owned by WS-3.** Call it, size the
   column for it, do not edit it. If it does not fit, that is WS-3's contract, not your patch.
5. **`Menu` on macOS 13 does not support arbitrary view content in items** the way iOS does — items
   are `Button`s with `Label`s. A two-field room row may need `Text` with an embedded `·`, not a
   `VStack`. Confirm before promising it.
6. **The chart popover must keep its search.** It is not a `Menu` candidate. Design §3.4 says so
   explicitly.
7. **Do not "simplify" the room's `SonosRoomStore` route into `PageRow.opts`.** `:444`'s comment
   documents a real regression: `enabledPageOpts` filters by `enabled`, so a disabled Sonos page would
   silently drop its room on the next save.
8. **`.frame(width: 300)` on the grid (`:129`) disappears** in the merge. Make sure nothing else
   depends on that fixed width.

**Rollback.** Revert the WS-2 commit(s). WS-1's sidebar survives with the old Pages layout inside it —
which is exactly the "sidebar plus a 780 pt-minimum destination" configuration, so the window's
820 pt minimum will feel tight but nothing breaks. Note this explicitly in your PR so the reviewer
knows the fallback state.

### WS-3 — Home's complication inspector, at 260 pt

**Goal.** Re-tokenise `ComplicationEditorView` and re-lay it out so it is correct in a **228 pt
content column** (260 pt inspector minus `HubSpace.l` × 2).

**Files to touch.** `ComplicationEditorView.swift` only.

**Files NOT to touch.** `PageDesignerView.swift` (WS-2 owns the inspector that hosts you), every other
view file, the component layer, `BeaconHubKit/ComplicationEditor.swift` and everything else under
`BeaconHubKit/` (**the rules live there and are not yours** — capacity, one-instance-per-id, arg
validation, the blank-Home warning), `HubViewModel.swift`, `firmware/`.

**What already exists.** The view renders what `BeaconHubKit.ComplicationEditor` decides and never
re-derives a rule. That property is correct and must survive your edit unchanged — you are moving
pixels, not logic. `ComplicationEditorTests` (162 lines, in `BeaconHubKitTests`) must stay untouched.

**What to build.**

1. Header (`:38`): the title/subtitle become `SectionHeader`; the "n of 6 slots" capsule becomes
   `HubBadge`. At 228 pt they cannot share a row — stack the badge under the header, or move it to a
   trailing position only when width allows. Pick one and make it deterministic; do not use a
   `GeometryReader` race.
2. `paletteTile` (`:105`) → `CatalogTile`. The palette grid's `.adaptive(minimum: 92)` yields
   `92×2 + 8 = 192 ≤ 228` — two columns. Confirm that is what renders and that labels do not truncate
   to uselessness; if they do, report rather than inventing a third tile style.
3. `ComplicationStackRow` (`:192`) → `ListRow` or `SettingsRow`, whichever fits its two-field shape.
   Its remove button → `IconButton` with a real label ("Remove Clock").
4. `ArgPickerList` (`:256`)'s inline buttons → `ListRow`.
5. The two orange warning strings (`:83`, `:86`) → `StatusRow` `warn`, with the **word in
   `ink.primary`** and the colour on the glyph (design §2.3). The blank-Home warning is a genuine
   `warn`; a drop refusal is transient and may stay inline `type.secondary` — state which you chose.
6. `appendDropZone` (`:75`) keeps its dashed affordance; tokenise the radius and the label.
7. 17 `.system(size:)` sites → 0.

**Acceptance gate.** §2.2, plus:

```bash
cd <worktree>/hub
grep -c "\.system(size:" Sources/beacon-hub/ComplicationEditorView.swift    # 0  (from 17)
grep -cE "cornerRadius: (6|7|8|10|12|13)" Sources/beacon-hub/ComplicationEditorView.swift  # 0
grep -cE "^private struct .*(Row|Tile): View" Sources/beacon-hub/ComplicationEditorView.swift  # 0
git diff --name-only <base> | grep -c "BeaconHubKit"    # 0
swift test 2>&1 | grep -E "^Executed [0-9]+ tests"      # >= 428, 0 failures
```

No new tests required (the rules are already covered by `ComplicationEditorTests`); if you add none,
say so and show the total is unchanged. Plus human script item H10.

**Traps.**

1. **The stack is an ordered list of placements, not six fixed wells.** The clock is *one* entry
   charged 2 units. Do not let a layout change imply a 1–6 grid.
2. **`.draggable` + `.dropDestination` on stack rows** target *insertion points*. Re-verify drag
   within the stack, palette→stack, and the append zone after re-layout.
3. **`.popover` anchored to a row inside a 260 pt column** can position off-screen at the window's
   trailing edge. Check the arg picker at the 820 pt minimum.
4. You cannot see your own result without WS-2's inspector bounding. Build a `#Preview` at
   `.frame(width: 228)` in **both** colour schemes and verify there; say so in your report.

---

## 5. Wave 2 — the remaining surfaces

Mechanical now that the components exist. Three parallel workstreams, disjoint files, no new
architecture. Each one's job is: delete its local row types, adopt the shared ones, take its
`.system(size:)` count to zero, and take its deprecation warnings to zero.

### WS-4 — the other three destinations + Sonos settings

**Files:** `SourcesTab.swift` (7 sites), `DeviceTab.swift` (3), `GeneralTab.swift` (2),
`SonosSettingsView.swift` (13). **Not:** `PageDesignerView.swift`, `TickerEditorView.swift`,
`HubPanel.swift`, `ComplicationEditorView.swift`, the component layer, `SonosProvider.swift`,
`SonosAPI.swift`, `AppDelegate.swift`.

Highlights:

- **`SourcesTab.ProviderRow` (`:68`) is deleted** and rebuilt on `SettingsRow` + `StatusRow`. This is
  the moment the §1.2 divergence stops existing — WS-2 already did the other half. Verify by eye that
  the Sources row and the Agents-page row are now the same component at the same size.
- `SourcesTab`'s `ColumnHeader` (`:52`) → `type.caption`; the "Ready" `Label` (`:106`) → `StatusRow`
  `ok`, word in `ink.primary`.
- `DeviceTab.swift:90`'s "Not reported by this firmware build" is **content on `ink.tertiary`** at
  ≈ 2.8:1 — move to `ink.secondary` (design §8.1).
- `DeviceTab`'s `Divider().padding(.leading, 42)` (`:36`) → `RowSeparator(hasLeadingIcon: true)`.
- `SonosSettingsView`'s `describe(_:)` is **the model for error copy** (design §3.9) — keep every
  sentence. Its two `.alert` confirmations (`:58`) are **the model for destructive confirmation**
  (§3.10) — keep both halves of the message.
- `SonosSettingsView`'s status mapping (`:100`) collapses into `HubState`. Design §3.3 says the
  current orange for "no Client ID yet" is **miscast**: a normal first-run state is `notSetUp`, not
  `warn`. Change it.
- Pane gutters `20` → `HubSpace.xl` (24) in all four.

**Gate:** §2.2 plus `grep -c "\.system(size:"` = 0 across all four; `grep -c "struct ProviderRow"` = 0;
`grep -cE "Color\.(white|black|blue)"` = 0. Human script H11.

**Traps:** `SonosSettingsView` is a separate file *because of the type checker* — its header says so.
Do not merge it into `SourcesTab`, and split further rather than growing any one body.
`SonosSettingsSection` is embedded in `SourcesTab.body:35`; that seam stays.

### WS-5 — the ticker editor

**Files:** `TickerEditorView.swift` (15 sites). **Not:** anything else.

`ResultRow` (`:191`), `CurrentRow` (`:223`), `IconButton` (`:246`), `SourceChip` (`:263`) and
`SyncBadge` (`:274`) all become shared components — that is five of the ten row implementations gone
in one file. Specifics: the local `IconButton`'s `frame(width: 22, height: 22)` clips at larger text
sizes and has no accessibility label; the shared one is 28 × 28 and requires one. Red 10 pt error text
(`:216`) fails contrast — `ink.primary` at `type.secondary` (§3.9). `frame(width: 420, height: 520)`
(`:29`) becomes `idealHeight` + `minHeight` (§8.3). Trash → `.alert` destructive confirmation naming
the ticker (§3.10).

**Gate:** §2.2 plus 0 `.system(size:)`, 0 `private struct .*Row`, 0 fixed `.frame(height:)` on
anything containing text. Human script H12.

**Trap:** `TickerEditorView` is embedded in `DeviceTab.tickerSection` (`DeviceTab.swift:71`), which
WS-4 owns in the same wave. Your view must not change its own external frame contract; if it must,
report before doing it.

### WS-6 — the menu-bar popover

**Files:** `HubPanel.swift` (15 sites). **Not:** `MenubarController.swift`, anything else.

**Re-tokenise, do not redesign.** The card-stack shape is settled. `Module` → `Card`, `WindowRow`
(`:162`) → shared, `Banner` (`:266`) → `StatusRow` `error`, `LinkButton` (`:278`) /
`ActionButton` (`:294`) → `HubButton` / `IconButton`. `ProviderCard.accessibilityElement(children:
.combine)` (`:147`) is **the VoiceOver template** — keep it and propagate the pattern, do not delete it.
`Color.blue` at `:58` and `:290`, and `Color.white` at `:59`/`:271`, all go.

**Traps.**

1. **`sizingOptions = [.preferredContentSize]`** (`MenubarController.swift:127`). The popover's root
   declares **exactly one** fixed width (340) and **no** descendant declares `.infinity` width or any
   fixed height, or the panel mispositions and clips its header (§9.3).
2. **`type.figure` is ≈ 22 pt where the current usage percentage is 21** (`:175`), and it now *scales
   with the system text size* inside a fixed 340 pt popover holding **two** `ProviderCard`s
   side by side. Add `.minimumScaleFactor` / `lineLimit(1)` and verify at the largest text size. See
   §10.7 — if it cannot be made to fit, report rather than reverting the token.
3. **Vibrancy.** `fill.card` over an `NSPopover`'s material composites differently than over
   `surface.window`. This is the most-used surface in the product; it gets its own line in the human
   script (H13) and must be checked in the real popover, not a preview.

---

## 6. Wave 3 — glass and appearance

### WS-7 — device-glass extraction, proportions, fonts

**Files:** `DevicePreview.swift`, `DeviceGlass.swift`, **new** `hub/Resources/fonts/`,
`hub/build-app.sh`, `hub/Sources/beacon-hub/main.swift`. **Not:** `PageDesignerView.swift` (it already
consumes `DeviceGlassPanel`), any other view, `AppDelegate.swift`, `firmware/`.

**Build:**

1. **Move `BeaconPalette` and every sketch into `DeviceGlass.swift`.** After this, `DevicePreview.swift`
   either disappears into it or retains only the `DevicePreview` entry point. **Nothing outside that
   file may read a device token; nothing inside it may read a hub token** — no `.secondary`, no
   `Color.accentColor`, no `HubSpace.*`, no `HubRadius.*`.
2. **Re-derive the type multipliers.** Replace the eyeballed `size * 0.042 / 0.135 / 0.05 / 0.038 /
   0.036 / 0.032 / 0.044` with four constants from the device's real scale, which is documented in
   `firmware/src/ui/fonts/MANIFEST.md`: **mono 15, body 18, display 30, hero 84**, each ÷ 466. Four
   constants; the preview's proportions become the device's proportions.
3. **Move the disclaimers out** (contract C3): delete `"sample shape · live on device"` (`:207`),
   `"live on device"` (`:233`), `"sample · live once connected"` (`:293`). WS-2 already placed the
   single line under the carousel. **Placeholder dashes (`—.——`) stay inside the glass** — the device
   genuinely renders those.
4. **Delete the SF Symbol inside the glass.** `UnknownSketch` (`:325`) draws
   `questionmark.square.dashed`; the device has a lucide subset, not SF Symbols. Draw a shape or use a
   word.
5. **Bundle the fonts.** See §6.1 below — this is the part with real unknowns.

**Gate:** §2.2, plus

```bash
cd <worktree>/hub
grep -c "\.system(size:" Sources/beacon-hub/DeviceGlass.swift        # > 0 — REQUIRED, this is the exemption
grep -cE "Color\.accentColor|\.secondary|\.primary|HubSpace|HubRadius|HubColor" Sources/beacon-hub/DeviceGlass.swift  # 0
grep -c "BeaconPalette" Sources/beacon-hub/*.swift | grep -v DeviceGlass   # every count 0
grep -c "systemName:" Sources/beacon-hub/DeviceGlass.swift            # 0
grep -c "live on device\|sample shape\|live once connected" Sources/beacon-hub/DeviceGlass.swift  # 0
grep -c "fonts" build-app.sh                                          # >= 1
./build-app.sh release && ls -la "Beacon Hub.app/Contents/Resources/fonts/"
du -sk "Beacon Hub.app/Contents/Resources/fonts/"                     # report the number
```

Test floor **+3**: `DeviceGlassFont.resolve(_:size:)` returns the bundled face when registration
succeeded and a **documented system fallback** when it did not; the four proportion constants equal
`15/466`, `18/466`, `30/466`, `84/466`.

Human script H14.

#### 6.1 Font bundling — what the design assumes and what is actually true

**The design says the faces are "already in the firmware's font pipeline." The *pipeline* is
documented; the font files are not in the repo.** `firmware/src/ui/fonts/` contains generated LVGL C
arrays (`font_sg_body.c`, `font_sg_disp.c`, `font_sg_hero.c`, `font_jbm_mono.c`) — glyph-subset
bitmaps that CoreText cannot load. `firmware/src/ui/fonts/MANIFEST.md` records the upstream sources:

| Family | google/fonts path | Instanced weight |
|---|---|---|
| Space Grotesk | `ofl/spacegrotesk/SpaceGrotesk[wght].ttf` | wght = 500 |
| JetBrains Mono | `ofl/jetbrainsmono/JetBrainsMono[wght].ttf` | wght = 500 |

So WS-7 must **acquire** the OFL TTFs, instance them to wght 500 (`fonttools varLib.instancer`, the
same route the firmware manifest documents), and commit them under `hub/Resources/fonts/` alongside
each family's `OFL.txt`. The OFL requires the licence to ship with the font and forbids renaming a
Reserved Font Name — keep the upstream filenames. **This is a decision that needs the owner's
approval before dispatch** (§10.1): committing binary font assets to a public repo is a repository
policy call, not an implementation detail.

Mechanics, once the files exist:

- **SwiftPM does not copy `Resources/`.** `build-app.sh` copies each resource explicitly
  (lines 128–141). Add `cp -R Resources/fonts "$APP/Contents/Resources/"`. The whole-bundle
  `codesign --force` at line 146 already covers anything under `Contents/Resources`, so no extra
  signing step — but **run `./build-app.sh release` and confirm** rather than assuming.
- Register with `CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)` in `main.swift`,
  **before** any view is built.
- **A fallback is mandatory, not optional.** `swift run` and `swift test` have no bundle; registration
  fails and every sketch would render with a nil font. `DeviceGlassFont.resolve` must fall back to
  `.system(size:design:)` and never crash or blank. That is the +3 test floor above.
- CI runs `swift test` then `./build-app.sh release` on `macos-15` (`.github/workflows/ci.yml:99`),
  and `release-hub.yml:47` runs the same script with a real Developer ID. Both will now carry ~300–400
  KB more. Report the measured delta.

### WS-8 — dark appearance and contrast verification

Runs after wave 2 is merged, in parallel with WS-7 **only if** WS-7 has not yet touched
`DevicePreview.swift`; otherwise sequential. Cross-cutting by nature, but tiny by design, because
`IconButton` already forced accessibility labels and `HubDynamic` already forced dynamic fills.

**Build:** every `#Preview` ships twice, `.preferredColorScheme(.light)` and `.dark` — five previews
exist today and **none** sets a scheme, which is a precise statement of how dark mode got missed. Add
the reduce-motion gate anywhere wave 1–2 missed it. Walk every destination in both appearances with
the contrast table (§8.1) in hand and fix what fails.

**Gate:** `grep -c "preferredColorScheme" Sources/beacon-hub/*.swift` ≥ 2 × the `#Preview` count;
`grep -cE "Color\.(white|black|blue)" Sources/beacon-hub/*.swift` excluding `DeviceGlass.swift` = 0;
`grep -c "accessibilityReduceMotion"` ≥ 3. Human script H15–H16.

**Trap:** `#Preview` blocks do not run under `swift test`. They are a development aid, not coverage.
The arithmetic contrast tests from WS-0 are the coverage; this workstream's real output is a
walkthrough report, not a green suite.

---

## 7. The migration: 154 call sites and ten rows, without divergence or merge hell

### 7.1 The measured starting point

| File | `.system(size:)` sites | Converted by | Wave |
|---|---|---|---|
| `PageDesignerView.swift` | **49** | WS-2 | 1 |
| `DevicePreview.swift` → `DeviceGlass.swift` | **26** | WS-7 — **stays > 0, exempt** | 3 |
| `ComplicationEditorView.swift` | **17** | WS-3 | 1 |
| `TickerEditorView.swift` | **15** | WS-5 | 2 |
| `HubPanel.swift` | **15** | WS-6 | 2 |
| `SonosSettingsView.swift` | **13** | WS-4 | 2 |
| `SourcesTab.swift` | **7** | WS-4 | 2 |
| `SettingsPanel.swift` | **4** | WS-0 (file deleted) | 0 |
| `DeviceTab.swift` | **3** | WS-4 | 2 |
| `DeckUI.swift` | **3** | WS-0 | 0 |
| `GeneralTab.swift` | **2** | WS-4 | 2 |
| **Total** | **154** | | |

**Chrome total = 128** (154 − 26 exempt). Burn-down: WS-0 kills 7, wave 1 kills 66, wave 2 kills 55.
Sum 128. Every file has exactly one owner in exactly one wave.

### 7.2 The five mechanisms

**1. Convert by surface, never by token.** There is no global find-and-replace, and a brief that
proposes one has misread the problem: `11` is `type.secondary` in a hint and `type.caption` in a
column header. A mechanical rewrite would encode the drift rather than remove it. Each workstream owns
whole files and converts every site in them, using judgement about role. **No two workstreams ever
edit the same file** — that single rule is the entire anti-merge-hell mechanism, and it is why §1.1 is
exhaustive rather than illustrative.

**2. The count is a per-file gate, not a global one.** Each brief's gate is
`grep -c "\.system(size:" <its own files>` → **0**. The global number is just the sum; nobody has to
coordinate on it, and nobody can be blocked by someone else's progress.

**3. `@available(*, deprecated)` is the burn-down tracker.** WS-0 keeps `Module`, `DeckButton` and
`ToggleRow` compiling as thin wrappers over the new components, marked deprecated with a message
naming the replacement. Consequences, all of them useful:

- The tree **always compiles**, at every commit, in every wave. There is no big-bang rename.
- Every unconverted call site **announces itself** in the build log with a file and line.
- Progress is a single number: `swift build 2>&1 | grep -c "is deprecated"`. Each workstream records
  it at step 0.4 and must **strictly lower** it. It never has to go up.
- WS-9 deletes `DeckUI.swift` when the count reaches zero, and the count reaching zero is the
  *definition* of the migration being finished.

**4. A half-converted UI stays shippable — and here is why, specifically.** The nine type roles map
to macOS text styles whose default resolved sizes coincide with the sizes already in dominant use
(13 → `.body`, 12 → `.callout`, 11 → `.subheadline`, 10 → `.caption`). At the default text size a
converted row beside an unconverted one differs by tracking, not by a visible jump. At *larger* text
sizes the converted parts grow and the unconverted do not — which is more correct, not less, since the
unconverted parts do not scale at all today. Structurally: the component layer is additive, the legacy
names still work, and no wave leaves a destination in a state where it cannot be demoed.

**5. Preventing a workstream from inventing what already exists.** Four layers, in increasing
severity:

- The **"do not redefine" table** (§3.1) is pasted verbatim into every brief.
- Every brief's step 0 requires **reading the three component files in full** before writing a line.
  They are ~450 lines. This is cheap and it is the difference between knowing `ListRow` exists and
  guessing.
- A **mechanical gate**: `grep -cE "^(private )?struct .*(Row|Card|Tile|Header|Chip|Badge): View"`
  over the workstream's own files must be **0**, or exactly the names declared in its report's "new
  types I added, and why" line. A silent new `Row` type is a failed gate.
- The **escalation rule** from §0: needing something the layer lacks means *stop and report*, never
  *build a local one*. And the structural cause of the original divergence — "the type I need is
  `private` in a file I may not edit" — cannot recur, because nothing in the layer is `private` and
  `HubComponentTests` proves it at compile time.

### 7.3 The ten rows, mapped

| Row today | File:line | Becomes | Wave |
|---|---|---|---|
| `ToggleRow` | `DeckUI.swift:63` | `SettingsRow` | 0 (wrapper), 2 (call sites) |
| `StatusRow` | `SettingsPanel.swift:21` | `StatusRow` (new vocabulary) | 0 |
| `ProviderRow` | `SourcesTab.swift:68` | `SettingsRow` + `StatusRow` | 2 |
| `AgentProviderRow` | `PageDesignerView.swift:756` | **same** `SettingsRow` + `StatusRow` | 1 |
| `InstrumentRow` | `PageDesignerView.swift:704` | `ListRow` | 1 |
| `RoomRow` | `PageDesignerView.swift:901` | deleted — becomes `Menu` items | 1 |
| `ComplicationStackRow` | `ComplicationEditorView.swift:192` | `ListRow` / `SettingsRow` | 1 |
| `ResultRow` | `TickerEditorView.swift:191` | `ListRow` | 2 |
| `CurrentRow` | `TickerEditorView.swift:223` | `ListRow` | 2 |
| `WindowRow` | `HubPanel.swift:162` | shared figure + `LevelBar` | 2 |

The two that matter most — `ProviderRow` and `AgentProviderRow` — land in **different waves and
different files**, and both become the same component. WS-2 converts the Agents side in wave 1; WS-4
converts the Sources side in wave 2. Neither can see the other's file, and they still converge,
because they are both consuming a type neither of them wrote. That is the whole thesis of this plan,
and WS-9's convergence check is where it gets confirmed.

---

## 8. How visual change actually gets verified

### 8.1 What `ImageRenderer` can and cannot prove

`ImageRenderer` is available on macOS 13 and rasterizes a SwiftUI hierarchy into an `NSImage`.
It is **not** a screenshot of your app.

**It cannot prove:**

- **Anything inside a `ScrollView`.** There is no scroll host, so content is clipped to the proposed
  size, and `LazyVStack` / `LazyVGrid` children are **never materialized** — a real layout host is
  what asks a lazy container for its children. The AVAILABLE grid, the carousel strip, the ticker
  list and every settings pane body are all inside scroll views. Any assertion about them is void.
- **Anything drawn by AppKit.** `Toggle`, `TextField`, `Picker`, `ProgressView` and bordered `Button`s
  are `NSViewRepresentable`-backed; with no window to host the `NSView` they render as empty or
  placeholder rectangles (commonly a flat yellow box). Every row in this product has a control in it.
- **Vibrancy.** `NSPopover`'s material is a window-server effect. A rendered `HubPanel` composites
  over nothing, which is precisely the case §5's WS-6 trap 3 is worried about.
- **Taste.** Density, rhythm, whether the inspector still feels empty, whether the bezel reads as a
  screen. None of it.

**It can prove:** that a view builds, lays out without hanging, and produces a non-nil bitmap of the
expected size in both `.light` and `.dark` — a crash/hang smoke test. That is worth having and nothing
more. **And it may need a GUI session**: if any such test is added, gate it behind an environment
variable and keep it out of the default `swift test` path, because CI runs `swift test` on a
GitHub `macos-15` runner (`ci.yml:99`) and a hang there is worse than no test.

**Do not write a screenshot test and call the design verified.**

### 8.2 What *is* automatable, and has teeth

Three categories, all deterministic and all in the gates above:

1. **Pure-value tests.** Token invariants; **every `fill.*` resolving to different sRGB values under
   `.aqua` vs `.darkAqua`** (this mechanically catches the single-opacity bug behind all of design
   §7); **WCAG contrast ratios computed from resolved components** and asserted ≥ 4.5:1 for
   `ink.primary`/`ink.secondary` over `surface.content` and `fill.card` in both appearances;
   `SettingsClosePolicy` as a state machine including the comps-before-pages push order;
   `InspectorLayout.tier` for 0/1/2/3/8 options; `RowSeparator`'s derived inset;
   `CheckState → HubState` mapping. These are the tests that would go red if someone broke the thing.
2. **Mechanical source gates.** The `grep` blocks in each workstream. They cannot judge a layout, but
   they can prove that `underPageBackgroundColor` is gone, that `SonosRoomPopover` no longer exists,
   that no file outside the glass carries a raw font size, that nothing in the component layer is
   `private`, and that the deprecation count fell.
3. **The compile-time internal check** (`HubComponentTests`), which is the only automated defence
   against the exact failure in §0.

### 8.3 The human script — the only thing that judges the result

Run against a real `./build-app.sh run` build, **not** a preview. Save screenshots to
`/tmp/beacon-qa/<ws-id>/` and list the filenames in your report; the orchestrator opens them.

Do every item in **both** appearances (System Settings → Appearance → Light / Dark), at **820 × 560**
and at a wide window, and once with a **non-blue accent** (System Settings → Appearance → Accent →
Graphite or Yellow).

| # | Owner | Step | Expected |
|---|---|---|---|
| H1 | WS-1 | Open Settings | A source list on the left, five-or-four full labels, no centered pill bar anywhere |
| H2 | WS-1 | Click each destination | The **window title** changes to match; `⌘1`–`⌘4` do the same |
| H3 | WS-1 | Stage a page edit, then look at **Sources** | Dot on the **Pages** sidebar row *while Sources is selected*; dot in the window's close button |
| H4 | WS-1 | With edits staged, press `⌘W` | Sheet: Save & push / Discard / Cancel. Cancel keeps the window **and** the edits. Discard loses them. Save & push closes once, and does **not** re-present |
| H5 | WS-2 | Look at the Pages destination | One elastic column: strip above, hairline, grid below. **No grey band.** |
| H6 | WS-2 | Look at an enabled tile | Two text lines, a corner check. Not simultaneously the greenest and the faintest thing on screen |
| H7 | WS-2 | Click a carousel card | Selection ring appears **outside** the bezel; nothing moves by a pixel |
| H8 | WS-2 | Select **Sonos** | A native menu with disclosure and keyboard nav — **and the Sonos page's own preview filling the column below it.** This is complaint 2; if the column still reads as a lone dropdown in a lake, the workstream is not done |
| H9 | WS-2 | Select **Chart** with no instrument, then **ICE** | Chart: menu + preview. ICE (0 options): preview + one sentence, **no "No options" string** |
| H10 | WS-3 | Select **Home** | Six-slot editor legible at the 820 pt minimum; header does not wrap into itself; palette is a clean two columns |
| H11 | WS-4 | Compare **Sources** rows with the **Agents** page inspector | Same component, same size, same "Ready" treatment. Screenshot **both** in one image |
| H12 | WS-5 | Ticker editor: add, reorder, delete | Delete asks, naming the ticker. Icon buttons are hittable and VoiceOver-labelled |
| H13 | WS-6 | Open the **menu-bar popover** | Cards legible over vibrancy in both appearances; the big percentage does not clip at the largest text size; nothing blue that is not the accent |
| H14 | WS-7 | Look at any device preview | Space Grotesk / JetBrains Mono, bezelled, shadowed. No SF Symbol, no hub caveat text **inside** the glass |
| H15 | WS-8 | Toggle appearance **while the window is open** | Every fill re-resolves live; nothing stays light-tuned |
| H16 | WS-8 | System Settings → Accessibility → Display → Reduce motion | Reorder and scroll-to are instant |
| H17 | WS-9 | Set text size larger (Accessibility → Display) | Text grows; no row clips; no fixed-height box crops its label |

**H8 and H1 are the acceptance criteria for the owner's two named complaints.** They are not "nice
to confirm" — a wave-1 workstream that cannot produce those two screenshots has not finished, whatever
its gates say.

---

## 9. Rollback, per workstream

Every workstream lands as a **small number of commits on its own branch**, and every one of them is
independently revertable because file ownership is exclusive. The smallest useful revert:

| WS | Smallest revert | What the tree looks like after |
|---|---|---|
| WS-0 | Revert the one commit | Pre-existing UI, unchanged. Nothing consumes the layer yet — that is why it ships alone |
| WS-1 | Revert the one commit | Pill tab bar returns; WS-2/WS-3's re-laid-out Pages destination survives inside it. `contentMinSize` returns to 720 × 520 — **note this in the PR**, since WS-2 removed the 780 pt internal frame |
| WS-2 | Revert its commits | Sidebar survives with the old three-zone Pages layout. Tight at 820 pt but functional. Complaint 2 remains |
| WS-3 | Revert the one commit | Home's editor reverts to its wide layout inside a 260 pt column — visibly cramped, not broken. Ship only if WS-2 also reverted |
| WS-4/5/6 | Revert per file group | That surface returns to legacy components. Deprecation count rises; the tree still compiles. This is the whole point of the compat layer |
| WS-7 | Revert in two pieces: the font commit separately from the extraction commit | Fonts can be dropped (previews fall back to system faces) while keeping the extraction, or vice versa. Split them deliberately for exactly this reason |
| WS-8 | Revert the one commit | Previews lose their second scheme. No runtime change |
| WS-9 | Revert the deletion commit | `DeckUI.swift` returns. Harmless — it is dead code by then |

**A workstream that cannot be reverted without breaking another has violated file ownership**, and
that is itself a QA failure worth reporting.

---

## 10. Under-specified in the design — settle these before dispatch

Ten items a cold agent would otherwise have to guess. Ordered by how much damage a wrong guess does.

**10.1 — The device fonts do not exist in this repository.** Design §6.4 says they are "already in the
firmware's font pipeline." The *pipeline* is documented (`firmware/src/ui/fonts/MANIFEST.md`); what is
committed is **generated LVGL C bitmap arrays**, which CoreText cannot load. WS-7 must download the
OFL variable fonts from google/fonts, instance both to wght 500, and commit ~300–400 KB of binary
under `hub/Resources/fonts/` with each family's `OFL.txt`. **Decide before dispatch:** is committing
binary font assets to this public repo acceptable, and does the plan commit *instanced statics*
(smaller, matches the device exactly) or the *upstream variable fonts* (larger, no toolchain step)?
Lean: instanced statics, filenames preserved for the OFL Reserved Font Name clause.

**10.2 — Who adds `SettingsTab.firmware`?** Design §4.1 lists Firmware as a destination and §10 says
the test rename "anticipates" a fifth case, but never says which plan adds it. If WS-1 adds it with a
placeholder pane, it collides with the OTA plan's Phase 0, which creates
`FirmwareSettingsView.swift`. **Lean: this plan adds *only* the four existing cases**; the OTA
workstream adds the case and its view, and the sidebar picks it up with no edit because it is
`allCases`-driven. Consequence: WS-1 wires `⌘1`–`⌘4`, not `⌘1`–`⌘5`. Confirm.

**10.3 — Open question 1 in the design: flat five rows, or Firmware nested under Device?** The design
leans flat and the owner has settled on flat; recorded here because it is WS-1's sidebar shape and the
first decision the OTA Phase 0 owner hits. **Treated as settled — flat.** Flagged only so it is not
re-opened mid-wave.

**10.4 — `SettingsPanel.swift` has two claimants.** This plan's WS-0 deletes it. The OTA plan's
Phase 0 file table lists `hub/Sources/beacon-hub/SettingsPanel.swift` under its own ownership, and its
text places a Local Network `StatusRow` in "the existing Connection section
(`SettingsPanel.swift:52-64`)" — a section that has not lived there since the four-destination IA
landed; it is at `DeviceTab.swift:26`. Design §10 records the correction. **Needed before dispatch: a
handshake.** If OTA Phase 0 has not started, WS-0 deletes the file freely. If it has, WS-0 must instead
leave an empty stub and WS-9 deletes it later.

**10.5 — Can a Sonos room row carry a second field?** Design §3.4 requires that "every list row carries
at least two fields where a second field exists," and asserts player count and coordinator are
"derivable today" because the Control API's `groups` response carries `playerIds` and `coordinatorId`.
That is true of **the API** and false of **the hub's current seam**: `HubViewModel.onFetchSonosRooms`
delivers `SonosRoomListResult.rooms([String])` — **names only**. A two-field row therefore requires
changing `SonosProvider.fetchAvailableRooms`'s return type, `SonosAPI`'s parse, and the closure on
`HubViewModel` — three files WS-2 does not own, in provider code this plan deliberately excludes.
**Decide:** (a) widen the seam as a small pre-wave workstream with its own tests, (b) ship one-line
room rows in wave 1 and widen later, or (c) drop the two-field rule for rooms. Lean: **(b)**, with the
exception recorded in WS-2's report, because complaint 2 is about the selector being a hand-built fake
`Menu` in an empty column — not about the row's field count.

**10.6 — Does `NavigationSplitView` give a sidebar show/hide toggle on macOS 13 without a toolbar?**
Design §4.4 and §5.1 both lean on "the standard show/hide toggle comes free," and §5.1 makes it the
escape hatch for anyone below 820 pt. The Settings window today has no `NSToolbar` and a plain
`.titled` style mask. If the toggle does not appear, the options are: add a minimal `NSToolbar` with a
sidebar tracking separator (**a visible change to the title bar's look — a design decision, not an
implementation detail**), add an explicit toggle button, or accept no toggle in Phase 1. **This wants
a five-minute check before WS-1 is briefed**, because the answer changes WS-1's scope.

**10.7 — `type.figure` inside a 340 pt popover.** The only current 21 pt site is `HubPanel.WindowRow`
(`:175`), the big usage percentage. `type.figure` is `.title` bold ≈ 22 pt **and now scales with the
system text size**, inside a fixed-width popover holding two `ProviderCard`s side by side. Confirm the
intended behaviour: `minimumScaleFactor`, `lineLimit(1)`, or an explicit exemption for this one figure.

**10.8 — What sentence goes under the "What this page shows" preview?** Design §5.2.1 requires "one
`type.secondary` sentence describing what it renders," for tiers 0 and 1–2. `PageRow.detail` already
exists and is the catalog tile's caption ("Ticker list, live"). **Decide:** reuse `row.detail`, or
write seven new strings. Lean: **reuse `row.detail`** — one source of truth for what a page is, and it
is already user-facing.

**10.9 — The sidebar dot's colour.** §4.3 specifies a 6 pt `state.warn` dot; the settled decisions say
"system accent only, no signal orange in hub chrome." These do not actually conflict —
`state.warn` is `NSColor.systemOrange`, a *state* role, not the device's `#ff4a2b` — but a cold agent
will hesitate. One confirming sentence in WS-1's brief resolves it.

**10.10 — Pane gutters.** Four destination bodies use `.padding(20)`; the ladder's window gutter is
`space.xl` = **24**. Trivial, but it is a visible 4 pt shift across four files in one wave, and it is
worth saying out loud so nobody reports it as a regression.

---

## 11. WS-9 — convergence and done

**Sequential, after wave 3.** Files: `DeckUI.swift` (delete), `docs/codemap.md`, `docs/recipes.md`.

1. `swift build 2>&1 | grep -c "is deprecated"` must be **0**. Delete `DeckUI.swift`.
2. **Duplication sweep.** Grep the whole target for the six banned shapes — a second row type, a second
   status vocabulary, a second tile, a second badge, a raw font size outside the glass, a numeric
   corner radius outside `HubStyle.swift`. Any hit is a wave that quietly reinvented something, and it
   gets named in the report, not silently fixed.
3. **The `ProviderRow` / `AgentProviderRow` check, explicitly.** Screenshot the Sources destination
   and the Agents page inspector side by side. If they are not visually identical, this entire effort
   did not achieve its stated purpose and that finding outranks every green gate.
4. Run the full human script (§8.3) end to end, both appearances, both window sizes, one accent
   change, one text-size change.
5. Update `docs/codemap.md`'s concern→file index (`HubStyle.swift`, `HubRows.swift`,
   `HubSurfaces.swift`, `DeviceGlass.swift`, `SettingsCloseDecision.swift`, `InspectorTier.swift`;
   `SettingsPanel.swift` and `DeckUI.swift` removed) and its known-drift table. Add a
   `docs/recipes.md` recipe: **"add a hub surface"** — read the token file, pick from the component
   table, never declare a new row type, never write `.system(size:)`.
6. Final numbers for the report: total tests, `.system(size:)` in chrome (**target 0**), distinct
   corner radii (**target 2**), row implementations (**target 3**), status vocabularies
   (**target 1**), bundle size delta.

**Definition of done for the whole effort:** chrome carries **0** raw font sizes, **2** corner radii,
**3** row implementations, **1** status vocabulary, **0** deprecation warnings, hub tests ≥ 445, and
the owner has looked at H1 and H8 and agrees the two things they complained about are gone.
