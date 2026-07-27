# Hub app window, page manager, and home-screen complications

**Status:** design, not yet built. Written 2026-07-27; revised 2026-07-27 after owner decisions on four
open questions (§9 records which, and what moved).

**Authority:** `DESIGN.md` owns tokens + safe area; `hub/CONTRACT.md` owns the wire; `docs/tech.md` owns
budgets. This doc proposes one new frame (`comps`) and one firmware subsystem; the schema lands in
`CONTRACT.md` §A3 when implemented. Nothing here changes a frozen block.

Three requests that turn out to share one spine: **the hub is where you compose the device, and the device
is a registry the hub drives.** Page config (design 2026-07-26) built the first half. This builds the rest.

---

## 0. Bottom line — the three calls

| | Call | Why |
|---|---|---|
| **1. Window** | One real `NSWindow` with toolbar tabs, `frameAutosaveName`, folding the page designer in. It never auto-opens except on the very first launch after install; the "Don't open on startup" checkbox is deleted, not re-defaulted. | A checkbox that suppresses a behaviour nobody wants is a worse fix than removing the behaviour. A fresh install still needs to be told hooks are missing, so that guidance moves into the menubar popover where it does not steal focus. |
| **2. Page manager** | Enabled pages as a draggable carousel on top, every available page as a grid below, per-page options in a right-hand inspector. Settings splits into **Pages / Sources / Device / General** — *four* tiers, not two. | "Per-page options live with their page" is right for `chart.sym` and `sonos.room`. It is wrong for OAuth credentials and provider toggles: those keep acting on your Mac when the page is hidden. Those get a **Sources** tab and are *projected* into the page inspector, not moved there. |
| **3. Complications** | **6 slots** on Home at the existing 62 px pitch, the clock among them as a 2-slot complication, one instance per id, and a **standalone `comps` frame** (not page `opts`) so a complication edit applies **live, without the ~5 s restart**. | `PAGE_OPTS_LEN` is 48 B and `page_list_equal` compares opts, so riding `opts` would both overflow the bag and reboot the device on every drag. The `comps` frame is the *third instance* of the `rev`+list+ack+NVS pattern, not a parallel mechanism. |

---

## 1. Goals and non-goals

### Goals

- Settings is an ordinary Mac app window you open deliberately, not a popup that ambushes you at login.
- One window for everything the hub configures. The page designer stops being a second top-level window.
- A page manager that reads as *composition*: what the device could show, what it does show, in what order.
- Per-page configuration lives with its page wherever that is honest, and the doc says where it isn't.
- Any page can **register complications**: small renderers the user assigns to slots on the Home face.
- A complication edit is cheap — no reboot, no reflash, no lost carousel position.
- A tool-permission prompt is **never invisible**, whatever the page configuration.
- Old firmware against a new hub degrades quietly, exactly as unknown page ids already do.

### Non-goals (first cut)

- **Complications on any face but Home.** The wire is keyed by face id so a second host is additive, but
  only `home` exists.
- **User-authored complications.** Renderers are compiled in, like screens. Pushing layouts over BLE is a
  different (much worse) project — the 2026-07-26 design already settled that for pages.
- **Duplicate placement.** One instance per complication id (owner decision, §9). Consequences in §4.5.
- **A second size class beyond the clock's 2 slots in Phase 1.** `chart` (2 slots, sparkline) is in the
  registry and the resolution rules from day one, implemented in Phase 2.
- **Tappable complications.** Read-only in Phase 1; see §5.6. The prompt takeover is a separate, deliberate
  exception with its own full-screen hit targets.
- **Per-device layouts.** One Beacon exists; the store is global `UserDefaults`, same as `PageConfigStore`.
- **A device→hub registry report.** The hub mirrors the registry statically in Phase 1, exactly as
  `PageCatalog` mirrors `REGISTRY`. Phase 3 fixes that drift for both at once (§8).
- **Theme work.** `THEME_COUNT` is 1. Every renderer is one editorial implementation reading `theme_active()`
  tokens. Nothing here assumes a second theme, and nothing here blocks one.

---

## 2. Part 1 — Settings becomes an app window

### 2.1 What is wrong today

`SettingsWindowController.showIfNeeded()` runs from `applicationDidFinishLaunching` and opens the window
unless `BeaconFirstRunComplete` is set. `AppDelegate.maybeMarkComplete()` sets that key once Bluetooth,
pairing and hooks all pass — so the window keeps auto-opening for anyone whose device happens to be off, or
whose hooks were never installed, *every single launch*, calling `NSApp.activate(ignoringOtherApps:)` and
stealing focus. The "Don't open on startup" checkbox exists because that behaviour is annoying. The window
itself is `[.titled, .closable]` at a fixed `width: 460` with no resize, no minimise, no frame autosave, and
no restoration. It is a panel wearing a window's chrome.

Separately, `PageDesignerWindowController` is a *second* top-level window over the same view model, with its
own revert-on-close rule. Two windows, one settings surface.

### 2.2 The window

One `NSWindow`, one controller, four tabs.

- `styleMask = [.titled, .closable, .miniaturizable, .resizable]`.
- `frameAutosaveName = "BeaconSettingsWindow"` — position and size persist. A settings window that forgets
  where it was is the tell that it is not a real window.
- `contentMinSize` 720×520; the Pages tab needs the horizontal run.
- `isRestorable = true`, `isReleasedWhenClosed = false` (already true).
- Toolbar tabs via `NSToolbar` in the standard preferences idiom, or SwiftUI `TabView` hosted in the
  `NSHostingController` — either is fine; the toolbar reads more like a Mac app and gives each tab a title.
- Tab selection persists (`BeaconSettingsTab`), so reopening lands where you left.

**Tabs.** `Pages` · `Sources` · `Device` · `General`. Contents in §3.1.

**The page designer folds in** as the Pages tab. `PageDesignerWindowController` retires; its
`windowWillClose` revert moves to (a) window close and (b) leaving the Pages tab with a dirty list. Keeping
a staged edit alive across a tab switch is correct — the user may be in Sources adding the ticker the chart
wants — so the revert fires on close only, and the tab shows a dirty badge while staged edits exist.

### 2.3 Launch behaviour — the actual ask

- **No auto-open at launch.** `showIfNeeded()` becomes: open only if `BeaconDidAutoOpenSettings` has never
  been set, then set it. Exactly once, on the first launch after install, forever.
- **`BeaconFirstRunComplete` stops driving window presentation.** It becomes what its name says: a "setup has
  passed once" latch used only for the menubar hint.
- **The "Don't open on startup" checkbox is deleted.** There is nothing left to suppress, and a checkbox that
  controls a behaviour we just removed is dead UI. Design the window properly rather than flip a flag — the
  flag's job was to compensate for a design bug.
- **Replacement guidance:** when a provider has its buddy toggle on but hooks undetected, the menubar popover
  shows a row — `Claude hooks not installed · Set up` — that opens Settings on the Sources tab. Non-modal,
  no focus theft, and it survives the case the checkbox previously broke (a user who ticked "don't show me"
  and then genuinely needed setup).
- **Menubar menu** gains `Settings…`, and `⌘,` under the activation-policy call in §2.4.

### 2.4 What was considered and rejected

- **Keep the popover, widen it.** Rejected: the ask is explicit, and a popover cannot host a horizontal
  drag-and-drop carousel plus an inspector at any sane width.
- **Two windows (Settings + Pages), better behaved.** Rejected: the complication editor is *Home's page
  inspector*, so it must live where pages live; and the Sonos/provider settings must be reachable from both
  a page inspector and a global tab. One window makes that a projection instead of cross-window plumbing.
- **`SwiftUI.Settings` scene.** Rejected: it wants a `.regular` app, and it forces the preferences look
  (fixed-size, non-resizable per tab) which is exactly what we are getting away from.
