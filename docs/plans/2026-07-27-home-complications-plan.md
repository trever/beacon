# Phase 1 implementation plan — hub app window, page manager, Home complications

**Status:** plan, not yet executed. Written 2026-07-27.

**Source of truth:** `docs/specs/2026-07-27-hub-app-and-home-complications-design.md`. That document is
decision-complete; this one only says *who builds what, in what order, and how we prove it*. Where the
design carries a provisional answer (§9.1–9.4), this plan implements it as written and marks where a
different answer changes the work.

**Companion rules this plan must obey:** `AGENTS.md`/`CLAUDE.md` (conventions, doc locations),
`docs/recipes.md` §1/§4/§5/§8 (checklists), `firmware/src/ui/screens/views/CONVENTIONS.md` (view
contract, LVGL 8.4 do/don't), `hub/CONTRACT.md` (frozen wire), `docs/codemap.md` (concern => file).

**How this is executed:** parallel subagents, one git worktree each, one brief per workstream. Every
workstream section below is written to be lifted verbatim into a brief. Read your own section and
Phase 0's "What the parallel workstreams import" table; you do not need the rest.

**Out of scope for every workstream here:** OTA. Do not touch
`docs/specs/2026-07-27-ota-updates-design.md` or write anything OTA-related.

---

## 1. Reality check — four places the design is ahead of, or behind, the tree

Verified against the working tree at `54366a7`. Read this before believing any "current state" claim in
the design doc.

| # | Design says | Tree actually does | What that changes |
|---|---|---|---|
| 1 | §3.5 is a live bug: `enabledPageOpts` filters by `enabled`, so a disabled Sonos page strips the room; §4.4 says the `sonos` complication needs the fix first; §7 wants a `BeaconSonosRoomMigrated` one-shot. | **Already fixed.** `SonosRoomStore.swift` exists; `HubViewModel.onLoadSonosRoom`/`onSetSonosRoom` are wired to `SonosProvider.setSelectedRoom`; `AppDelegate.applyPageEdit` carries an explicit comment saying it deliberately no longer reads `after.opts["sonos"]["room"]`; `PageDesignerView.selectRoom` applies immediately. The room never rides `opts` at all any more — there is not even a mirror key. | **Delete this work item.** The `sonos` complication needs no prerequisite. Do not write a `BeaconSonosRoomMigrated` migration — there is no page-opts room to migrate *from*. Add one regression test (WS-3) that a page save with the Sonos page disabled leaves `BeaconSonosSelectedRoom` intact, so this cannot silently regress. Confirmed by the owner 2026-07-27: this was fixed earlier the same day, after the design was written. |
| 2 | §4.4 says the device's Sonos page header reads `opts["room"]` as a mirror. | No `opts["room"]` is written by the hub any more — there is not even a mirror key. | Nothing to build. **WS-4 corrects that sentence in the design doc** — the owner has authorized this single factual correction (§10 step 6). If the device's Sonos page header currently shows nothing until a `sonos` frame lands, that is pre-existing and out of scope. |
| 3 | Doc counts: `docs/codemap.md` §1 says 33 firmware suites / 204 cases and 216 hub cases; `docs/recipes.md` §0 says 29 suites / 185 cases and 204 hub cases. | **36 firmware suites / 257 `RUN_TEST` cases; 362 hub test functions.** | The floors in this plan are 257 / 362. WS-4 updates both docs. |
| 4 | §10.2 notes `docs/perf.md` claims `int_min` 49,832 B against an observed 46,428 B. | Unverified here. | Out of scope. Do not "fix" `docs/perf.md` in this work; WS-4 may note it, nothing more. |

---

## 2. Sequencing

The one rule that makes this dispatchable: **anything more than one workstream must touch belongs to
Phase 0.** Phase 0 is sequential and lands before any fan-out. The parallel workstreams *import* Phase 0's
types and **must not redefine, re-declare, or "improve" them** — if a parallel workstream believes a Phase
0 type is wrong, it stops and reports rather than forking it.

| Order | Workstream | Runs | Depends on |
|---|---|---|---|
| **0** | **WS-0 — wire + substrate** (two ordered steps, one owner) | **alone, first** | — |
| 1 | **WS-1 — firmware: complication stack, renderers, Home refactor, prompt takeover, live apply** | parallel | WS-0 |
| 1 | **WS-2 — hub: the app window and the four-tab IA** | parallel | WS-0 |
| 1 | **WS-3 — hub: Pages tab, drag-and-drop, inspector, complication slot editor** | parallel | WS-0 |
| 2 | **WS-4 — convergence, hardware gate, docs** | alone, last | WS-1, WS-2, WS-3 |

Forced orderings, stated so nobody discovers them at merge time:

- The firmware parser (`hub_parse_comps`) and the hub encoder (`CompsFrame`) must agree byte for byte.
  **Both live in WS-0**, so they cannot diverge. Neither WS-1 nor WS-3 writes wire code.
- The `home_editorial.cpp` refactor must land before renderers can be extracted — they are the *same*
  change (the row bodies move out of that file into the renderers), so both are WS-1 and there is no
  intermediate state where one exists without the other.
- WS-1 cannot compile `-e beacon` without WS-0's headers; WS-3 cannot compile without WS-0's
  `Complications.swift`. Both are satisfied by WS-0 landing first.
- WS-2 and WS-3 are disjoint by file, not by feature: WS-2 owns the window and tab *shells*, WS-3 owns
  the Pages tab *content*. The seam between them is frozen in §5.
- `AppDelegate.swift`, `HubViewModel.swift`, `MenubarController.swift` and `Protocol.swift` are contested
  god-files. **WS-0 makes every change any workstream needs in them.** WS-1/2/3 must not edit them at all
  except where §5/§6 explicitly names a line.

---

## 3. WS-0 — wire + substrate (sequential, one owner)

### Goal

Ship the `comps` wire schema, the pure resolver, the active-assignment holder, both codecs, the hub-side
store and app plumbing, and the `CONTRACT.md` entry — with tests, and with **no UI and no renderers**. When
this lands, the device can receive, validate, resolve, persist and ack a `comps` frame and simply not draw
it yet; the hub can store, encode and push one. Everything downstream is presentation.

Do it in two ordered steps. Step 0a is firmware-core + `BeaconHubKit`; step 0b is the hub app. 0b needs
0a's Swift types.

### Files to create

**Firmware**

- `firmware/src/core/complications.h`
- `firmware/src/core/complications.cpp`
- `firmware/src/core/comp_state.h`
- `firmware/src/core/comp_state.cpp`
- `firmware/src/ui/comps/comp_registry.h` — **header only**, no `.cpp`. WS-1 writes the `.cpp`.
- `firmware/src/ui/comps/comp_stack.h` — **header only**, no `.cpp`. WS-1 writes the `.cpp`.
- `firmware/test/test_comp_list/test_main.cpp`

**Hub**

- `hub/Sources/BeaconHubKit/Complications.swift`
- `hub/Sources/beacon-hub/ComplicationStore.swift`
- `hub/Tests/BeaconHubKitTests/ComplicationsTests.swift`
- `hub/Tests/beacon-hubTests/ComplicationStoreTests.swift`

### Files to edit

- `firmware/src/core/hub_proto.h` / `.cpp` — add `hub_parse_comps` + `hub_build_comps_ack`.
- `firmware/platformio.ini` — `[env:native] build_src_filter` gains `+<core/complications.cpp>` and
  `+<core/comp_state.cpp>`. **Forgetting this is the classic "undefined symbol" in a new suite**
  (`docs/codemap.md` §5).
- `firmware/test/test_hub_proto/test_main.cpp` — parse tests + the worst-case byte assertion.
- `firmware/src/ui/carousel.h` / `.cpp` — add **only** `bool carousel_has_page(const char* id);`, a
  three-line export of the existing `static int active_index_of(...)`. Touch nothing else in this file;
  WS-1 owns the rest of it afterwards.
- `hub/Sources/BeaconHubKit/Protocol.swift` — `DeviceCommand.compsAck(rev:ok:count:err:)` + its `parse`
  branch, modelled exactly on `.pagesAck`.
- `hub/Tests/BeaconHubKitTests/ProtocolTests.swift` — round-trip + malformed cases for `compsAck`.
- `hub/Sources/beacon-hub/HubViewModel.swift` — the published complication state and intent closures (§3.4).
- `hub/Sources/beacon-hub/MenubarController.swift` — `setComps(_:)` / `setCompSync(_:)` setters, mirroring
  `setPages` / `setPageSync`.
- `hub/Sources/beacon-hub/AppDelegate.swift` — `compStore`, `pushCompConfig()`, `applyCompEdit(_:)`, the
  `.compsAck` case in `handle(_:)`, the `central.onReady` push order, **and** the launch-behaviour change
  (§3.5). This is the only workstream that edits `AppDelegate.swift`.
- `hub/CONTRACT.md` — new **§A3**, placed after §A2.

### Files NOT to touch

`firmware/src/ui/screens/views/**` (all of it), `firmware/src/ui/comps/*.cpp`, `firmware/src/core/hub_task.cpp`,
`firmware/src/core/page_config.*`, `hub/Sources/beacon-hub/SettingsPanel.swift`,
`SettingsWindowController.swift`, `PageDesignerView.swift`, `PageDesignerWindowController.swift`,
`TickerEditorView.swift`, `TickerEditorWindowController.swift`, `DevicePreview.swift`, `main.swift`,
`hub/Sources/BeaconHubKit/PageConfig.swift`, `docs/specs/**`.

### What to build

**1. `core/complications.h` — the pure contract.** Freestanding C (no LVGL, no Arduino), mirroring
`core/page_config.h` in shape so a reader who knows one knows the other.

```c
#define COMP_SLOTS_MAX   6     // per face; the geometry cap derived in design 5.3
#define COMP_FACES_MAX   2     // wire cap; only "home" exists
#define COMP_ID_LEN     12     // 11 chars + NUL
#define COMP_ARG_LEN    16     // 15 chars + NUL
#define COMP_ENTRY_LEN  28     // "id.arg" = 11 + 1 + 15 + NUL

typedef struct {
  char    ids [COMP_SLOTS_MAX][COMP_ID_LEN];
  char    args[COMP_SLOTS_MAX][COMP_ARG_LEN];
  uint8_t count;               // PLACEMENTS, not slot units
} comp_list_t;

// Static, LVGL-free mirror of what this firmware can draw. THE single source of truth for size and
// takes_arg on the device; ui/comps/comp_registry.cpp reads size/takes_arg from HERE, never re-states
// them, so the two cannot drift.
typedef struct { const char* id; uint8_t size; bool takes_arg; } comp_def_t;
extern const comp_def_t COMP_CATALOG[];
extern const uint8_t    COMP_CATALOG_N;

bool comp_entry_valid(const char* id, const char* arg);   // charset + length, both ends
bool comp_entry_split(const char* entry, char* id, size_t id_cap, char* arg, size_t arg_cap);
bool comp_list_equal(const comp_list_t* a, const comp_list_t* b);

uint8_t comp_list_resolve(const comp_list_t* requested,
                          const char* const* known, const uint8_t* known_size, uint8_t known_count,
                          uint8_t slot_cap,               /* COMP_SLOTS_MAX */
                          bool requested_was_explicit_empty,
                          const comp_list_t* fallback,
                          comp_list_t* out);

size_t comp_list_serialize(const comp_list_t* l, char* buf, size_t cap);   // "clock,fin.sp500,ice"
void   comp_list_deserialize(const char* s, comp_list_t* out);
```

`COMP_CATALOG` contents, exactly (design §4.2). `chart` is present from day one in the catalog and the
resolution rules; **its renderer is Phase 2**, so WS-1 will not register a `chart` renderer and
`comp_find("chart")` returns `NULL` on the device — the resolver drops it, which is the correct Phase 1
behaviour.

| id | size | takes_arg |
|---|---|---|
| `clock` | 2 | false |
| `fin` | 1 | true |
| `ice` | 1 | false |
| `agents` | 1 | false |
| `usage` | 1 | true |
| `weather` | 1 | false |
| `sonos` | 1 | false |
| `chart` | 2 | true |

Resolution rules, verbatim from design §4.3 — do not re-derive them:

1. Unknown id dropped, remaining entries **compact upward**.
2. Duplicate ids collapse to the **first** occurrence **regardless of arg**; the first entry's arg wins.
3. An entry that does not fit the remaining slot units is **dropped**, and the walk **continues** — a later
   1-slot entry may still place where a 2-slot one did not. Never degraded to a smaller size.
4. Over capacity truncates. There is no `too_many` error.
5. An **explicitly empty** request (`N == 0` on the wire) is honoured and resolves to 0 placements. A
   **non-empty** request that resolves to 0 falls back to `fallback`. This is why `resolve` takes an
   explicit `requested_was_explicit_empty` flag — do not infer it from `requested->count`, because a
   request of 3 unknown ids also arrives with a resolved count of 0 and must behave differently.
6. `owner` is never consulted. The device does not know whether the owning page is enabled.
7. An entry whose id or arg fails `comp_entry_valid` is dropped.

Charset: `id` ≤ 11 chars from `[a-z0-9_-]`; `arg` ≤ 15 chars from `[a-z0-9_-]`; `.` separates them and
appears nowhere else. **No character in that alphabet is JSON-escapable**, which is the entire reason
character caps bound bytes and the frame needs none of `SessionDetailsFrame`'s encode-measure-shrink loop.

**2. `core/comp_state.{h,cpp}` — the active/pending holder.** Mutex-guarded, LVGL-free, host-linkable. Use
`core/ds_lock.h` (`std::mutex` on native, FreeRTOS on device) — that is exactly what it exists for; do not
write a second wrapper.

```c
void comp_state_set_active (const comp_list_t* l);        // boot: from NVS or the default
bool comp_state_active     (comp_list_t* out);            // by-value snapshot, DataStore discipline
void comp_state_set_pending(const comp_list_t* l);        // hub task (Core 0) writes
bool comp_state_take_pending(comp_list_t* out);           // LVGL tick (Core 1) reads-and-clears
bool comp_arg(const char* id, char* out, size_t cap);     // mirrors carousel_page_opt(); one lookup
```

`comp_state.cpp` does **no** NVS and **no** LVGL — same split as `page_config.cpp`. NVS lives in
`carousel.cpp` (WS-1).

The face table also lives here (design §4.2), so the default string has exactly one home:

```c
typedef struct { const char* id; const char* nvs_key; const char* default_slots; uint8_t slots; } comp_face_t;
// { "home", "c_home", "clock,fin.sp500,ice,agents", COMP_SLOTS_MAX }
```

`c_home` is 6 chars — inside the 15-char NVS key limit.

**3. `ui/comps/comp_registry.h` — the renderer contract and the geometry, header only.**

```c
typedef void (*comp_build_fn)(lv_obj_t* slot);   // slot = transparent container, already sized/placed
typedef void (*comp_update_fn)(void);

// size/takes_arg deliberately absent: they live in COMP_CATALOG and nowhere else.
typedef struct {
  const char*    id;
  const char*    owner;    // page id that provides it; "" for core. HUB METADATA -- never a gate.
  const char*    label;
  comp_build_fn  build;
  comp_update_fn update;
} complication_t;

extern const complication_t COMP_REGISTRY[];
extern const uint8_t        COMP_REGISTRY_N;
const complication_t* comp_find(const char* id);   // NULL when this firmware has no renderer
```

Plus the geometry constants, which are the contract every renderer aligns against:

```c
#define COMP_SLOT_PITCH   62
#define COMP_SLOT_A1      68     // anchors: 68 130 192 254 316 378
#define COMP_BAND_TOP_DY (-14)   // container top, relative to the anchor
static inline int comp_slot_anchor(uint8_t n) { return COMP_SLOT_A1 + COMP_SLOT_PITCH * (n - 1); }  // n = 1..6
```

Container-local element offsets (absolute y minus container top; see §7 for the derivation and the proof
they reproduce the shipped pixels):

| Element | Local y | Local x | Style |
|---|---|---|---|
| separator rule (386 x 1) | 0 | 0 | `S.hairline` |
| shape-A name | 18 | 0 (`TOP_LEFT`) | `S.slot` |
| shape-A value | 10 | 0 (`TOP_RIGHT`) | `S.display` |
| shape-A change % | 40 | 0 (`TOP_RIGHT`) | `S.slot` |
| shape-A trend glyph | — | `align_to(pct, OUT_LEFT_MID, -6, 0)` | `t->f_icon` |
| shape-B icon | 18 | 0 | `t->f_icon` |
| shape-B line 1 | 14 | 26, width 356, `LONG_DOT` | `S.body` |
| shape-B line 2 | 40 | 26, width 356, `LONG_DOT` | `S.slot` |
| clock hero | 4 | 0 | `S.hero` |
| clock meridiem | — | `align_to(hero, OUT_RIGHT_BOTTOM, 8, -14)` | `S.slot` |
| clock date | 96 | 0 | `S.slot` |

**4. `ui/comps/comp_stack.h` — the stack contract, header only.**

```c
void comp_stack_build (lv_obj_t* page);   // called from a view's build(); creates the root + containers
void comp_stack_update(void);             // called from a view's update(); calls def->update() per placement
bool comp_stack_apply (void);             // LVGL thread only: take pending, clean, rebuild. true if rebuilt
void comp_stack_set_hidden(bool on);      // prompt takeover hides the whole stack
```

**5. `hub_parse_comps` / `hub_build_comps_ack` in `core/hub_proto.{h,cpp}`.** Signatures modelled on
`hub_parse_pages` / `hub_build_pages_ack`:

```c
data_err_t hub_parse_comps(const char* json, size_t len, uint32_t* rev,
                           const char* face_id, comp_list_t* out, bool* explicit_empty,
                           const char** err_out);
size_t hub_build_comps_ack(char* buf, size_t cap, uint32_t rev, bool ok, const char* err, int count);
```

- `err` ∈ `{"malformed"}` only. There is deliberately no `too_many_slots`.
- An unknown **face** key is dropped; other faces apply. Asking for a face the frame does not carry returns
  `ERR_PARSE`/`"malformed"`? **No** — it returns `ERR_NONE` with `*out` empty and `*explicit_empty=false`,
  and the caller does nothing. Say so in the header comment; this is the one place the pages analogy breaks.
- `count` in the ack is **placements applied**, not slot units. 4 placements can occupy 5 slots.

**6. `hub/CONTRACT.md` §A3.** Document the frame, the ack, every cap, the charset, the back-compat table
(design §6.4 verbatim), the "no restart" property, and the general rule from §4.4:

> A complication may only read a record the device already maintains for reasons independent of the page
> list. A complication must never be the thing that causes a fetch.

**7. `BeaconHubKit/Complications.swift`.**

```swift
public enum CompLimits {
    public static let slotsPerFace = 6
    public static let maxFaces     = 2
    public static let idMax        = 11
    public static let argMax       = 15
    public static let frameMaxBytes = 1024        // HUB_FRAME_MAX
    public static let homeFace     = "home"
    public static let allowed      = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
}
public struct ComplicationCatalogEntry { id, owner, label, size, takesArg, detail }
public enum ComplicationCatalog { public static let all: [ComplicationCatalogEntry] /* the 8 rows above */ }
public struct CompPlacement: Equatable { public let id: String; public let arg: String?
    public init?(_ wire: String)      // parse + validate; nil on out-of-alphabet
    public var wire: String { arg.map { "\(id).\($0)" } ?? id } }
public struct CompsFrame: Codable {   // {"v":1,"comps":{"rev":R,"slots":{"home":[...]}}}
    public init(rev: Int, slots: [String: [CompPlacement]])   // normalizes: dedupe by id, cap slot units
    public func encoded() throws -> Data   // JSONEncoder(.sortedKeys) + trailing 0x0A
    public func fitsFrame() -> Bool }
```

`CompsFrame.init` normalizes at the wire boundary the same way `PagesFrame.init` does, so the device never
has to defend against the hub: one instance per id (first wins), slot-unit capacity honoured using the
catalog's `size`, out-of-alphabet entries refused.

**8. `beacon-hub/ComplicationStore.swift`.** `UserDefaults`, keys `BeaconCompRev` and `BeaconCompSlots`
(`[String: [String]]`, face id => wire strings). Mirrors `PageConfigStore` exactly:

- `isPristine` when `BeaconCompSlots` is absent. `current.rev == 0` while pristine.
- `frame()` returns `nil` while `rev == 0` — **an untouched hub never pushes**, which is the whole of the
  migration promise in design §7.
- `set(slots:)` bumps the rev **only on a real change**.

**9. `AppDelegate` plumbing.**

- `pushCompConfig()` — guard `central.isConnected`, guard `compStore.frame()`, guard `fitsFrame()`, send.
- `applyCompEdit(_ slots: [String: [String]])` — persist, bump, mirror to the view model, push. Unlike
  `applyPageEdit` it must **not** print restart wording.
- `.compsAck` in `handle(_:)` — ignore a stale rev exactly as `.pagesAck`/`.configAck` do, then
  `menubar.setCompSync("Updated \(count) complications.")` / the error string.
- `central.onReady` push order becomes **tickers → comps → pages** (design §7). Comps before pages so that
  if the page push restarts the device, the complication blob is already persisted.

**10. Launch behaviour (design §2.3), the AppDelegate half.** `showIfNeeded()` becomes: open only if
`BeaconDidAutoOpenSettings` has never been set, then set it — once per install, forever.
`BeaconFirstRunComplete` stops driving window presentation and becomes a latch used only by the menubar
hint. Extract the decision as a pure function so it is testable:

```swift
enum SettingsLaunch { static func shouldAutoOpen(didAutoOpen: Bool) -> Bool { !didAutoOpen } }
```

WS-2 owns the window itself and the deleted checkbox; WS-0 owns only this gate and the key.

### What it can assume already exists

`page_config.{h,cpp}` (the shape to mirror), `hub_parse_pages`/`hub_build_pages_ack` (the codec to mirror),
`PagesFrame`/`PageConfigStore` (the Swift shape to mirror), `ds_lock.h`, `nvs_get_bytes`/`nvs_set_bytes`,
`DeviceCommand.pagesAck` (the ack case to mirror), `HubAck`. The Sonos room fix (§1 item 1) is **done** —
do not re-do it.

### Acceptance gate

```bash
cd /path/to/worktree/firmware && ~/.beacon-pio/bin/pio test -e native
cd /path/to/worktree/firmware && ~/.beacon-pio/bin/pio run -e beacon
cd /path/to/worktree/hub && swift build && swift test
```

- `pio test -e native`: **≥ 283** cases (257 baseline + ≥26 new). New suite `test_comp_list` must cover, one
  test each: unknown-id drop + compact; duplicate id collapse **with differing args**; a 2-slot entry
  dropped when 1 unit remains **while a later 1-slot entry still places**; over-capacity truncation;
  explicit-empty honoured; all-unknown falls back to the default; serialize/deserialize round-trip; a
  corrupt/garbage blob deserializing to something resolvable rather than crashing; out-of-alphabet entry
  dropped; and **the default string `clock,fin.sp500,ice,agents` resolving to slots 1–2 / 3 / 4 / 5 with
  slot 6 free**. `test_hub_proto` additions: happy path, absent-`comps` frame ignored, malformed `v`,
  unknown face dropped, out-of-alphabet entry dropped, ack bytes, and **a synthetic worst-case frame
  asserted `< 1024` (6 entries × 2 faces = 437 B)**.
- `pio run -e beacon`: **SUCCESS**. Always pass `-e beacon`; a bare `pio run` also builds `[env:native]`,
  which has no `main()` and always reports `FAILED`.
- `swift test`: **≥ 384** cases (362 baseline + ≥22 new), covering `CompsFrame` round-trip and
  `sortedKeys` + trailing `0x0A` framing, `fitsFrame()` at the documented caps, `CompPlacement` parse/
  reject, the catalog vs a checked-in fixture **including sizes**, `compsAck` parse + malformed, store
  pristine => no push, rev bumps only on a real change, and `SettingsLaunch.shouldAutoOpen`.

### Traps

- **`platformio.ini` `build_src_filter`.** A new non-header `src/` file that is not listed there will not
  link into any test binary. This is the usual "undefined symbol" (`docs/codemap.md` §5).
- **`hub_parse_comps` must be dispatched before the loc/status fall-through** when WS-1 wires it — say so
  in the header comment. `on_frame` swallows unrecognized frames into `hub_parse_status`.
- **Emit-only-when-set semantics in Swift.** A property the wire omits when unset must be `Optional` and
  `nil`, never `false` — synthesized `Codable` omits `nil` but encodes `false` (see `ProviderUsage.stale`).
- **ASCII only** in firmware source and comments (`=>`, not the arrow glyph).
- **No force-unwraps outside tests** in hub code.
- **`comp_list_resolve` must not consult `owner`.** It is hub metadata. A resolver that checks whether the
  owning page is enabled defeats the entire feature.
- The **device's registry size always wins** over the hub's preview (design §6.4). Do not add a wire field
  for size; Phase 3's device report fixes the mirror.

### Rollback

Revert the whole worktree. Nothing else depends on WS-0 until WS-1/2/3 exist, and every change is additive
except the two `AppDelegate` behaviours (push order, `showIfNeeded`), which revert cleanly on their own.

### What the parallel workstreams import (do not redefine)

| Symbol | Owner | Used by |
|---|---|---|
| `comp_list_t`, `COMP_SLOTS_MAX`, `COMP_ID_LEN`, `COMP_ARG_LEN`, `COMP_ENTRY_LEN` | `core/complications.h` | WS-1 |
| `COMP_CATALOG` / `comp_def_t` (the **only** home of `size` and `takes_arg`) | `core/complications.cpp` | WS-1 |
| `comp_list_resolve`, `comp_list_serialize/deserialize`, `comp_list_equal`, `comp_entry_valid/split` | `core/complications.cpp` | WS-1 |
| `comp_state_*`, `comp_arg`, `comp_face_t` | `core/comp_state.h` | WS-1 |
| `complication_t`, `comp_find`, `COMP_SLOT_PITCH/A1`, `comp_slot_anchor`, the local-offset table | `ui/comps/comp_registry.h` | WS-1 |
| `comp_stack_build/update/apply/set_hidden` | `ui/comps/comp_stack.h` | WS-1 |
| `hub_parse_comps`, `hub_build_comps_ack` | `core/hub_proto.h` | WS-1 |
| `carousel_has_page` | `ui/carousel.h` | WS-1 |
| `CompLimits`, `ComplicationCatalog`, `CompPlacement`, `CompsFrame` | `BeaconHubKit/Complications.swift` | WS-3 |
| `ComplicationStore` | `beacon-hub/ComplicationStore.swift` | WS-3 |
| `HubViewModel.compSlots/appliedCompSlots/compSync/compsDirty/onApplyComps/onRevertComps` | `HubViewModel.swift` | WS-3 |
| `SettingsLaunch.shouldAutoOpen`, `BeaconDidAutoOpenSettings` | `AppDelegate.swift` | WS-2 |

---

## 4. WS-1 — firmware: stack, renderers, Home refactor, prompt takeover, live apply

### Goal

Home stops being a hand-laid page and becomes a host: `build_header` + `comp_stack_build(page)` + a hidden
prompt card. Seven renderers exist. A `comps` frame from the hub persists to NVS, acks, and re-renders Home
**within one 500 ms tick with no reboot**. With Coding Buddy on and the Agents page hidden, a permission
prompt takes Home over. The default assignment is **pixel-identical to today** except one intentional 4 px
move.

### Files to create

- `firmware/src/ui/comps/comp_registry.cpp` — the `COMP_REGISTRY[]` array and `comp_find`.
- `firmware/src/ui/comps/comp_stack.cpp`
- `firmware/src/ui/comps/comp_clock.cpp`
- `firmware/src/ui/comps/comp_fin.cpp`
- `firmware/src/ui/comps/comp_ice.cpp`
- `firmware/src/ui/comps/comp_agents.cpp`
- `firmware/src/ui/comps/comp_usage.cpp`
- `firmware/src/ui/comps/comp_weather.cpp`
- `firmware/src/ui/comps/comp_sonos.cpp`
- `firmware/src/ui/screens/views/prompt_card.h`
- `firmware/test/test_comp_geom/test_main.cpp`

### Files to edit

- `firmware/src/ui/screens/views/home_editorial.cpp` — **rewritten** into the thin host.
- `firmware/src/ui/screens/views/buddy_editorial.cpp` — adopt `prompt_card.h`; the Approve/Deny layout, its
  `BUDDY_HIT_SLOP` (24 px), the `(1 of N)` badge and the expiry countdown must exist in exactly one place.
- `firmware/src/ui/carousel.h` / `.cpp` — NVS `c_home` load at boot into `comp_state_set_active`,
  `carousel_apply_comps()`, the `comp_stack_apply()` call from `tick_cb`, `carousel_goto_buddy()` fallback.
- `firmware/src/core/hub_task.cpp` — `on_comps()` dispatch + ack.

### Files NOT to touch

`firmware/src/core/complications.*`, `firmware/src/core/comp_state.*`,
`firmware/src/ui/comps/comp_registry.h`, `firmware/src/ui/comps/comp_stack.h`,
`firmware/src/core/hub_proto.*`, `firmware/src/core/page_config.*`, `firmware/src/core/datastore.*`,
`firmware/src/core/records.h`, any `views/*_editorial.cpp` other than `home_` and `buddy_`, **anything
under `hub/`**, `docs/**`.

### What it can assume already exists (from WS-0)

The whole import table at the end of §3. `comp_stack_apply()` is declared but unimplemented — you implement
it. `carousel_has_page()` exists. `hub_parse_comps`/`hub_build_comps_ack` exist and are tested; do not
change their signatures.

### What to build

**1. `comp_stack.cpp`.** One file-static root container per page, plus one transparent container per
placement.

- Root: `lv_obj_create(page)` + `lv_obj_remove_style_all` + `lv_obj_clear_flag(..., LV_OBJ_FLAG_SCROLLABLE)`,
  sized `SCREEN_W x SCREEN_H` at (0,0), so `lv_obj_clean(root)` tears down exactly the stack and nothing
  else. **`lv_obj_clean` on the page itself would take the header and the prompt card with it.**
- Per placement `k` starting at slot `n`: container at absolute
  `(SAFE_INSET, comp_slot_anchor(n) + COMP_BAND_TOP_DY)`, size `(SCREEN_W - 2*SAFE_INSET, 62*size - 2)`,
  `lv_obj_remove_style_all`, not scrollable, not clickable (Phase 1 complications are **not tappable**,
  design §5.6 / §9.2).
- The stack, not the renderer, decides the separator rule: **draw no rule when the placement starts at slot
  1**; every other placement draws one at local y 0. Confirm against the shipped layout: the default puts
  `clock` at 1–2 (no rule, correct) and `fin` at slot 3 (rule at absolute 178, which is what ships today).
- `comp_stack_update()` walks the resolved list and calls `def->update()`. It runs from Home's `update()` on
  the existing 500 ms tick, so complications inherit the idle pause (#60) for free.
- `comp_stack_apply()` runs **only** on the LVGL thread. `comp_state_take_pending`; no-op if it equals the
  active list; else `lv_obj_clean(root)`, rebuild, `comp_state_set_active`, `comp_stack_update()`. Returns
  whether it rebuilt.

**2. The seven renderers.** Each is one file with file-static widget pointers and exactly
`{build, update}` — the same contract as a view (`views/CONVENTIONS.md`), because one-instance-per-id makes
per-instance state unnecessary. No `comp_inst_t`. **Never create an object in `update()`.**

| id | renders | source |
|---|---|---|
| `clock` (2 slots) | hero-84 time + meridiem + date line | `render_clock_ex` from `views/view_common.h`, wrapped |
| `fin` | name / value / trend + % | `ds_get_finance(i)` matched by `arg` (a ticker id), same `finance_by_id` scan today's Home does — **never assume slot 0** |
| `ice` | `D4 RIN` / price / trend + % | `ds_get_ice()` + `ice_front()`; `count == 0` with `ST_LIVE` is legal ("no contracts"), not an error |
| `agents` | icon + `project - title` / `state · age · +N more` | `ds_get_buddy().sessions[0]` |
| `usage` | `CLAUDE` / `24%` | `ds_get_usage()` provider matched by `arg` (a provider id). **Never feed `pct < 0` to a bar** — `-1` means unavailable, render `"--"` and no fill |
| `weather` | condition / temp / humidity | `ds_get_weather()` |
| `sonos` | icon + `track` / `artist · room` | `ds_get_sonos()` |

`fin`, `ice`, `weather`, `usage` are **shape A**; `agents` and `sonos` are **shape B**. Both shapes use the
local-offset table from `comp_registry.h`, unchanged. Every renderer must handle a non-live record with
`state_view.h` (`sv_status` / `sv_dim` / `sv_placeholder`) exactly as `market_put` does today. Use the
diff-aware `txt_set` / `txt_color` / `hidden_set` helpers from `screens/screen_common.h` — a 500 ms tick
that unconditionally re-sets text repaints the whole screen forever.

**3. The pixel-preserving move.** `market_row`/`market_put` become `comp_fin`/`comp_ice`; the Claude block
becomes `comp_agents`; `render_clock_ex` gets wrapped by `comp_clock`. **Move the bodies verbatim** —
recolour, restyle and "tidy" nothing. The only permitted change is coordinate *form* (page-absolute becomes
container-local) and the one 4 px move in §7. `finance_by_id` moves into `comp_fin.cpp` unchanged.

**4. `home_editorial.cpp`, after.** Roughly:

```cpp
static void build(lv_obj_t* page) {
  s_slot = build_header(page, "HOME");
  comp_stack_build(page);
  s_prompt = prompt_card_build(page);        // built ONCE, hidden
}
static void update(void) {
  buddy_rec_t b = ds_get_buddy();
  bool takeover = b.prompt.present && !carousel_has_page("agents");
  comp_stack_set_hidden(takeover);
  prompt_card_set_hidden(&s_prompt, !takeover);
  if (takeover) prompt_card_update(&s_prompt, &b);
  else          comp_stack_update();
  slot_set(s_slot, "", &b.hdr, now_s());     // header keeps carrying hub-link state
}
```

Precedence on Home is **takeover > stack**, and nothing else pre-empts.

**5. `views/prompt_card.h`.** Extract the Approve/Deny card out of `buddy_editorial.cpp`: `mk_btn`,
`BUDDY_HIT_SLOP`, the `PROMPT_PENDING` / `PROMPT_SENT_OK` / `PROMPT_TOO_LATE` kicker states, the queue badge
(`buddy_queue_badge`), the countdown (`buddy_prompt_secs_left`), and the offline dimming. Structure it as a
small struct of widget pointers plus `prompt_card_build/update/set_hidden` so two callers can each own one
instance — a header of `static inline` functions matching `view_common.h`'s idiom, or a `.h` + `.cpp` pair;
either is fine, but there must be exactly one implementation. `buddy_editorial.cpp` must render
**identically** after the extraction (its own `env:capture` frame is part of the WS-4 diff).

**Both surfaces call `buddy_decide()`** in `hub_task.cpp`, which is and stays the single canonical guard
(`docs/recipes.md` §5: "guard rails belong in the action function, not per-view"). Do not add a second
decision path; `PROMPT_PENDING`/`PROMPT_SENT_OK`/`PROMPT_TOO_LATE` must behave identically on both.

**Permission prompts only.** A `question` session does **not** take Home over — no hook is held for
`AskUserQuestion` (`CONTRACT.md` §C.3), so there is no stall to fix and a takeover would be pure noise.

**6. `carousel.cpp`.**

- Boot: read NVS `c_home` via `nvs_get_bytes`. Absent => `comp_face_t.default_slots`. Deserialize, resolve
  against `COMP_CATALOG` filtered by what `comp_find()` actually carries, `comp_state_set_active`. This must
  run in `carousel_init()` **before** any page is built, the same way `load_active_pages()` does.
- `uint8_t carousel_apply_comps(const comp_list_t* want, bool explicit_empty, bool* changed)` — resolve,
  compare with `comp_list_equal` against the active list (idempotence: the hub re-pushes on every reconnect),
  and on a real change `nvs_set_bytes("c_home", ...)` then `comp_state_set_pending`. **Persist before
  applying**, so the choice survives even if the rebuild path fails.
- `tick_cb`: `if (!s_settling) comp_stack_apply();` before the per-page `update()`. Never call it from
  Core 0.
- `carousel_goto_buddy()` gains the fallback: resolve `agents`, else `home`, else no-op. It keeps its
  wake-and-navigate contract. Its only callers today are the prompt wake path — re-read anything else that
  assumes it means "the agents page".

**7. `hub_task.cpp` `on_comps()`.** Model it on `on_pages()` and dispatch it **before** the loc/status
fall-through, alongside `frame_has(json, len, "\"comps\"")`. Unlike pages: no `ESP.restart()`, and the ack
is reliable because the link stays up. Log `hub: comps rev=%u applied (%u placements)` /
`hub: comps rev=%u already active; no rebuild`.

**8. `test_comp_geom`.** Pure host test over the geometry constants — no LVGL. Assert
`comp_slot_anchor(1..6) == {68, 130, 192, 254, 316, 378}`; assert slot 6 bottom ink
(`378 + 46`) `<= 426`; assert slot 1 top ink (`68 - 4`) `>= 60`; assert every local offset in the
`comp_registry.h` table reproduces the shipped absolute coordinates listed in §7 of this plan. This is the
**hardware-free half of the pixel proof** and the fallback if `env:capture` cannot run.

### Acceptance gate

```bash
cd /path/to/worktree/firmware && ~/.beacon-pio/bin/pio test -e native
cd /path/to/worktree/firmware && ~/.beacon-pio/bin/pio run -e beacon
cd /path/to/worktree/hub && swift build && swift test
```

- `pio test -e native`: **≥ 291** (WS-0's 283 + ≥8 from `test_comp_geom`). No existing case may go red.
- `pio run -e beacon`: **SUCCESS**, and flash usage must not regress by more than ~8 KB (the renderers are
  moved code, not new code; a large jump means something got duplicated rather than moved).
- `swift build && swift test`: **≥ 384**, unchanged — WS-1 touches no Swift. If it changed, you edited a
  file you were told not to.
- The `env:capture` diff and the on-device gate are **WS-4's**, not yours — but capture the "before" images
  first (§7) so WS-4 has a baseline.

### Traps

- **`lv_obj_clean` scope.** Clean the stack root, never the page. The header and the prompt card must
  survive a complication rebuild.
- **`lv_obj_clean` timing.** LVGL 8.4 will happily let you delete an object that is mid-animation or
  mid-event. Apply only from the LVGL timer, gate on `!s_settling`, and no-op on an identical list. This is
  the load-bearing risk in the whole design (§6.1) — do not weaken any of the three guards.
- **Container clipping.** LVGL 8 clips children to the parent. A shape-A row's secondary line sits at local
  y 40 with a mono-15 box ~20 px tall, ending at local y ~60 against a container height of exactly 60. If
  descenders clip on glass, **raise the container height to `62*size` and keep every anchor unchanged** —
  the extra 2 px overlaps only the next container's empty rule row and changes no ink. This remedy is
  pre-authorized; do not instead move the text.
- **`s_pages[8]`/`s_dots[8]` are fixed size.** You are not adding a screen, but do not assume otherwise.
- **`nvs_set_bytes` returns `false` on write failure and callers MUST check it** (unlike the byte setters).
- **Don't draw the page background** — `chrome_attach()` already did.
- **No hardcoded colours or fonts** in renderers; read `theme_active()` tokens or the shared `S` styles.
- **`SAFE_INSET` (40 px) is a floor** and nothing tappable may sit in a corner arc. Slot 6 ends at y 424,
  which is 20.7 px inside the arc — verified in design §5.3; do not "reclaim" the last few pixels.
- **Time comes from `now_s()`** (wall, for staleness) or `uptime_s()` (monotonic, for timeouts). Never a
  local `millis()` clock.
- The **`chart` complication is Phase 2.** Do not write `comp_chart.cpp`. `comp_find("chart")` returning
  `NULL` is correct and the resolver drops it.
- **`resolve_chart()` is Phase 2 work too.** Do not touch `firmware/src/fetch/series.cpp`.
- Only one `SRC_SERIES` slot exists, so at most one instrument can carry a live series — with
  one-instance-per-id that is now enforced by construction, not by a rule. Nothing to implement.

### Rollback

Two independent reverts, in this order:

1. **Takeover only:** revert `views/prompt_card.h`, the `buddy_editorial.cpp` adoption, the takeover branch
   in `home_editorial.cpp::update`, and the `carousel_goto_buddy` fallback. The complication stack survives.
2. **Everything:** revert the worktree. `home_editorial.cpp` returns to the hand-laid layout, `c_home` stays
   in NVS but is never read, and the hub's `comps` push is ignored by `on_frame` — exactly the "old
   firmware, new hub" row of the back-compat table, which is a supported state.

There is a third, narrower revert for the live-apply risk specifically; see §8.

---

## 5. WS-2 — hub: the app window and the four-tab IA

### Goal

Settings is an ordinary Mac window you open deliberately: resizable, minimisable, frame-autosaving,
restorable, with `Pages · Sources · Device · General` toolbar tabs. It never auto-opens except on the very
first launch after install. The "Don't open on startup" checkbox is **deleted**, not re-defaulted. The page
designer and the ticker editor fold in as tab content, leaving the hub with exactly one window.

### Files to create

- `hub/Sources/beacon-hub/SettingsTabs.swift` — the tab enum, the toolbar/`TabView` host, `BeaconSettingsTab`
  persistence.
- `hub/Sources/beacon-hub/SourcesTab.swift` — provider rows (toggles + per-provider `Set up`) and the Sonos
  account section, hosting the **existing** `SonosSettingsView` and provider-row views.
- `hub/Sources/beacon-hub/DeviceTab.swift` — connection/pairing checks, `Open Bluetooth & forget`, the
  ticker list (hosting the existing `TickerEditorView`), firmware version.
- `hub/Sources/beacon-hub/GeneralTab.swift` — start at login (`SMAppService`, honest `.requiresApproval`
  surfacing), prompt mute, about/version.

### Files to edit

- `hub/Sources/beacon-hub/SettingsWindowController.swift` — the real window (§below).
- `hub/Sources/beacon-hub/SettingsPanel.swift` — becomes the tab container's root, or is dissolved into
  `SettingsTabs.swift` + the tab files. Either is fine; `SectionHeader` and `StatusRow` are shared and must
  survive somewhere WS-3 can still import them.
- `hub/Sources/beacon-hub/MenubarController.swift` — **only** the menu items `Settings…` / `⌘,` and the
  replacement setup hint row ("Claude hooks not installed · Set up" → opens Settings on Sources). Do not
  touch the comps setters WS-0 added.
- `hub/Sources/beacon-hub/main.swift` — activation policy (§9.1: switch to `.regular` while the window is
  open, back to `.accessory` on close). **Provisional; see §11.**
- **Delete** `hub/Sources/beacon-hub/PageDesignerWindowController.swift` and
  `hub/Sources/beacon-hub/TickerEditorWindowController.swift`, and remove their `lazy var`s in
  `AppDelegate.swift`. *(This is the one line of `AppDelegate.swift` WS-2 may touch — deleting two stored
  properties and their two `onOpen*` closures. Nothing else.)*

### Files NOT to touch

`hub/Sources/beacon-hub/PageDesignerView.swift`, `DevicePreview.swift`, `ComplicationStore.swift`,
`HubViewModel.swift`, `hub/Sources/BeaconHubKit/**`, `AppDelegate.swift` (beyond the two deleted
properties), **anything under `firmware/`**, `docs/**`.

### What it can assume already exists (from WS-0)

`SettingsLaunch.shouldAutoOpen(didAutoOpen:)` and the `BeaconDidAutoOpenSettings` key; `AppDelegate` already
calls `showIfNeeded()` through the new gate. `HubViewModel` already carries the complication fields — you
do not render them; WS-3 does. `PageDesignerView(model:)` already exists as a plain SwiftUI `View` taking a
`HubViewModel` and is embeddable as-is.

### The frozen seam with WS-3

The Pages tab body is **exactly** `PageDesignerView(model: model)` and nothing else. WS-2 supplies the tab
chrome and the dirty badge; WS-3 supplies everything inside. Neither side may change that initializer.
`PageDesignerWindowController`'s revert-on-close rule moves to (a) window close and (b) nothing else —
**keeping a staged edit alive across a tab switch is correct**, because the user may be in Sources adding
the ticker the chart wants. The Pages tab shows a dirty badge while staged edits exist.

### What to build

- `styleMask = [.titled, .closable, .miniaturizable, .resizable]`.
- `frameAutosaveName = "BeaconSettingsWindow"`. A settings window that forgets where it was is the tell that
  it is not a real window.
- `contentMinSize` 720×520 — the Pages tab needs the horizontal run.
- `isRestorable = true`, `isReleasedWhenClosed = false` (already true).
- Tabs via `NSToolbar` in the standard preferences idiom, or a SwiftUI `TabView` in the
  `NSHostingController`. The toolbar reads more like a Mac app and gives each tab a title.
- Tab selection persists under `BeaconSettingsTab`.
- **Delete** `model.dontShowOnStartup`, `model.onToggleDontShow`, and the checkbox in `SettingsPanel.swift`.
  A checkbox that controls a behaviour we just removed is dead UI.
- The menubar popover gains the replacement guidance row: when a provider has its buddy toggle on but hooks
  are undetected, show `Claude hooks not installed · Set up`, opening Settings on the Sources tab. Non-modal,
  no focus theft.

Tier placement, from design §3.1 — do not relitigate it. Provider toggles and hooks installs are **Sources**,
not the Agents page, because coding-buddy-on holds real tool calls on the Mac whether or not any page shows
them, and hooks installs write `~/.claude/settings.json` / `~/.codex/config.toml` / `~/.omp/.../beacon.ts`.
The ticker list is **Device** (provisional, §9.3): one list serves Markets *and* Chart, so putting it in
either page's inspector makes the other page's dependency invisible.

### Acceptance gate

```bash
cd /path/to/worktree/hub && swift build && swift test
./build-app.sh run     # manual: window opens, resizes, remembers frame, tabs persist
```

- `swift test`: **≥ 384**, i.e. WS-0's floor, plus ≥4 new for any pure helper you extract (e.g. the
  menubar-hint decision). Do not delete a test to make a number.
- `swift build`: clean, no warnings introduced.
- Manual checks, recorded in the PR body: (a) launch with `BeaconDidAutoOpenSettings` set => **no** window;
  (b) delete the key and launch => window opens exactly once; (c) resize + move + quit + relaunch => frame
  restored; (d) each tab renders and selection persists; (e) `⌘,` opens Settings and `⌘W` closes it.
- **No firmware commands.** WS-2 does not build firmware.

### Traps

- **macOS 13 is the deployment target** (pinned by the single-parameter `onChange` comment in
  `PageDesignerView`). `.draggable`/`.dropDestination` are available; `NSItemProvider` is not needed.
- **`SwiftUI.Settings` scene is rejected** (design §2.4): it wants a `.regular` app and forces the fixed-size
  preferences look, which is exactly what we are getting away from.
- **The activation-policy switch is provisional** (§9.1). It buys a real menu bar, `⌘,`, `⌘W` and window
  cycling; it costs a Dock icon that appears and disappears. Implement it as written, but keep it in **one
  isolated commit** so it can be reverted alone.
- **`BeaconFirstRunComplete` still exists** and is still written by `maybeMarkComplete()`. It just no longer
  drives window presentation. Do not delete the key or the latch.
- **CoreBluetooth cannot remove an OS-level bond.** The Device tab's forget guidance text stays as-is.
- **Never log a token or a command `hint`.**

### Rollback

Revert the worktree. `SettingsPanel.swift`'s single-window form returns; the two window controllers come
back with their `AppDelegate` properties. The activation-policy commit reverts independently if the Dock
icon proves obnoxious.

---

## 6. WS-3 — hub: Pages tab, drag-and-drop, inspector, complication slot editor

### Goal

The Pages tab reads as *composition*: enabled pages as a draggable carousel of `DevicePreview` cards on
top, the full catalog as a grid below, per-page options in a right-hand inspector. Selecting **Home** gives
you the six-slot complication editor, which enforces the 6-unit capacity with the clock counting as 2, one
instance per id, arg validation, and the blank-Home warning — and whose Save applies **live, with no device
restart**.

### Files to create

- `hub/Sources/beacon-hub/ComplicationEditorView.swift` — the slot editor (the Home inspector).
- `hub/Sources/BeaconHubKit/ComplicationEditor.swift` — the **pure** editor rules (capacity, one-per-id,
  arg validation, blank warning), so they are testable without SwiftUI.
- `hub/Tests/BeaconHubKitTests/ComplicationEditorTests.swift`
- `hub/Tests/beacon-hubTests/SonosRoomPersistenceRegressionTests.swift` — or extend the existing
  `SonosRoomPersistenceTests.swift`: a page save with the Sonos page **disabled** must leave
  `BeaconSonosSelectedRoom` intact (§1 item 1; this is the regression guard, not a new fix).

### Files to edit

- `hub/Sources/beacon-hub/PageDesignerView.swift` — the carousel/grid/inspector rework. Keep
  `ChartInstrumentPopover` + the pure `ChartInstrumentSelection` **verbatim**; keep `SonosRoomPopover` and
  `selectRoom`'s immediate-apply behaviour **verbatim**. Keep the chevron `move(±1)` buttons as the
  keyboard/accessibility path — drag-and-drop with no non-pointer equivalent is a regression and they cost
  two buttons.
- `hub/Sources/beacon-hub/DevicePreview.swift` — if the Home preview should reflect the staged complication
  assignment. Optional; do it only if it is cheap.
- `hub/Tests/beacon-hubTests/SonosRoomPersistenceTests.swift` — if extending rather than adding.

### Files NOT to touch

`SettingsPanel.swift`, `SettingsWindowController.swift`, `SettingsTabs.swift`, `SourcesTab.swift`,
`DeviceTab.swift`, `GeneralTab.swift`, `main.swift`, `MenubarController.swift`, `AppDelegate.swift`,
`HubViewModel.swift`, `ComplicationStore.swift`, `BeaconHubKit/Complications.swift`,
`BeaconHubKit/Protocol.swift`, `BeaconHubKit/PageConfig.swift`, **anything under `firmware/`**, `docs/**`.

### What it can assume already exists (from WS-0)

`CompLimits`, `ComplicationCatalog` (with sizes), `CompPlacement`, `CompsFrame`, `ComplicationStore`, and on
the view model: `compSlots`, `appliedCompSlots`, `compSync`, `compsDirty`, `onApplyComps`, `onRevertComps`.
Pushing is already wired — you call `model.onApplyComps(...)`.

### What to build

**Layout** (design §3.2):

```
+----------------------------------------------------------------------------------+
| ON THE BEACON   (drag to reorder)                                 4 of 7 enabled  |
| [prev] [prev] [prev] [prev]     <- ~150 px DevicePreview cards, settings pinned    |
+----------------------------------------------------------------------------------+
| AVAILABLE  (LazyVGrid of the full PageCatalog)  |  HOME                            |
|                                                  |  Complications  (6 slots)       |
+----------------------------------------------------------------------------------+
| * Pages changed - the Beacon restarts (~5 s)     [ Revert ]   [ Save & push ]     |
+----------------------------------------------------------------------------------+
```

- Drag payload is the page id `String`. Two drop targets: the carousel (insert-at-index, with an insertion
  caret between cards) and the available grid (= disable). `settings` is pinned — `PageLimits.alwaysID`
  already encodes this and the device force-appends it regardless, so showing it as removable would be a lie.
- The inspector shows the selected page's options. A page with nothing to configure says **"No options"**,
  not an empty well.
- Source controls are **projected, not moved** (design §3.1): the Agents inspector shows the same provider
  rows bound to the same `ProviderSettingsStore` that the Sources tab renders, with one line of honesty
  under them — *"Also applies while this page is hidden."* Do not invent a rule where hiding a page disarms
  a permission gate.
- Reordering mutates `model.pageRows` and clears `model.pageSync`; nothing pushes until `Save & push`.
  Unchanged.

**The slot editor** uses the same two primitives (`.draggable` / `.dropDestination`), with slot wells as
drop targets. Rules, all enforced in `BeaconHubKit/ComplicationEditor.swift` and merely rendered by the view:

- 6 slot **units**, and the clock consumes 2. A 2-slot complication cannot be dropped where 1 unit remains.
- **One instance per id.** A complication already placed is greyed in the palette. Consequence, stated
  plainly in the UI copy so nobody files it as a bug: Home can show exactly one ticker, one usage provider
  and (Phase 2) one sparkline.
- `fin` takes a ticker id as its arg (picked from `model.tickerRows`); `usage` takes a provider id (picked
  from `model.providers`). Both must be validated against `CompLimits.allowed` and refused at the editor
  boundary — **the hub must not be able to store an out-of-alphabet arg**, so the device-side drop is a
  defence rather than the first line (design §10.7).
- An **empty** assignment is allowed but warned: *"Home will be blank."* The clock is assignable, so this is
  reachable, and nothing recovers an intentional blank except editing it back — which is fine, because
  Settings is always reachable (`PageLimits.alwaysID`).
- A secondary cue lives in the Pages tab: *"Coding Buddy is on but the Agents page is hidden; prompts will
  appear on Home."* This is **information**, not the mitigation — the device-side takeover is the fix.

**The footer must distinguish the two verbs** (design §10.3). A single `Save & push` that changes both the
page list *and* the complication assignment still reboots, because the page frame does:

- `Pages changed · the Beacon restarts (~5 s)`
- `Complications updated · applies immediately`

Show whichever apply, both when both are dirty. Users who learn that the editor "sometimes reboots for no
visible reason" stop trusting it.

### Acceptance gate

```bash
cd /path/to/worktree/hub && swift build && swift test
./build-app.sh run     # manual: drag a page, drag a complication, watch the two footer lines
```

- `swift test`: **≥ 396** (WS-0's 384 + ≥12 new). Editor tests must cover: 6-unit capacity **with the clock
  counting as 2**; a 2-slot placement refused when 1 unit remains; one-instance-per-id enforcement; arg
  validation accepting a real ticker id and refusing an out-of-alphabet string; the blank-Home warning
  firing on an empty assignment and not otherwise; and the Sonos-room regression guard.
- `swift build`: clean.
- **No firmware commands.** WS-3 does not build firmware.

### Traps

- **Do not put the complication assignment in `opts`.** `PAGE_OPTS_LEN` is 48 bytes and `hub_parse_pages`
  truncates at that boundary; and `page_list_equal` compares opts, so any difference sets `changed` =>
  `nvs_set_bytes` => `pages_ack` => `ESP.restart()`. Dragging a complication would reboot the device. That
  is the single worst outcome available.
- **`enabledPageOpts` filters by `enabled`.** Anything that must survive its page being hidden does not
  belong in `PageRow.opts`. The Sonos room already learned this; do not undo it (§1 item 1).
- **`ChartInstrumentSelection.addAndSet` writes to the shared device ticker list.** Keep the hint that the
  Chart inspector's picker is adding a row to the device's list (provisional §9.3).
- **The hub's slot preview cannot verify sizes.** `ComplicationCatalog` mirrors `COMP_CATALOG` with no
  compiler check — the same failure `PageCatalog` already carries, and the class that produced the
  `symbol`/`sym` investigation on 2026-07-26. The device's size always wins (design §6.4); the catalog
  fixture test in WS-0 is the mitigation until Phase 3's device report.
- **Keep "page" as the noun everywhere** (§9.4, provisional). Apple's model is "apps provide
  complications", but "page" is what the wire, the firmware, `PageCatalog`, `page_config.h` and every
  existing doc say. Renaming only the user-facing noun is a drift generator.
- **Complications are not tappable in Phase 1** (§9.2, provisional) — do not build affordances that imply
  they are.
- **No force-unwraps outside tests.**

### Rollback

Revert `PageDesignerView.swift` and delete the four new files. `ComplicationStore` and the frame remain but
nothing writes them, so the hub stays pristine and never pushes — the exact "new firmware, old hub" row of
the back-compat table. The rest of Phase 1 still ships; users just cannot edit complications yet.

---

## 7. The pixel-preserving refactor, and how it is proved

### The coordinate contract

These are the **shipped** absolute coordinates in `home_editorial.cpp` today. Every one must survive the
refactor, in this exact form, with one exception marked.

| Element | Shipped expression | Absolute y | After the refactor |
|---|---|---|---|
| clock hero | `SAFE_INSET + 18` | **58** | `comp_clock`, container top 54, local y 4 |
| meridiem | `align_to(clock, OUT_RIGHT_BOTTOM, 8, -14)` | follows | unchanged, same call |
| date | `SAFE_INSET + 110` | **150** | `comp_clock`, local y 96 |
| S&P rule | `SAFE_INSET + 152 - 14` | **178** | slot 3 (a=192), container top 178, local y 0 |
| S&P name | `SAFE_INSET + 152 + 4` | **196** | local y 18 |
| S&P value | `SAFE_INSET + 152 - 4` | **188** | local y 10 |
| S&P pct | `SAFE_INSET + 152 + 26` | **218** | local y 40 |
| S&P trend | `align_to(pct, OUT_LEFT_MID, -6, 0)` | follows | unchanged, same call |
| D4 RIN rule / name / value / pct | `SAFE_INSET + 214 ∓ …` | **240 / 258 / 250 / 280** | slot 4 (a=254), same locals |
| Claude rule | `SAFE_INSET + 262` | **302** | slot 5 (a=316), container top 302, local y 0 |
| Claude icon | `SAFE_INSET + 280` | **320** | local y 18 |
| Claude line 1 | `SAFE_INSET + 276`, x `SAFE_INSET + 26`, width 356 | **316** | local y 14, local x 26 |
| Claude line 2 | `SAFE_INSET + 306` | **346** | **→ 342** (local y 40) — *the one intentional change* |
| slot 6 | — | unused today | still empty in the default assignment; nothing drawn, no rule, no placeholder |

The 4 px move exists so both row shapes share a secondary baseline and a two-line complication can sit
anywhere in the stack without clipping the next slot's rule (design §5.2). It is the **only** permitted
visual delta.

### Primary proof — `env:capture` diff

`env:capture` exists (`firmware/platformio.ini` `[env:capture]`, `firmware/src/ui/capture.cpp`,
`firmware/tools/capture/grab.py`) and is deterministic: it forces `BEACON_DEV=1`, so screens are always
populated with seeded data and two runs are comparable.

**Before WS-1 starts**, on the unmodified tree:

```bash
cd firmware
~/.beacon-pio/bin/pio run -e capture -t upload
~/.beacon-pio/bin/pio device list                     # find the port
python3 tools/capture/grab.py --port /dev/cu.usbmodemXXXX --out shots/before/
```

**After WS-1 lands** (WS-4 runs this), same device, same seed:

```bash
~/.beacon-pio/bin/pio run -e capture -t upload
python3 tools/capture/grab.py --port /dev/cu.usbmodemXXXX --out shots/after/
```

Then diff. The assertion is not "looks the same" — it is a rectangle:

- `shots/before/*HOME*.png` vs `shots/after/*HOME*.png`: every pixel **outside** the rectangle
  `x ∈ [66, 422], y ∈ [342, 366]` must be byte-identical. Inside it, the only change is the mono-15
  secondary line moving up 4 px. (Derivation: the label's left edge is `SAFE_INSET + 26 = 66`, its capped
  width is 356, and the mono-15 box spans ~20 px from 346 old / 342 new — union 342..366.)
- `shots/before/*AGENTS*.png` vs `shots/after/*AGENTS*.png`: **byte-identical, no exceptions.** The prompt
  card extraction must be invisible.
- Every other screen: **byte-identical.**

A ten-line `PIL`/`numpy` script produces the count and the bounding box of changed pixels; put it in the PR
body, not in the repo.

Needs `pip install pyserial pillow numpy`. **Do not hold the port open in `pio device monitor` at the same
time.** `env:capture` is never shipped.

### Fallback proof, if `env:capture` cannot produce a usable diff

Reasons it might not: no device free, the serial port is contended, `pyserial`/`pillow`/`numpy` are
unavailable, or the sweep drops frames. If so, the refactor is proved by **both** of the following, and the
capture diff is deferred to the on-device gate in §8:

1. **`test_comp_geom`** (WS-1) asserts the anchors and every local offset reproduce the absolute
   coordinates in the table above. Host-only, no hardware, must pass regardless.
2. **A literal-diff review.** Extract every `lv_obj_align*` call from the pre-change `home_editorial.cpp`
   as `(align, x, y)` triples and assert the post-change renderers emit the identical set once the
   container origin is added back. The table above **is** that set — 14 rows, one intentional delta. This
   is a mechanical review artifact, recorded in the PR body.

Neither substitute is as strong as the pixel diff, so if both are used, §8's on-device gate must include a
**side-by-side photo of Home** against a pre-change photo before Phase 1 is called done. Do not ship the
refactor on host tests alone.

---

## 8. The Phase 1 exit gate — go/no-go on the live rebuild

This is the load-bearing risk in the entire design (§10.1). `on_theme()` already does strictly more
(`lv_obj_clean` + rebuild of **every** page, live, from a settings tap via `lv_async_call`) — but it has
never been done **from the tick timer while the carousel may be scrolling**, and LVGL 8.4 will happily let
you delete an object that is mid-animation or mid-event. Find out in week one, not week three.

WS-4 runs this on hardware. It is a **gate**, not a hope: if it fails, Phase 1 does not ship as designed.

### Criterion 1 — live rebuild (the one that can fail)

1. Flash `-e beacon`, connect the hub, open Settings → Pages → Home.
2. Drag a complication into a free slot and Save. **Expect:** serial shows
   `hub: comps rev=N applied (M placements)`, Home redraws within one 500 ms tick, and there is **no** boot
   banner, **no** `ESP.restart()`, and **no** BLE disconnect.
3. **Stress:** repeat drag-save **20 times** while continuously swiping the carousel, deliberately trying to
   land an apply inside a scroll animation and inside the `s_settling` recenter window. Expect no crash, no
   `Guru Meditation`, no LVGL assert, no orphaned widget.
4. **Heap:** the `hub: conn=1 int_free=… min=…` line prints every ~10 s. `min` must not move by more than
   ~1 KB across the whole 20-apply run (the design budgets ~0.62 KB persistent internal SRAM against an
   observed 46,428 B floor).
5. **Idempotence:** toggle Bluetooth off and on so the hub re-pushes on reconnect. Expect
   `hub: comps rev=N already active; no rebuild` and **no flicker**.

### Criterion 2 — pixel identity

The `env:capture` diff in §7, or the documented fallback plus a side-by-side photo.

### Criterion 3 — the prompt takeover

With Coding Buddy on and the **Agents page disabled**, trigger a `PermissionRequest` (e.g. a Bash tool call
in Claude Code). Expect: the device wakes, `carousel_goto_buddy()` lands on **Home**, Home shows the
Approve/Deny card, a tap routes through `buddy_decide` and the hub answers the held hook, and the device
shows a **truthful** ack (`SENT OK`, not an optimistic clear). Then re-enable the Agents page and confirm
the takeover no longer fires — a user who keeps the Agents page must never see it.

Also confirm the negative: a `question`-state session with Agents hidden must **not** take Home over.

### If criterion 1 fails — the fallback, in tiers

Do not improvise. Take the highest tier that passes.

**Tier 1 — defer the rebuild off the visible page.** Keep everything, but gate `comp_stack_apply()` on
`s_current != home_index` (rebuild while Home is scrolled away) plus a wake-time apply so a user staring at
Home still sees the change within a swipe or a screen wake. Cost: the edit is not instant when Home is the
visible page. Benefit: no object is deleted on a page that is currently rendering or animating. Confined to
`carousel.cpp`; ~15 lines.

**Tier 2 — degrade to the page path, restart per edit.** `carousel_apply_comps` persists NVS, acks, then
`delay(250); ESP.restart()` exactly as `carousel_apply_pages` does. `on_comps` gains the "ack before
restarting" comment. The hub's footer collapses to one line — `Complications changed · the Beacon restarts
(~5 s)` — and §10.3's two-status-line requirement goes away. Confined to `hub_task.cpp`, `carousel.cpp`,
and one string in `PageDesignerView.swift`; ~30 lines. **Prepare this patch before the bench session** so
the decision is a merge, not a scramble.

If Tier 2 is taken: **delete the pending-holder path** (`comp_state_set_pending` /
`comp_state_take_pending` / `comp_stack_apply`) rather than leaving it in the tree. Dead code that claims a
capability the device does not have is worse than the missing capability, and `CONTRACT.md` §A3 must be
corrected in the same change to say the device restarts.

A reboot-per-drag product is worse than no feature. If **Tier 2 is also unacceptable to the owner**, the
correct move is to ship WS-2 (the window) and WS-3's page manager without the complication editor, and hold
WS-1 — not to ship a rebooting editor.

---

## 9. Migration — what must be true for existing users

Encoded as acceptance checks, all of which WS-4 verifies.

| Claim | Check | Where |
|---|---|---|
| NVS `c_home` absent => compiled default | Erase the key (or a fresh flash), boot, confirm Home renders `clock,fin.sp500,ice,agents` at the shipped anchors | on-device, WS-4 |
| A hub with `BeaconCompRev` 0 never pushes | `ComplicationStore.frame()` returns `nil` while pristine; `pushCompConfig()` returns early | host test, WS-0 |
| Existing users see no change until they open the editor | Combination of the two rows above: an untouched hub pushes nothing, so the device keeps its default | WS-4 sign-off |
| The first save writes `BeaconCompSlots` and bumps to rev 1 | Host test on `ComplicationStore.set` | WS-0 |
| Stored page config is untouched | `BeaconPageIDs` / `BeaconPageRev` / `BeaconPageOpts` keep their meaning and format; nothing in this plan writes them differently | WS-4 review |
| `sp500` keeps today's semantics | Including `"not in list"` when the hub has pushed a ticker list without it — `finance_by_id` already handles that; it moves verbatim into `comp_fin` | WS-1 |
| Old firmware + new hub | `on_frame()` finds no known key and drops the `comps` frame, exactly as it drops `sessions`/`sdetail`/`sonos` on older builds. Home renders its compiled layout. No error, no version bump | design §6.4; assert by reading the dispatch order |
| **No Sonos room migration is needed** | §1 item 1 — the room never rode `opts`. Do **not** write `BeaconSonosRoomMigrated` | WS-3 regression test |

Push order on `central.onReady` is **tickers → comps → pages** (WS-0), so that if the page push restarts the
device the complication blob is already persisted and the device boots correct.

---

## 10. WS-4 — convergence, hardware gate, docs

### Goal

The three parallel branches become one green tree, the gate in §8 is executed and its verdict recorded, and
the docs stop lying.

### What to do

1. **Merge and build the union.** From the integrated tree:
   ```bash
   cd firmware && ~/.beacon-pio/bin/pio test -e native      # >= 291
   cd firmware && ~/.beacon-pio/bin/pio run -e beacon       # SUCCESS
   cd hub && swift build && swift test                      # >= 396
   ```
2. **Duplication sweep.** Three agents working blind produce three near-identical helpers. Specifically
   check for: a second charset validator (there must be exactly one on each side — `comp_entry_valid` in C,
   `CompPlacement` in Swift); a second slot-anchor table; a second Approve/Deny layout; a second
   size/`takes_arg` table on the device.
3. **Run the §8 gate on hardware.** Record the verdict, the heap numbers, and the capture diff in the PR
   body. If Tier 1 or Tier 2 is taken, apply the prepared patch and re-run.
4. **Run the §7 capture diff** across all screens, not just Home.
5. **Docs.**
   - `docs/codemap.md` §1: correct the test counts (they are stale by ~53 firmware cases and ~146 hub
     cases), add `comps` to the hub→device blocks row and `comps_ack` to the device→hub commands row, add
     `ui/comps/` and `core/complications.*` / `core/comp_state.*` to the concern tables, and add a data-path
     trace **F. Complication config (hub → device)** alongside E.
   - `docs/recipes.md`: new **§11 "Add a complication"** — the file list (`ui/comps/comp_<id>.cpp`, the
     `COMP_REGISTRY` entry, the `COMP_CATALOG` row, `ComplicationCatalog`, the fixture test) and the traps
     (must read a record the device already maintains; never causes a fetch; size lives only in
     `COMP_CATALOG`; not tappable in Phase 1).
   - `docs/recipes.md` §0: correct the stale counts there too.
   - `DESIGN.md`: add the six-slot grid, the 62 px pitch, the anchors `68 · 130 · 192 · 254 · 316 · 378`,
     and the two row shapes. `DESIGN.md` is the authority for the visual system and must carry them.
   - `hub/CONTRACT.md`: verify WS-0's §A3 still matches what shipped, especially if a §8 fallback tier was
     taken (the "does not restart" claim).
6. **One authorized edit to the design doc, and only this one.** In
   `docs/specs/2026-07-27-hub-app-and-home-complications-design.md` §4.4, the sentence claiming the page's
   `opts["room"]` "becomes a mirror the device reads for its page header" is **false as of 2026-07-27**: no
   mirror key is written at all (§1 item 2). Correct that sentence to state that the room lives solely in
   the Sonos source store (`SonosRoomStore` / `SonosProvider.setSelectedRoom`) and never rides `opts`.
   Owner-authorized 2026-07-27 as a factual correction of a claim overtaken by shipped code — **not** a
   design change. Edit the statement in place; do not append a changelog (`docs/recipes.md` §10: docs
   reflect current state, not history). Change nothing else in that file: leave §3.5, §7 and every other
   section alone, and do not restructure or re-argue anything.
7. **Do not** touch `docs/specs/2026-07-27-ota-updates-design.md` — that is separate work under another
   agent. Report any other design drift (§1, §11, §13) to the owner rather than editing it.

### Acceptance gate

All three commands above green at the stated floors, the §8 verdict recorded, and the §7 diff attached.

### Rollback

WS-4 changes only docs and (possibly) the fallback patch. Reverting it leaves the code intact.

---

## 11. Later phases (sketch only)

**Phase 2 — the `chart` sparkline.** The 2-slot chart complication (`comp_chart.cpp`); the
`resolve_chart()` precedence change from design §4.4 — the `chart` page's `opts["sym"]` when the page is
enabled, else the `chart` complication's arg, else `CHART_TICKER_ID`; and the "one series slot" constraint
surfaced in the hub editor (which one-instance-per-id now enforces structurally). Band 122 px: 34 (name +
value) + 8 gap + 68 sparkline + 12 (lo/hi labels). Nothing in Phase 1 forecloses it — `chart` is already in
`COMP_CATALOG` at size 2 with `takes_arg`, and the resolver already handles it.

**Phase 3 — device-reported registry, and tap-to-jump if §9.2 resolves that way.**
`cmd:"report","what":"comps"` reusing the §B3 one-way chunked report machinery verbatim, so the hub renders
only complications the connected firmware actually carries **and their real sizes** — the one back-compat
gap §6.4 currently resolves in the device's favour. This is the same cure `PageCatalog` needs; do both in
one change and delete a row from `docs/codemap.md` §6's drift table.

Deliberately unscheduled: a second face, user-authored renderers, per-device layouts.

---

## 12. Rollback matrix

| Workstream | Smallest revert | What survives | What the user loses |
|---|---|---|---|
| WS-0 | whole worktree | nothing downstream exists yet | — |
| WS-1 | (a) takeover only: `prompt_card.h` + the `home_editorial.cpp` branch + the `carousel_goto_buddy` fallback; (b) whole worktree | (a) the complication stack; (b) the hub side, which simply never gets applied | (a) prompts stall silently when Agents is hidden — back to today's behaviour; (b) Home is the hand-laid layout again |
| WS-1, live-apply only | §8 Tier 2 patch (~30 lines across `hub_task.cpp`, `carousel.cpp`, one hub string) | everything else | complication edits reboot the device |
| WS-2 | whole worktree; or the activation-policy commit alone | the page manager and the editor, in the old single-panel window | the real window, the four tabs |
| WS-3 | `PageDesignerView.swift` + delete 4 new files | the window, the firmware, the wire | no complication editor; hub stays pristine and pushes nothing, which is a supported state |
| WS-4 | whole worktree (docs only) | all code | docs stay stale |

---

## 13. Under-specified in the design

Each of these would otherwise make a cold agent guess. **Items 1–4 are settled** — owner-confirmed
2026-07-27, implement them exactly as written and do not reopen them. Items 5–9 are still open and should
be decided before dispatch; each names the workstream a different answer would move.

1. ~~**Where `size` lives on the device.**~~ **Settled 2026-07-27.** The design's `complication_t` carries
   `size`, and `comp_list_resolve` also takes a `known_size[]` array — two homes for the same fact, in
   files that link into different builds (`comp_registry.cpp` is LVGL-coupled and cannot be host-tested),
   which drifts invisibly until a slot renders at the wrong span. **Resolution: `size`/`takes_arg` live
   only in the pure `COMP_CATALOG` and are removed from `complication_t`.** Single home, pure side.
2. ~~**How the resolver distinguishes "explicitly empty" from "everything unknown".**~~ **Settled
   2026-07-27.** Design §4.3 rule 5 requires the distinction but the signature in §4.3 cannot express it —
   both arrive with a resolved count of 0. **Resolution: a `bool requested_was_explicit_empty` parameter,
   threaded from `hub_parse_comps`.** The mechanism matters less than it being decided once in WS-0 rather
   than three agents each inventing one.
3. ~~**The Sonos room.**~~ **Settled 2026-07-27.** Design §3.5 and §4.4 treat it as unfixed work with a
   migration flag; it is already fixed (§1 item 1). The work item is dropped, no `BeaconSonosRoomMigrated`
   is written, WS-3 adds the regression test, and WS-4 corrects the one false sentence in design §4.4
   (§10 step 6). Recorded here because the design doc still reads as though this is open.
4. ~~**Who owns the `pages` vs `comps` footer when both are dirty.**~~ **Settled 2026-07-27.** §10.3
   requires the two lines but does not say the order, whether Save pushes both in one action, or what
   `Revert` reverts. **Resolution: one `Save & push` applies both, comps first and pages second** —
   matching the existing tickers-before-pages rationale, so the cheap non-restarting push lands before the
   one that restarts — **both lines show when both are dirty, and `Revert` discards both staged edits.**
5. **The activation-policy switch (§9.1, provisional).** Taking it means a Dock icon appears and vanishes
   as the window opens and closes. Kept in an isolated commit so it can be dropped; say if you would rather
   it not land at all.
6. **Ticker-list location (§9.3, provisional).** Device tab, with the Chart inspector keeping its
   add-a-symbol picker plus a hint that it writes to the device's shared list. If it should instead be
   duplicated into both the Markets and Chart inspectors, that is a WS-2/WS-3 boundary change and must be
   decided before dispatch.
7. **Tappable complications (§9.2, provisional).** Not tappable in Phase 1. If they should be tappable,
   WS-1's containers need hit targets and WS-3 needs an affordance, and the mis-tap argument at 62 px pitch
   plus the "tapping a disabled page's complication would reboot the device to enable it" follow-on need an
   answer first.
8. **Whether `DevicePreview`'s Home card should reflect staged complications.** The design's Pages-tab mock
   shows preview cards but never says whether Home's preview is live against the staged assignment. This
   plan makes it optional in WS-3. If it is required, it is real work and should be its own line item.
9. **Container height vs LVGL clipping.** `62*size - 2` leaves a shape-A secondary line ending at exactly the
   container's bottom edge. This plan pre-authorizes raising the height to `62*size` if descenders clip on
   glass, because it changes no ink. Confirm that is acceptable rather than adjusting the type scale.