- **Switch `NSApp.setActivationPolicy(.regular)` while the window is open, `.accessory` on close** — this is
  what buys a real menu bar, `⌘,`, `⌘W`, and proper window cycling; it costs a Dock icon that appears and
  vanishes. **Provisional call: take it** (§9.1) — *not yet confirmed by the owner.*

---

## 3. Part 2 — The page manager, and where every setting lives

### 3.1 The information-architecture problem

Today Settings is three flat sections — `Providers`, `Device pages`, `Sonos` — plus `Connection`, `Forget
device`, and a stray checkbox. The premise of the request is that provider and Sonos config are really
per-page config. That is **half true**, and the half that isn't matters.

Walk every setting and ask "if I hide this page, should this setting disappear?":

| Setting | Today | Page home? | Verdict |
|---|---|---|---|
| Chart instrument (`opts["sym"]`) | Page card | **Chart** | Genuinely per-page. Already is. |
| Sonos room (`opts["room"]`) | Page card | **Sonos** | Per-page *display*, but the hub's `SonosProvider` also polls by it (§3.5). |
| Provider `Usage` / `Coding buddy` toggles | Providers table | Agents *(partly)* | **No.** Coding-buddy-on holds real tool calls on your Mac for ~590 s whether or not any page shows them. Hiding the Agents page must not silently change what gates your shell. |
| Provider hooks install (`Set up`) | Providers table | Agents *(partly)* | **No.** It writes `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.omp/.../beacon.ts`. Machine state, not page state. |
| Sonos OAuth client id / secret / authorize | Sonos section | Sonos *(no)* | **No.** A Keychain credential, one per Mac, shared by any future Sonos surface. |
| Ticker list (16 rows) | Separate window | Markets? Chart? | **Neither** — two pages consume one list. It is a device-level resource. |
| Bluetooth / device connected / forget | Connection | — | Device-level. |
| Start at login, mute, window behaviour | Menubar / checkbox | — | App-level. |
| Theme, brightness, sleep, auto-rotate | On device | — | Device-owned (NVS), not hub-owned. Out of scope. |

So there are **four tiers**, and pretending there are two is what produces the current flat pile:

1. **Pages** — what the device shows, in what order, and each page's own `opts`.
2. **Sources** — the things that *produce* data: agent providers (toggles + hooks) and the Sonos account.
   A source keeps working when every page that renders it is hidden. That is the defining property.
3. **Device** — this Beacon: connection, pairing/forget, the ticker list, firmware version.
4. **General** — the hub app itself: login item, prompt sound, about.

**Resolution for the request's intent:** the page inspector shows the *relevant source's controls inline*.
Selecting the Agents page shows the provider rows; selecting Sonos shows connect/disconnect and the room
field. These are the **same** controls bound to the **same** store (`ProviderSettingsStore`,
`SonosSetupStore`) that the Sources tab renders — a projection, not a copy — with one line of honesty under
them: *"Also applies while this page is hidden."* You get the co-location the request asks for, without
inventing a rule where hiding a page disarms a permission gate.

### 3.2 The Pages tab

```
+----------------------------------------------------------------------------------+
| ON THE BEACON   (drag to reorder)                                 4 of 7 enabled  |
| +--------+  +--------+  +--------+  +--------+                                    |
| | [prev] |  | [prev] |  | [prev] |  | [prev] |    <- 150 px DevicePreview cards   |
| |  Home  |  | Chart  |  | Agents |  |Settings|       last one pinned              |
| +--------+  +--------+  +--------+  +--------+                                    |
+----------------------------------------------------------------------------------+
| AVAILABLE                                     |  HOME                             |
| +------+ +------+ +------+                    |  ------------------------------   |
| |Markets| | ICE  | |Sonos |   <- LazyVGrid    |  Complications  (6 slots)         |
| +------+ +------+ +------+      of the        |  [ slot editor, sections 4/5 ]    |
|                                 full catalog  |                                   |
+----------------------------------------------------------------------------------+
| * Pages changed - the Beacon restarts (~5 s)     [ Revert ]   [ Save & push ]     |
+----------------------------------------------------------------------------------+
```

- **Top carousel** = `model.pageRows.filter(\.enabled)` in device order. Each card is the existing
  `DevicePreview` at ~150 px plus title. Reordering is drag-and-drop within the strip.
- **Bottom grid** = the full `PageCatalog`, greyed where already enabled. Drag a card up into the carousel to
  enable it at that position; drag a carousel card down (or hit its `x`) to disable. `settings` is pinned:
  not draggable out, no remove affordance, `always on` chip — `PageLimits.alwaysID` already encodes this and
  the device force-appends it regardless, so showing it as removable would be a lie.
- **Inspector** (right) = the selected page's options. Chart keeps its instrument popover verbatim
  (`ChartInstrumentPopover` + the pure `ChartInstrumentSelection`); Sonos keeps its room field; Agents gets
  the projected provider rows; **Home gets the complication editor**. A page with nothing to configure says
  "No options" rather than showing an empty well.
- **Footer** keeps the staging model. It is correct: applying a page list reboots the device, so one
  deliberate `Save & push` beats a push per checkbox. See §10.3 for the two-status-line requirement.

### 3.3 Drag and drop

macOS 13 is the deployment target (the `onChange` single-parameter comment in `PageDesignerView` pins this),
so `.draggable(_:)` / `.dropDestination(for:)` are available and `NSItemProvider` is not needed. Payload is
the page id `String`. Two drop targets: the carousel (insert-at-index, with an insertion caret between
cards) and the available grid (= disable). The existing chevron `move(±1)` buttons stay as a keyboard/
accessibility path — drag-and-drop with no non-pointer equivalent is a regression, and they cost two
buttons. The complication slot editor uses the same two primitives, with slot wells as drop targets.

Reordering mutates `model.pageRows` and clears `model.pageSync`; nothing pushes until `Save & push`. That is
unchanged.

### 3.4 What has no page home

- **Bluetooth, device connected, forget/re-pair** → `Device` tab, with the existing
  `Open Bluetooth & forget` guidance (CoreBluetooth cannot remove an OS bond; that text stays).
- **Ticker list** → `Device` tab (**provisional**, §9.3). It is one list serving Markets *and* Chart; putting
  it inside either page's inspector makes the other page's dependency invisible. The Chart inspector keeps
  its picker, which can still *add* a row to the shared list (`ChartInstrumentSelection.addAndSet` already
  does), with a hint that it is adding to the device's ticker list.
- **Start at login** (`SMAppService`, honest `.requiresApproval` surfacing), **prompt mute**, **about /
  version** → `General`.
- **`TickerEditorWindowController`** folds into the Device tab the same way the page designer folds into
  Pages, leaving the hub with exactly one window.

### 3.5 The bug this surfaces

`HubViewModel.enabledPageOpts` filters on `$0.enabled`. `AppDelegate.applyPageEdit` then reads
`after.opts["sonos"]?["room"]` and calls `sonos?.setSelectedRoom(...)`. **Disable the Sonos page and the
hub stops knowing which room to follow** — the key is simply absent, so `setSelectedRoom` is never called and
the provider keeps whatever it had until the next launch, when the store reloads from a snapshot that no
longer carries it.

Today that is invisible (no page, no display). The moment a **Sonos complication can live on Home while the
Sonos page is hidden**, it is a dead complication. Fix: the room moves out of "opts of enabled pages" into
the Sonos **source** store, pushed to the provider on change regardless of page state. The room lives solely
in that store (`SonosRoomStore` / `SonosProvider.setSelectedRoom`) and never rides `opts` at all — there is
no mirror key, and the device's Sonos page header does not read one. This is required for §4.4 to hold, and
it is called out here rather than discovered during implementation.

---

## 4. Part 3 — Complications

### 4.1 The model

A **complication** is a named, compiled-in renderer that draws one page's worth of data into one or two
slots of a face. It is *provided by* a page (Apple's "apps provide complications") and *hosted by* a face.
Today there is one face: Home.

**The renderer contract is the view contract.** Because one complication may appear at most once (owner
decision, §9), a renderer owns file-static widget pointers exactly the way `home_editorial.cpp` and every
other view does — `{build, update}`, build creates, update mutates:

```c
typedef void (*comp_build_fn)(lv_obj_t* slot);   // slot = a transparent container sized to the span
typedef void (*comp_update_fn)(void);

typedef struct {
  const char*    id;         // wire id, <= 11 chars, [a-z0-9_-]
  const char*    owner;      // page id that provides it; "" for core. HUB METADATA -- never a gate.
  const char*    label;      // default display name (hub UI + on-device row label fallback)
  uint8_t        size;       // SLOT UNITS: 1 or 2. A static registry property (see below).
  bool           takes_arg;  // e.g. "fin" takes a ticker id
  comp_build_fn  build;
  comp_update_fn update;
} complication_t;
```

**`size` and per-instance state are different mechanisms — do not conflate them.** The owner's decision to
make the clock assignable requires *multi-slot spans*; the decision to forbid duplicate placement removes
*per-instance state*. These are independent:

- **Span** is a compile-time property of the complication, read from the registry. The resolver walks the
  assignment and advances its slot cursor by `def->size`. It stores nothing per placement beyond the id and
  its argument. A `clock` occupies slot positions *n* and *n+1*; that is arithmetic in the resolver, not
  state in the renderer.
- **Per-instance state** (the `comp_inst_t` an earlier draft carried) existed for exactly one purpose:
  letting `fin.sp500` and `fin.ynasdaq` coexist as two independently-parameterised placements. With one
  instance per id that purpose is gone, so the struct is **deleted**. Renderers are file-static, like views.

An argument still exists — it is just singular. A renderer reads it with `comp_arg(id, buf, cap)`, mirroring
`carousel_page_opt(page_id, key, buf, cap)`: one lookup against the active assignment, one value, no
allocation.

### 4.2 The Phase 1 registry

Every entry is backed by a record that **already exists in `records.h` and already flows**:

| id | owner page | size | data source | renders |
|---|---|---|---|---|
| `clock` | *(core)* | **2** | `now_s()` / RTC via `render_clock_ex` | hero-84 time + meridiem + date line |
| `fin` | `markets` | 1 | `ds_get_finance(i)` matched by `arg` (ticker id) | name / value / trend + % |
| `ice` | `ice` | 1 | `ds_get_ice()` front contract | `D4 RIN` / price / trend + % |
| `agents` | `agents` | 1 | `ds_get_buddy().sessions[0]` | icon + `project - title` / `state · age · +N more` |
| `usage` | `agents` | 1 | `ds_get_usage()` provider matched by `arg` (provider id) | `CLAUDE` / `24%` 5h + 7d bar |
| `weather` | *(core)* | 1 | `ds_get_weather()` | condition / temp / humidity |
| `sonos` | `sonos` | 1 | `ds_get_sonos()` | icon + `track` / `artist · room` |
| `chart` | `chart` | **2** | `ds_get_series()` matched by `arg` | value + 48-point sparkline — **Phase 2** |

The hub mirrors this as `ComplicationCatalog` in `BeaconHubKit`, exactly as `PageCatalog` mirrors `REGISTRY`
(with the same drift risk and the same Phase 3 cure, §8).

The face registry, likewise compiled in:

```c
typedef struct {
  const char* id;              // "home"
  const char* nvs_key;         // "c_home"   (NVS keys are <= 15 chars: "c_" + <= 11 fits)
  const char* default_slots;   // "clock,fin.sp500,ice,agents"  -- reproduces today's Home exactly
  uint8_t     slots;           // 6   (COMP_SLOTS_MAX)
} comp_face_t;
```

### 4.3 Resolution: assignment → renderer

`core/complications.{h,cpp}` is **pure and host-tested**, mirroring `page_config.cpp` — it takes the known-id
list and their sizes as parameters so it links into `env:native` with no LVGL:

```c
uint8_t comp_list_resolve(const comp_list_t* requested,
                          const char* const* known, const uint8_t* known_size, uint8_t known_count,
                          uint8_t slot_cap,                 /* 6 */
                          const comp_list_t* fallback,
                          comp_list_t* out);
```

Rules, mirroring `page_list_resolve` wherever the semantics are the same:

1. **An unknown id is dropped, not rejected**, and the remaining entries **compact upward**. Same as pages.
   A hole would be uglier than a shift, and "the thing I put in slot 3 moved up because slot 1's
   complication does not exist on this firmware" is the correct outcome.
2. **Duplicate ids collapse to the first occurrence, regardless of argument.** One instance per id, per the
   owner's decision. Unlike an earlier draft, a differing `arg` does *not* make a second placement legal —
   the second entry is dropped and the first entry's arg wins.
3. **An entry that does not fit the remaining slot units is dropped**, and the walk continues — a later
   1-slot entry may still fit where a 2-slot one did not. Dropped, not degraded: a hero-84 clock cannot
   render in a 60 px band, so silently shrinking it would produce a broken face rather than a smaller one.
   (`chart` may later opt into ROW degradation with a registry flag; the clock never will.)
4. **Over the total capacity truncates** — no `too_many` error. The hub already prevents it in the editor,
   and failing the whole frame would be worse than dropping the tail. The ack reports the applied count.
5. **An explicitly empty list is honoured.** This deliberately differs from `hub_parse_pages`, which rejects
   an empty `list` as malformed: an empty page list means an unusable device, while an empty slot list is a
   legitimate (if austere) face. With the clock now assignable this means Home can be reduced to its eyebrow
   and hub-status chip, so **the hub editor warns** ("Home will be blank") while still allowing it. The
   device distinguishes *explicitly empty* (`N == 0` on the wire) from *everything unknown* (`N > 0`,
   resolved to 0); only the latter falls back to `default_slots`.
6. **`owner` is never consulted.** The device does not know or care whether the owning page is enabled.
7. **The permission-prompt takeover pre-empts the whole stack** — see §4.6.

The stack builder (`ui/comps/comp_stack.cpp`) walks the resolved list, creates one transparent container per
placement at the §5 geometry (height `62 * size - 2`), and calls `def->build(slot)`. `comp_stack_update()`
runs from Home's `update()` at the existing 500 ms tick and calls `def->update()` per placement — so
complications inherit the idle-pause behaviour (#60) and the diff-aware `txt_set`/`txt_color` discipline for
free.

### 4.4 Can a complication show while its page is disabled?

**Yes, and it must** — a complication whose page you still have to keep is a pointless complication. What
that costs, per plane, checked against the code rather than assumed:

| Complication | Data path | Works with the owning page OFF? |
|---|---|---|
| `clock` | `now_s()` off the RTC/NTP. No page, no fetch. | **Yes, free.** |
| `fin` | `fetch_task.cpp` iterates `TICKER_BASE .. TICKER_BASE + ticker_table_count()`. **It never consults the page list.** | **Yes, free.** The fetch already happens. |
| `ice` | `SRC_ICE` is a fixed slot in the same loop. | **Yes, free.** |
| `weather` | `SRC_WEATHER`, likewise fixed. | **Yes, free.** |
| `agents`, `usage` | Hub pushes `usage`/`buddy`/`sessions` unconditionally into `DataStore`. | **Yes, free.** |
| `sonos` | Hub pushes the `sonos` frame — **but only for a room it was told to follow, and that room arrives via `enabledPageOpts`.** | **Only after the §3.5 fix.** |
| `chart` (Phase 2) | `resolve_chart()` reads `carousel_page_opt("chart","sym", …)`, which returns false when the page is not in the active list → falls back to compiled `CHART_TICKER_ID`. | **Only if the complication's own `arg` is consulted.** |

Two implications, both real work, neither optional:

- **§3.5 fix (Sonos room):** move room selection into the Sonos source store.
- **`resolve_chart()` must consider the complication assignment**, not just the page opt. Proposed precedence:
  the `chart` page's `opts["sym"]` when the page is enabled, else the `chart` complication's arg, else
  `CHART_TICKER_ID`. Only one series slot exists (`SRC_SERIES`), so **at most one instrument can have a live
  series** — which, with one-instance-per-id, is now enforced by construction rather than by a hub rule.

The general rule to write into `CONTRACT.md`: **a complication may only read a record the device already
maintains for reasons independent of the page list.** A complication must never be the thing that causes a
fetch. If it would be, it needs its own fetch slot designed under `docs/recipes.md` §6, and the complication
ships after that, not with it.

### 4.5 Arguments, and what one-instance-per-id costs

The wire entry is `id` or `id.arg`:

- `.` is the separator, chosen because `:` `;` `|` `=` `,` are exactly the characters the page-opts flattener
  strips — keeping the complication alphabet a subset of the opts alphabet means an assignment could later be
  carried in `opts` (or in NVS, or in a log line) with no re-escaping.
- `id` ≤ **11** chars, `[a-z0-9_-]`. `arg` ≤ **15** chars, `[a-z0-9_-]`. Any entry containing a character
  outside that set is dropped by both ends.
- Ticker ids already satisfy this: `TickerID.make` emits a source prefix plus lowercase Crockford base32,
  max 14 chars, and the compiled defaults are slugs like `sp500`. Provider ids are documented as "stable
  lowercase ascii, <= 12 chars" — **12 exceeds the 11-char id cap but fits the 15-char arg cap**, which is
  why `usage` takes the provider as an *arg* rather than minting `usage_claude` ids.

The charset restriction is load-bearing: it is why **character caps bound bytes** here (§6.2) and why the
`comps` frame needs none of the encode-measure-shrink machinery `SessionDetailsFrame`/`SonosFrame` carry.

**The cost of one instance per id**, stated plainly so it is not discovered later: Home can show exactly one
ticker, one usage provider, and (Phase 2) one sparkline. Today's Home shows one ticker, so this is not a
regression — but "S&P *and* Nasdaq on the home screen" is now unreachable without the Markets page. In
exchange the design loses an entire struct, and every renderer is byte-identical in shape to the views the
repo already has. That is the trade the owner took.

### 4.6 The permission-prompt takeover (Home)

`carousel_goto_buddy()` today resolves `agents` and **returns silently if the page is absent**. With Coding
Buddy on and the Agents page hidden, a `PermissionRequest` is held for ~590 s with nothing on the glass —
a silent stall on the one path that gates a shell command. Per the owner's decision this is fixed on the
device, not merely warned about in the hub:

- **When `buddy.prompt.present` and `agents` is not an active page, Home renders the prompt takeover instead
  of its slot stack.** Precedence on Home: takeover > stack. Nothing else pre-empts.
- The card is built **once in `build()`** and toggled with `hidden_set()` in `update()` — no object creation
  in `update()` (`views/CONVENTIONS.md`).
- The prompt card is **extracted from `buddy_editorial.cpp` into `views/prompt_card.h`** and shared, so there
  is one implementation of the Approve/Deny layout, its hit slop (`BUDDY_HIT_SLOP`, 24 px), the `(1 of N)`
  queue badge, and the expiry countdown.
- **Both surfaces call `buddy_decide()`** in `hub_task.cpp`, which is and stays the single canonical guard
  (`docs/recipes.md` §5: "Guard rails belong in the action function, not per-view"). There is no second
  decision path, so `PROMPT_PENDING` / `PROMPT_SENT_OK` / `PROMPT_TOO_LATE` behave identically.
- `carousel_goto_buddy()` gains a fallback: resolve `agents`, else `home`, else no-op. It keeps its
  wake-and-navigate contract. A tiny `carousel_has_page(id)` (exporting the existing `active_index_of`) is
  what Home's `update()` tests.
- **Permission prompts only.** A `question` session ("tap to answer on Mac") does *not* take Home over: no
  hook is held for it (`AskUserQuestion` is never held, `CONTRACT.md` §C.3), so there is no stall to fix, and
  a takeover for it would be pure noise. If `agents` is hidden, `question` state surfaces through the
  `agents` complication if one is placed, and nowhere otherwise.
- The hub keeps a **secondary** cue in the Pages tab — "Coding Buddy is on but the Agents page is hidden;
  prompts will appear on Home" — as information, no longer as the mitigation.

---

## 5. The slot layout — 466 × 466 with the ≥40 px inset

### 5.1 Ground truth

Panel 466 × 466. `SAFE_INSET` 40, `CORNER_R` 90 (`config/layout.h`). Content rectangle **386 × 386**, from
(40, 40) to (426, 426).

*Corner check.* The bottom-left arc centre is (90, 376); the content corner (40, 426) is
`sqrt(50² + 50²) = 70.7` px from it, against `R = 90` — **19.3 px inside the arc**, so a full-width row
ending at y = 426 does not clip. (`DESIGN.md` states the inset is safe up to R ≈ 96; the actual bound is
R ≤ 40√2/(√2−1) ≈ 136, so 90 has real margin. Not a reason to reduce the inset.)

*Fixed header band.* `build_header` puts the eyebrow at (40, 40) and the right-hand status slot at (426, 40),
both mono-15 → ink roughly y 40..56. It is on **every** screen and carries the hub-link state, the one thing
the user can act on. It is **not** assignable.

*Page-dot keep-out.* `carousel.cpp` aligns the dot bar `BOTTOM_MID, 0, -(SAFE_INSET - 22)` → the dots occupy
y ≈ 442..448 at the horizontal centre.

### 5.2 The row shape, measured off the shipped layout

From `home_editorial.cpp`, a row anchored at `a`:

| Element | y | Style |
|---|---|---|
| hairline rule | `a − 14` | `S.hairline`, 386 × 1 |
| name | `a + 4` | `S.slot`, mono 15 |
| value | `a − 4` | `S.display`, 30 |
| change % | `a + 26` | `S.slot`, mono 15 |
| trend glyph | aligned left of the % | lucide 14 (PUA — needs its own label) |

Shipped anchors are **192** (`SAFE_INSET+152`) and **254** (`SAFE_INSET+214`): pitch **62**. Bottom ink is
the mono-15 secondary line at `a + 26`, ending ≈ `a + 46`. So a row **occupies `[a−14, a+46]` = 60 px, with
2 px of clearance before the next rule.** That 2 px is the shipped clearance, not a target — it is why the
pitch cannot be tightened further without changing the type scale.

**One correction to the two-line shape.** The Claude block today puts line 2 at `SAFE_INSET+306` = `a + 30`,
giving it a 64 px span — 2 px *more* than the pitch. It gets away with it only because it is the last row.
As a complication it can sit anywhere, so **line 2 moves to `a + 26`**, matching the value row's secondary
baseline. Both shapes then occupy exactly `[a−14, a+46]`, and the face gains a consistent secondary-line
grid — better typography, and the reason a two-line complication in slot 3 does not clip slot 4's rule.

### 5.3 Slot count — the arithmetic

With the clock assignable (owner decision), the y 40..172 band it used to own permanently is now grid, and
the grid runs from just under the header to the inset.

Constraints, pitch fixed at 62 (owner decision):

- Slot *n* anchor: `a_n = a_1 + 62(n − 1)`.
- **Top:** slot 1 draws **no separator rule** (there is nothing above it to separate from, and a rule at
  `a_1 − 14` would land in the header band). Its topmost ink is the display-30 value at `a_1 − 4`, which must
  clear the header ink at ≈ 56 → `a_1 ≥ 60`.
- **Bottom:** `a_N + 46 ≤ 426` → `a_N ≤ 380`.

Solving for N: `a_1 + 62(N−1) ≤ 380` with `a_1 ≥ 60` → `62(N−1) ≤ 320` → `N ≤ 6.16`.

**N = 6.** Seven would need `a_7 = a_1 + 372 ≤ 380`, i.e. `a_1 ≤ 8` — far above the header. Six is the
ceiling, and the coordinator's `386 / 62 = 6.2` reading is confirmed by the exact constraint, not just the
division.

Now pick `a_1` so the grid **lands on the shipped anchors**. Slot 3 must be 192 → `a_1 = 192 − 124 = 68`:

> **Anchors: 68 · 130 · 192 · 254 · 316 · 378.**

Check every edge:

| Check | Value | Limit | |
|---|---|---|---|
| Slot 1 top ink (value row, no rule) | `68 − 4` = **64** | ≥ 60 (header ink ends ≈56) | ok, 8 px clear |
| Slot 3 anchor | **192** | shipped `SAFE_INSET+152` | **exact** |
| Slot 4 anchor | **254** | shipped `SAFE_INSET+214` | **exact** |
| Slot 5 anchor | **316** | shipped Claude anchor | **exact** |
| Slot 6 bottom ink | `378 + 46` = **424** | ≤ 426 | ok, 2 px |
| Slot 6 left end vs arc | (40, 424) → centre (90, 376): `sqrt(50²+48²)` = **69.3** | ≤ 90 | ok, 20.7 px inside |
| Slot 6 right end vs arc | (426, 424) → centre (376, 376): **69.3** | ≤ 90 | ok |
| Slot 6 bottom vs page dots | 424 vs 442 | — | 18 px gap |

```
 y=40   +--------------------------------------------------+  eyebrow / status   FIXED
 y=64   |                                                  |  SLOT 1  a= 68  (no rule)
 y=126  +--------------------------------------------------+  SLOT 2  a=130
 y=178  +--------------------------------------------------+  SLOT 3  a=192   <- shipped S&P
 y=240  +--------------------------------------------------+  SLOT 4  a=254   <- shipped D4 RIN
 y=302  +--------------------------------------------------+  SLOT 5  a=316   <- shipped Claude
 y=364  +--------------------------------------------------+  SLOT 6  a=378
 y=424  +--------------------------------------------------+
                              . . . .                          page dots, y 442-448
```

### 5.4 The clock as a 2-slot complication

`size = 2`, so it spans slot positions *n* and *n+1*: band `[a_n − 14, a_n + 108]`, drawable **386 × 122**.
Its content — hero-84 time, meridiem, and a mono-15 date line — measures 112 px in the shipped layout
(clock label top 58, date bottom ≈ 170).

Placed at slots 1–2 (`a_1 = 68`), a naive top-aligned render would put the hero at `68 − 4 = 64` and the date
at 156 — a **6 px downward shift** from today. Since the default assignment must be pixel-identical (§7), the
clock renderer carries a **−10 px optical offset** inside its band:

- hero label at `a − 10` = **58** — exactly today's `SAFE_INSET + 18`
- meridiem `lv_obj_align_to(OUT_RIGHT_BOTTOM, 8, −14)` off the hero, unchanged, so it follows
- date at `a + 82` = **150** — exactly today's `SAFE_INSET + 110`
- date bottom ≈ 170 ≤ `a_2 + 46` = 176 ✓

An optical offset inside a band is ordinary typography here: the hero face is a digits-only glyph subset with
large internal leading, so its label box is taller than its ink. The offset is a renderer constant, not a
grid exception — the grid stays uniform at 62.

If the clock is placed lower (say slots 3–4), the same offset applies and it reads correctly there too; the
only thing the offset encodes is "this face's ink starts high in its box".

### 5.5 What actually renders in 386 × 60

**Shape A — value row** (`fin`, `ice`, `weather`, `usage`):

| Element | Font | x | Budget |
|---|---|---|---|
| name | mono 15 (JetBrains Mono) | left, x = 40 | ~140 px (`S&P 500` ≈ 63 px, ~9 px/char) |
| value | display 30 (Space Grotesk) | right, x = 426 | ~200 px (`6,142.85`, 8 glyphs ≈ 17 px each ≈ 136 px) |
| change % | mono 15 | right, under the value | ~72 px (`+1.24%`) |
| trend glyph | lucide 14 | left of the % | 14 px + 6 gap |

140 + 200 = 340 of 386, with 46 px of gutter.

**Shape B — two-line row** (`agents`, `sonos`): 26 px icon column at x = 40; line 1 body-18
`LV_LABEL_LONG_DOT` at width 356 (~40 chars before the ellipsis); line 2 mono-15 dimmed at `a + 26`
(~38 chars).

**Not shape-able in 60 px:** a sparkline. `SERIES_MAX` is 48 points across 386 px = 8 px per point, and after
a 20 px label and an 8 px baseline you have ~30 px of vertical range — a squiggle, not a chart. Hence
`chart` is `size = 2`: band 122 px → 34 (name + value) + 8 gap + **68 sparkline** + 12 (lo/hi labels).

**Why not a 2×2 grid.** 193 px cells cannot hold a display-30 value plus label plus change on one line, and
the Agents complication is inherently full-width (already `LV_LABEL_LONG_DOT` at 356 px and truncating).
The rounded square also punishes grids: a 2×2's outer corners are the four places the arcs bite, while
full-width rows only put *ends* near arcs, at y-values where the arcs are shallowest.

### 5.6 Touch

`DESIGN.md` calls for ~64 px minimum touch targets at arm's length. A slot's pitch is 62 px, marginally
under, and up to six of them stack against each other separated by a hairline. Six adjacent 62 px targets on
a device you poke while holding a coffee is a mis-tap generator.

**Phase 1: complications are not tappable** (**provisional**, §9.2). The natural action — "show me the page
behind this" — is one swipe away and already exists.

The prompt takeover (§4.6) is the deliberate exception and is *not* affected by this: it replaces the whole
stack with two full-width Approve/Deny targets plus `BUDDY_HIT_SLOP`, which is the geometry that already
ships on the Agents page.

---

## 6. The wire format

### 6.1 The frame

Standalone, like `sessions` / `sdetail` / `sonos`. Additive on `"v":1`.

```json
{"v":1,"comps":{"rev":1,"slots":{"home":["clock","fin.sp500","ice","agents"]}}}
{"v":1,"cmd":"comps_ack","rev":1,"ok":true,"count":4}
{"v":1,"cmd":"comps_ack","rev":1,"ok":false,"err":"malformed"}
```

- `rev` — monotonic hub counter (uint32), echoed in the ack. A stale ack (for a rev the user has since edited
  past) is ignored, exactly as `pagesAck`/`configAck` already are in `AppDelegate.handle`.
- `slots` is keyed by **face id** so a second host face is additive with no frame change and no version bump.
  An unknown face key is dropped — the same rule as an unknown page id, one level up.
- Each array entry is `id` or `id.arg` (§4.5). `count` in the ack is the number of **placements** applied,
  not slot units — 4 placements can occupy 5 slots when one of them is the clock.
- `err` ∈ {`malformed`}. There is deliberately no `too_many_slots`: over-cap truncates (§4.3 rule 4).
- Device → hub uses the existing `cmd` channel (`DeviceCommand.compsAck`), not the prompt-id `ack` — same
  choice `config_ack` and `pages_ack` made.

The frame above **is** the default assignment, and it measures **80 B** (`sortedKeys` + trailing `0x0A`):
7 + 9 + 8 + 9 + 8 + 8 + 12 + 6 + 8 + 1 + 3 + 1.

### 6.2 Worst case against the 1024 B ceiling

Caps: faces ≤ **2**, slots per face ≤ **6** (`COMP_SLOTS_MAX`), face id ≤ **11**, entry ≤ **27**
(`11 + '.' + 15`). Charset `[a-z0-9_-]` plus the `.` separator — **no character in the alphabet is
JSON-escapable**, so 1 char = 1 byte and character caps bound bytes exactly. This is the reason `comps`
needs none of the encode-measure-shrink loop `SessionDetailsFrame`/`SonosFrame` carry: those fields are
free-form human text where one `"` costs 2 bytes, an emoji 4, and a ZWJ grapheme cluster 25.

Worst case is **6 one-slot entries per face** (the clock's `size` 2 reduces the entry count, so it can only
make the frame *shorter* — the byte bound is set by placement count, not slot units):

| Part | Bytes |
|---|---|
| `{"v":1,` | 7 |
| `"comps":{` | 9 |
| `"rev":4294967295,` (uint32 max, 10 digits) | 17 |
| `"slots":{` | 9 |
| per face: `"` + 11 + `":[` | 15 |
| per face: 6 × (`"` + 27 + `"`) | 174 |
| per face: 5 separating commas | 5 |
| per face: `]` | 1 |
| **face subtotal** | **195** |
| 2 faces + 1 joining comma | 391 |
| `}}}` | 3 |
| trailing `0x0A` | 1 |
| **TOTAL** | **437 B** |

**437 of 1024 = 42.7 %.** Single-face worst case (the only shape that exists today) is **241 B**; the
realistic default is **80 B**. No chunking — and, like the `pages` frame, if `comps` ever outgrows the
ceiling it chunks exactly as §B2 does; nothing here forecloses that. The ack is ~62 B.

Headroom: the ceiling is reached at roughly `entries × 29 > 950`, i.e. ~32 placements — with 6 slots per
face, about 5 faces. There is no realistic path to overflow.

NVS blob, per face, worst case: `6 × 27 + 5 commas + NUL` = **168 B** under key `c_home`.

### 6.3 Why a standalone frame and not `pages` `opts`

Riding `opts` is the obvious move — the plumbing is end to end, `chart.sym` and `sonos.room` prove it, and
the instruction is to prefer it. Two hard blockers:

1. **`PAGE_OPTS_LEN` is 48 bytes**, and `hub_parse_pages` truncates the flattened `k:v;k:v` string at that
   boundary, keeping whatever fit. Six assignments with real ticker ids need ~140 chars. Carrying
   complications in `opts` means growing `PAGE_OPTS_LEN` past 160, which more than triples the per-page
   static array (8 × 48 = 384 B → 8 × 160 = 1280 B) and changes the NVS blob format for every user.
2. **`page_list_equal` compares ids *and* opts**, and any difference sets `changed` → `nvs_set_bytes` →
   `pages_ack` → **`ESP.restart()`**. Dragging a complication would reboot the device. That is the single
   worst outcome available: ~5 s of black screen, a dropped BLE link, a lost carousel position, and an ack
   race, per drag, on the most-edited surface in the product.

A standalone frame is not a parallel mechanism — it is the **third instance of the same pattern**
(`rev` + list + device-side NVS + `*_ack` + idempotent re-push on reconnect) that `config` established and
`pages` copied. The 2026-07-26 design's own argument applies verbatim: *"Page config should be a second
instance of this exact pattern, not a new mechanism."* This is the third.

### 6.4 Back-compat

| Situation | Behaviour |
|---|---|
| Old firmware, new hub sends `comps` | `hub_task.on_frame()` finds no known key and drops the frame, exactly as it drops `sessions`/`sdetail`/`sonos` on older builds. Home renders its compiled layout. No error, no version bump. |
| New firmware, old hub (never sends `comps`) | NVS `c_home` absent → `default_slots` → Home renders exactly as today. |
| New hub names a complication this firmware lacks | Dropped, remaining entries compact. Same rule as unknown page ids. |
| New hub names a **face** this firmware lacks | The whole face key is dropped; other faces apply. |
| New hub places a 2-slot complication this firmware knows as 1-slot (or vice versa) | The **device's** registry size wins. The hub's slot preview may disagree until Phase 3's device report; the device is always right. |
| Assignment resolves to zero entries **from a non-empty request** | Fall back to `default_slots` — never an accidental blank face. |
| Assignment is **explicitly empty** (`[]`) | Honoured: eyebrow-only face. The hub warns before sending it. |
| Complication's owning page is disabled | Kept and rendered (§4.4). `owner` is hub metadata only. |
| Duplicate id (any arg) | Collapses to the first; the first entry's arg wins. |
| Entry with an out-of-alphabet character | Dropped (both ends validate). |

Upstream (`angaziz/beacon`) merge safety: `comps` is additive and ignorable, same discipline as `sdetail`.

### 6.5 Why this does **not** restart the device

`carousel_apply_pages` restarts because rebuilding the pager's children means creating and destroying
top-level page objects under a live scroll. A complication change touches **one container's children on one
page**.

The precedent is already in the tree: `on_theme()` does `lv_obj_clean(s_pages[i])` + `chrome_attach` +
`MODULES[i]->build(...)` + `update()` for **every page**, live, while the carousel is showing one of them,
driven from a settings tap via `lv_async_call`. Rebuilding one page's slot stack is strictly less than an
operation the firmware already performs on demand.

```
hub_task (Core 0)  hub_parse_comps -> comp_list_resolve -> nvs_set_bytes("c_home")
                   -> comp_pending_set(&resolved)      [mutex-guarded holder, DataStore discipline]
                   -> hub_build_comps_ack -> send       (link stays up; the ack is reliable, unlike pages')
carousel tick_cb   if (comp_pending() && !s_settling)   [Core 1, LVGL thread, 500 ms]
(Core 1)             comp_stack_apply(): lv_obj_clean(stack_root); rebuild; update()
```

Guards: apply only from the LVGL timer (never from Core 0), never while `s_settling` (the recenter guard
already exists), and no-op when the resolved list equals the active one — the hub re-pushes on every
reconnect, so idempotence matters here for the same reason it does for pages, just with a cheaper failure
(a flicker, not a boot loop).

**If the live rebuild proves flaky on hardware**, the fallback is to reuse the page path and restart. That
would be a real regression in feel, so it is the first thing to verify on device (§8 Phase 1 exit criteria).

---

## 7. Migration

**The default assignment, spelled out.** `comp_face_t.default_slots` for `home` is:

```
"clock,fin.sp500,ice,agents"
```

Resolved against the 6-slot grid:

| Slot(s) | Placement | Anchor | Renders at | Matches shipped |
|---|---|---|---|---|
| 1–2 | `clock` (size 2) | 68 | hero at `68−10` = **58**, date at `68+82` = **150** | `SAFE_INSET+18` / `SAFE_INSET+110` ✓ |
| 3 | `fin.sp500` | **192** | rule 178, name 196, value 188, pct 218 | `SAFE_INSET+152` ✓ |
| 4 | `ice` | **254** | rule 240, … | `SAFE_INSET+214` ✓ |
| 5 | `agents` | **316** | rule 302, icon 320, line1 316, line2 **342** | `SAFE_INSET+262/+280/+276`; line 2 moves 346 → 342 (§5.2) |
| 6 | *(empty)* | 378 | nothing drawn — no rule, no placeholder | today's unused band ✓ |

**Pixel-identical to today** with one intentional 4 px change: the Claude block's second line moves from
`a+30` to `a+26` so both row shapes share a secondary baseline and a two-line complication can sit anywhere
in the stack without clipping the next rule (§5.2). Everything else lands on the shipped coordinate.

`home_editorial.cpp` becomes a thin host — `build_header` + `comp_stack_build(page)` + the hidden prompt card
— and its `market_row`/`market_put`/Claude-block bodies move verbatim into `comp_fin`, `comp_ice`,
`comp_agents`, with `render_clock_ex` wrapped by `comp_clock`. This is a **pixel-preserving refactor**, and
`env:capture` gives a before/after diff that proves it (§11).

**Existing device.** NVS gains one key (`c_home`); nothing existing is rewritten. Absent key → the default
above. The `sp500` lookup keeps today's semantics, including `"not in list"` when the hub has pushed a
ticker list without it (`finance_by_id` already handles that).

**Existing hub.** `ComplicationStore` starts pristine (`BeaconCompRev` absent → rev 0). `pushCompConfig()`
no-ops while pristine, exactly as `pushPageConfig()` does — an untouched hub never pushes, so nobody's Home
changes until they open the editor and save. The first save writes `BeaconCompSlots` and bumps to rev 1.

**Stored page config is untouched.** `BeaconPageIDs` / `BeaconPageRev` / `BeaconPageOpts` keep their meaning
and format. The one semantic change is §3.5: the Sonos room's *source of truth* moves to the Sonos source
store. Migration: on first launch of the new build, if `BeaconPageOpts["sonos"]["room"]` exists and the
Sonos source store has no room, copy it across. One-shot, keyed by a `BeaconSonosRoomMigrated` flag; the
page opt keeps being written so an older hub build reading the same defaults still works.

**Push order on `central.onReady`:** tickers → **comps** → pages. Comps before pages so that, in the rare
case the page push restarts the device, the complication blob is already persisted and the device boots
correct. Both converge either way (the device persists on receipt), but this ordering avoids a needless
second round-trip.

---

## 8. Phasing

**Phase 1 — the window, the page manager, complications, and the prompt takeover.** Shippable alone; it is
the whole user-visible ask minus sparklines.

- Settings window: tabs, autosave, no auto-open, checkbox removed, menubar setup hint, designer folded in.
- Pages tab: carousel + grid + drag-and-drop + inspector.
- Firmware: `core/complications.{h,cpp}` (pure), `ui/comps/` registry + stack + seven renderers (`clock`,
  `fin`, `ice`, `agents`, `usage`, `weather`, `sonos`), `hub_parse_comps` / `hub_build_comps_ack`, NVS
  `c_home`, live apply, the §5.2 two-line baseline fix.
- Firmware: prompt card extracted to `views/prompt_card.h`; Home takeover; `carousel_has_page`;
  `carousel_goto_buddy` falls back to Home (§4.6).
- Hub: `ComplicationCatalog`, `CompsFrame`, `ComplicationStore`, the Home inspector's slot editor.
- Wire: `CONTRACT.md` §A3.
- **Exit criteria:**
  1. Dragging a complication re-renders Home within one 500 ms tick with no reboot, no dropped BLE link, and
     no change to `int_min` in the 10 s heap log.
  2. `env:capture` of Home with the default assignment is pixel-identical to the pre-change capture except
     the 4 px line-2 move.
  3. With Coding Buddy on and the Agents page disabled, a `PermissionRequest` surfaces on Home within the
     wake path, and Approve/Deny routes through `buddy_decide` with a truthful ack.

  If the live rebuild is not clean on hardware, stop and reconsider §6.5 before shipping — a reboot-per-drag
  product is worse than no feature.

**Phase 2 — the `chart` sparkline.** The 2-slot chart complication, the `resolve_chart()` precedence change
from §4.4, and the "one series slot" constraint surfaced in the hub editor (which one-instance-per-id now
enforces structurally).

**Phase 3 — device-reported registry, and tap-to-jump if §9.2 resolves that way.**
`cmd:"report","what":"comps"` reusing the §B3 one-way chunked report machinery verbatim, so the hub renders
only complications the connected firmware actually carries — **and their real sizes**, which is the one
back-compat gap §6.4 currently resolves in the device's favour. This is the same cure `PageCatalog` needs;
do both in one change and delete a row from `docs/codemap.md` §6's drift table.

Deliberately unscheduled: a second face, user-authored renderers, per-device layouts.

---

## 9. Open questions

**Settled by the owner on 2026-07-27** (recorded here because the rest of the doc is downstream of them):
slot geometry stays at **62 px pitch**; the **clock is an assignable complication**, not a fixed face
element; **one instance per id** (so `comp_inst_t` is gone and renderers look like views); and a
**permission prompt takes over Home** when the Agents page is disabled — the hub warning is a secondary cue,
not the fix.

Still open. For each, this doc now carries **a provisional call so it is actionable** — provisional means
*implemented as written unless the owner says otherwise*, not *decided*.

1. **Activation policy.** Switch `NSApp.setActivationPolicy(.regular)` while the Settings window is open and
   back to `.accessory` on close? It buys a real menu bar, `⌘,`, `⌘W`, and proper window cycling; it costs a
   Dock icon that appears and disappears.
   **Provisional: take it.** *Not yet confirmed by the owner.*
2. **Tappable complications.** Tap → jump to the owning page? §5.6 argues no on mis-tap grounds at 62 px
   pitch, and it raises a follow-on: tapping a complication whose page is *disabled* would either do nothing
   (confusing) or enable the page, which means a tap on the glass triggers a reboot.
   **Provisional: not tappable in Phase 1; revisit in Phase 3 alongside the device registry report.**
   *Not yet confirmed by the owner.*
3. **Ticker-list location.** Device tab (one list, two consuming pages) versus duplicating the editor into
   both the Markets and Chart inspectors.
   **Provisional: Device tab**, with the Chart inspector keeping its add-a-symbol picker and a hint that it
   writes to the device's shared list. *Not yet confirmed by the owner.*
4. **Page-vs-app naming.** Apple's model is *apps provide complications*, and the request cites it. "Page" is
   what the wire, the firmware, `PageCatalog`, `page_config.h` and every existing doc say. Renaming only the
   user-facing noun is a drift generator; renaming both is a wide change across two languages and a frozen
   wire field.
   **Provisional: keep "page" everywhere.** *Not yet confirmed by the owner.*

---

## 10. Risks

### 10.1 The live rebuild is the load-bearing assumption *(biggest risk)*

Everything good about §6.3 — no reboot, no dropped link, a reliable ack, a fluid editor — rests on
`lv_obj_clean(stack_root)` + rebuild being safe from `tick_cb`. The evidence is strong (`on_theme()` already
does strictly more, live), but it has never been done *from the tick timer* while the carousel is scrolling,
and LVGL 8.4 will happily let you delete an object that is mid-animation or mid-event. Mitigations: apply
only from the LVGL thread, gate on `!s_settling`, no-op on an identical list, and treat the exit criteria in
§8 as a gate rather than a nice-to-have. If it fails, the feature degrades to the page path (restart per
edit) and the design's main UX claim goes with it — so find out in week one, not week three.

### 10.2 Memory — 6 populated slots, with numbers

The instinct is that going from 3 populated rows to as many as 6 on the most-viewed page threatens the
internal-heap watermark. **It does not, and the reason is mechanical:** `lv_conf.h` sets `LV_MEM_CUSTOM 1`
with `LV_MEM_CUSTOM_ALLOC = lvm_alloc`, and `lvm_alloc` is a straight
`heap_caps_malloc(size, MALLOC_CAP_SPIRAM)` passthrough — **not a fixed pool**. Every `lv_obj_create` /
`lv_label_create` on the device allocates from PSRAM. The draw buffer is in PSRAM too
(`BEACON_LVGL_PSRAM`). No LVGL widget has ever touched internal SRAM in this build.

**Per-slot LVGL cost (PSRAM).** LVGL 8.4 with this config: `lv_obj_t` ≈ 36 B; `lv_label_t` ≈ 68 B (with
`LV_LABEL_LONG_TXT_HINT 1`); plus a 2-entry style array ≈ 16 B, the label's copied text block ≈ 24 B, and
ESP-IDF allocator headers/alignment. Call it **~150 B per label, ~100 B per plain object**.

| Placement | Objects | PSRAM |
|---|---|---|
| Value row (`fin`, `ice`, `weather`, `usage`) | container + rule + 4 labels | ~800 B |
| Two-line row (`agents`, `sonos`) | container + rule + icon + 2 labels | ~650 B |
| Clock (2 slots) | container + 3 labels | ~600 B |
| Hidden prompt card (built once, always resident) | ~6 objects | ~600 B |

Rounding generously to **~1 KB per occupied slot**:

| | LVGL objects | PSRAM |
|---|---|---|
| Home today (clock + 2 rows + Claude block) | ~17 | ~3.5 KB |
| Home with **6 populated slots** + prompt card | ~34 | **~6.6 KB** |
| **Delta** | +17 | **+3.1 KB** |

Against **8.29 MB PSRAM free** that is **0.08 %**. Complications are not a PSRAM story either; they are a
rounding error in it.

**Internal SRAM — the number that actually matters.** Observed `int_min` is **46,428 B** (below both the
~53 KB `tech.md` §2 claims and perf.md's 49,832 B — that drift should be corrected in perf.md separately;
this design budgets against the *lowest* observed figure). This design's internal-SRAM cost:

| Item | Region | Bytes |
|---|---|---|
| `COMP_REGISTRY[]` (`static const`) | flash `.rodata` | **0** internal |
| Active assignment `char[6][28]` + count | `.bss` | 176 |
| Pending assignment holder (live apply) | `.bss` | 176 |
| Renderer file statics (~8 renderers × 6 `lv_obj_t*`) | `.bss` | ~192 |
| Pending-holder mutex (`xSemaphoreCreateMutex`) | internal heap | ~80 |
| **Static/persistent total** | | **~0.62 KB** |
| `hub_parse_comps` `JsonDocument`, ≤437 B frame | hub task, transient | ~1 KB |

**Verdict: 6 populated slots is safe.** The persistent internal-SRAM delta is **~0.62 KB — 1.3 % of the
46,428 B observed minimum**. The transient parse allocation is ~1 KB, and it is *not a new class*: the hub
task already builds a `JsonDocument` for `hub_parse_status` on every 30 s heartbeat and for
`hub_parse_pages` on every reconnect, both against larger frames.

**What actually caps the slot count, since memory doesn't.** To threaten `int_min` you would need ~46 KB of
new *internal* allocation, i.e. roughly 75 times this design's total footprint — unreachable, because the
widgets are in PSRAM. **The binding cap is geometry: 6, derived in §5.3**, backed up by one-instance-per-id
(§4.5), which caps distinct placements at the size of the catalog.

**One correction to an earlier draft:** the "at most one chart-bearing complication" cap was justified there
on memory grounds. That was wrong. Two `lv_chart`s with 48 points cost ~1 KB of PSRAM between them. The real
constraint is that **`fetch_task` has exactly one `SRC_SERIES` slot**, so only one instrument can carry a
live intraday series — a data constraint, and with one-instance-per-id it is now enforced by construction
rather than by a rule anyone has to remember.

### 10.3 Restart amplification

A single `Save & push` that changes both the page list *and* the complication assignment still reboots (the
page frame does). The footer must distinguish them — "Pages changed · the Beacon restarts (~5 s)" versus
"Complications updated · applies immediately" — or users will learn that the editor sometimes reboots for no
visible reason and stop trusting it.

### 10.4 Registry / catalog drift

`ComplicationCatalog` (Swift) must match `COMP_REGISTRY` (C++) — **now including each entry's `size`**, since
the hub's slot editor previews spans it cannot verify. No compiler checks it; this is the exact failure
`PageCatalog` already carries, and the same class that produced the `symbol`/`sym` investigation on
2026-07-26. Mitigations: a firmware host test asserting registry ids, sizes and `takes_arg`; a hub test
asserting the catalog against a checked-in fixture; §6.4's rule that the device's size always wins; and
Phase 3's device report, which removes the mirror entirely.

### 10.5 The prompt takeover replaces the most-glanced page

Decision 4 closes the silent-stall hole, and it should — a held tool call with nothing on the glass is not a
UX wrinkle, it is a stall on the shell. The residual risk is the inverse: Home is the page the device sits
on all day, and a full-screen Approve/Deny card now pre-empts it whenever the Agents page is hidden. Two
containments: the takeover fires **only** when `agents` is genuinely absent from the active list (a user who
keeps the Agents page never sees it), and it fires **only** for permission prompts, never for `question`
state (§4.6). The 590 s device-side expiry (`BUDDY_PROMPT_EXPIRY_S`) and the ~2 s confirm hold already bound
how long it can sit there, and both are unchanged.

Second-order: `carousel_goto_buddy()` now navigates to Home in this configuration, so a wake-on-prompt lands
on Home rather than doing nothing. Anything else that assumes that function means "the agents page" must be
re-read — today its only callers are the prompt wake path.

### 10.6 Frame and cap creep

437 B of 1024 leaves room, but the caps are the guarantee, not the current usage. `COMP_SLOTS_MAX` (6), the
face cap (2), and the id/arg alphabet must be asserted in `test_hub_proto` against a synthetic worst case —
the same discipline `sdetail` and `sonos` documented after `sessions` nearly overran.

### 10.7 An unexpected character silently drops a complication

Charset validation is what makes §6.2's byte bound exact, but a dropped entry is invisible unless someone
reports it. The hub must validate at the editor boundary and refuse to *store* an out-of-alphabet arg, so
the device-side drop is a defence rather than the first line.

### 10.8 A blank Home is now reachable

With the clock assignable and empty lists honoured (§4.3 rule 5), a user can configure Home down to its
eyebrow. That is their right, but it reads as a broken device. The hub editor warns before sending an empty
assignment, and the on-device fallback still catches the *accidental* blank (an all-unknown list). Nothing
recovers an intentional one except editing it back — which is fine, because Settings is always reachable
(`PageLimits.alwaysID`).

---

## 11. Verification

**Firmware (`env:native`, Unity).**

- `test_comp_list` — resolve: unknown-id drop + compact, **duplicate id collapse regardless of arg**,
  2-slot entry dropped when only 1 unit remains while a later 1-slot entry still places, over-capacity
  truncation, explicit-empty honoured, all-unknown falls back, serialize/deserialize round-trip including a
  corrupt blob, and **the default string resolving to slots 1–2/3/4/5 with slot 6 free**.
- `test_hub_proto` — `hub_parse_comps` happy path, absent-`comps` frame ignored, malformed `v`, unknown face
  dropped, out-of-alphabet entry dropped, and a **synthetic worst-case frame asserted < 1024 B** (6 entries
  × 2 faces = 437 B).
- Idempotence: applying the identical list twice sets no pending flag.

**Hub (XCTest).**

- `CompsFrame` round-trip and `sortedKeys` + trailing `0x0A` framing; `fitsFrame()` at the documented caps.
- `ComplicationCatalog` vs a checked-in registry fixture, **including sizes**.
- Editor rules: 6-unit capacity with the clock counting as 2, one-instance-per-id enforcement, arg
  validation, the blank-Home warning.
- `ComplicationStore` pristine → no push; rev bumps only on a real change.

**On hardware (no substitute).** The §8 exit criteria, plus `env:capture` of Home at 1, 2, 4 and 6 occupied
slots to confirm slot 6's bottom ink lands at 424 and nothing enters a corner arc — and a
default-assignment capture diffed against the pre-change build to prove the refactor is pixel-preserving.
