# Beacon — task recipes

> **What this is:** the multi-file checklists for the changes people actually make. Each recipe lists
> every file you must touch, in order, plus the traps that bite. `docs/codemap.md` says where things
> live; this says what to do.
>
> Rules that override anything here: `AGENTS.md`, `docs/tech.md` (§10 conventions), `DESIGN.md`
> (tokens), `hub/CONTRACT.md` (wire schema).

---

## 0. Verify before and after

```bash
cd firmware && ~/.beacon-pio/bin/pio test -e native      # 38 suites / 295 cases, ~20 s
cd firmware && ~/.beacon-pio/bin/pio run -e beacon       # compile for ESP32-S3 (~2 min cold, ~10 s warm)
cd hub && swift build && swift test                      # 416 cases, ~1 s
```

Both suites are green at `bbf0774` (2026-07-27, WS-4 of the home-complications build). If a suite is
red before your change, say so rather than absorbing it.

**Pass `-e beacon`.** A bare `pio run` also builds `[env:native]`, which has no `main()` and always
reports `FAILED` — ignore-able noise that reads like a broken build. The first ESP32 build downloads
~2.4 GB of toolchain into `~/.platformio`; `pio test -e native` needs none of it.

---

## 1. Add a carousel screen

The screen module itself is 4 lines; the work is the 7 per-theme views and the registration. Budget
one view file per theme — `SCREEN_MODULE_SIMPLE` will not link until all 7 exist.

**1. Views (7 files).** `src/ui/screens/views/<screen>_<theme>.cpp` for each theme suffix
`editorial, hud, calm, blueprint, led, oscilloscope, analog`. Read
`src/ui/screens/views/CONVENTIONS.md` first — it is the authority on the view contract. Each file
ends with exactly:
```cpp
const screen_view_t <screen>_<theme>_view = { build, update };
```
Start by copying the nearest existing view for that theme (e.g. `home_calm.cpp` for a calm layout) so
the lane's visual language carries over.

**2. Module (2 files).**
```cpp
// src/ui/screens/screen_<name>.h
#pragma once
#include "ui/screen.h"
extern const screen_module_t <name>_module;

// src/ui/screens/screen_<name>.cpp
#include "ui/screens/screen_<name>.h"
#include "ui/screens/screen_module.h"
SCREEN_MODULE_SIMPLE(<name>, "<ID>", <name>_module);
```
`<ID>` is the uppercase carousel label (`"HOME"`, `"LIMITS"`, ...). Keep it short — views render it as
an eyebrow.

**3. Register.** `src/ui/carousel.cpp`: add the `#include` and the entry in `MODULES[]`. `COUNT` is
derived, so nothing else changes.

### Traps
- **`s_pages[8]`/`s_dots[8]` are fixed-size.** 8 screens is the hard ceiling; a 9th silently
  overruns. Bump both if you go past 8.
- **`nvs_set_screen()` persists the last screen as a raw index.** Inserting a screen anywhere but the
  end changes what a returning device restores. Either append, or bump a migration byte the way
  `THEME_DEFAULT_VER` does for themes (`carousel.cpp:131`).
- **`carousel_goto_buddy()` hardcodes index 3** (`carousel.cpp:160-164`). If buddy moves, fix it —
  it is the wake-on-prompt entry point, so a wrong index sends the user to the wrong screen.
- **Every page is built at theme-apply time**, not lazily (`on_theme()`, `carousel.cpp:43`). A new
  screen costs its widget tree in the LVGL PSRAM pool permanently, on every theme. See `docs/perf.md`
  §4 before adding anything heavy.
- **The screenshot sweep picks it up for free** — `carousel_count()`/`carousel_screen_id()` are
  generic, so `env:capture` will emit 7 new PNGs (7 themes x the new screen).
- Time comes from `now_s()` (wall, for staleness) or `uptime_s()` (monotonic, for timeouts). Never a
  local `millis()` clock — that split-brains ages.

---

## 2. Add a per-theme view to an existing screen

Only relevant if a view file is missing (all 35 exist today). Same as §1 step 1, single file. No
registration — `SCREEN_MODULE_SIMPLE` already references the symbol by name, so creating the file
with the right symbol is the whole job.

---

## 3. Add a theme

More invasive than it looks: **5 new view files (one per screen) + 5 edits.**

1. `src/ui/theme_catalog.h` — append a `theme_catalog_t` row, bump `THEME_COUNT`. Pick a
   `gauge_style_t`; reuse an existing one unless you're also writing a new gauge.
2. `src/ui/theme.cpp` — append a row to `THEME_FONTS[THEME_COUNT]` mapping
   `f_hero/f_display/f_body/f_mono`. This is a **parallel array indexed by theme index**: bumping
   `THEME_COUNT` without adding the row is an out-of-bounds read the compiler won't catch (it is a
   `static const` array sized by the macro, so it just zero-fills and you get a null-font crash on
   switch). `f_mono` is JetBrains Mono for every theme. Fonts must already exist in `src/ui/fonts/`
   (see `fonts.h` + `MANIFEST.md`); generating a new glyph subset is its own task via `gen_fonts.sh`.
3. `src/ui/screens/screen_module.h` — the `SCREEN_MODULE_SIMPLE` macro **hardcodes the 7 view names
   in catalog order**. Add the 8th `extern` and the 8th `V[]` entry. Order must match
   `THEME_CATALOG` exactly; `theme_index()` indexes straight into `V[]`.
4. `src/ui/chrome.cpp` — `kind_for()` maps theme index => background chrome. Add a case or fall
   through to `CH_NONE`.
5. `src/ui/screens/views/<screen>_<newtheme>.cpp` x 5 (home, finance, usage, buddy, settings).
6. `firmware/test/test_theme/` — the suite asserts catalog invariants; extend it.
7. `DESIGN.md` — add the theme to the catalog table. It is the authority for token values.

### The `dotmatrix` / `calm` naming trap
Theme index 2's catalog `id` is **`"dotmatrix"`** but its view files are named **`*_calm.cpp`** and
its view symbols are `<screen>_calm_view`. Both are load-bearing: the id is what NVS and the theme
picker show, the `calm` suffix is what `SCREEN_MODULE_SIMPLE` links against. Don't "fix" one without
the other. Prefer matching id and suffix for any new theme.

---

## 4. Add or change a hub -> device frame field

Seven places, and they must agree or the field silently vanishes.

1. **`hub/CONTRACT.md` §A** — document the field first. Say whether it is emitted always or only in
   its meaningful state (the convention: optional extras like `qlen`/`stale` are emitted **only when
   set**, so absent means default).
2. **`firmware/src/core/records.h`** — add the field to the record struct and a `*_LEN` cap for any
   string. Strings are fixed-capacity NUL-terminated; writers truncate.
3. **`firmware/src/core/hub_proto.cpp`** — parse it in `hub_parse_status` / `hub_parse_sessions` /
   `hub_parse_loc`. Use `copy_trunc()` for strings and `| default` for scalars so an absent field
   degrades instead of failing the frame.
4. **`firmware/test/test_hub_proto/`** — assert the new field, and assert the absent case yields the
   default.
5. **`hub/Sources/BeaconHubKit/Protocol.swift`** — add it to the `Codable` struct. For
   emit-only-when-set semantics the property **must be `Optional` and `nil`, not `false`** —
   synthesized `Codable` omits `nil` but encodes `false` (see the comment on `ProviderUsage.stale`).
6. **`hub/Tests/BeaconHubKitTests/ProtocolTests.swift`** — round-trip it.
7. **The producer** — usually `ProviderMux.publish*()`, occasionally `AppDelegate`.

### Frame budget (the trap that already bit once)
`HUB_FRAME_MAX` is **1024 B** and the device **drops** a longer frame silently. A combined
`usage`+`buddy`+`loc` frame already runs ~600 B. This is exactly why `sessions` is a **standalone
frame**, not a `buddy` sub-object (`CONTRACT.md` §A). If your addition is an array, give it its own
frame or chunk it at ~900 B like `config`/`report` do.

Version discipline: additive optional fields ride `"v":1`. A breaking change (like `usage.claude` =>
`usage.providers`) means old firmware shows unavailable until reflashed — call that out in
`CONTRACT.md` under Migration.

---

## 5. Add a device -> hub command (the "better controls" path)

This is the path for any new on-device control that acts on the Mac. Existing examples:
`permission` (`hub_task.cpp:190`) and `open` (`hub_task.cpp:224`) — read `open` first, it's the
smaller of the two.

**Device side**
1. `src/core/hub_proto.h` + `.cpp` — a `hub_build_<cmd>()` that fills a `JsonDocument` and returns
   `finish_frame(doc, buf, cap)` (JSON + `'\n'`). Keep `buf` small and stack-allocated at the caller.
2. `src/core/hub_task.cpp` — an exported action function that builds, sends via `g_link->send()`, and
   handles `g_link == nullptr` (the `BEACON_DEV`/native path has no link — return success and clear
   locally, as `buddy_decide` does).
3. If it needs local in-flight state (pending/ok/failed), add it to `records.h` as **device-local,
   not serialized** — follow `open_state`/`OPEN_*` and its `ds_set_open_pending` /
   `ds_apply_open_ack` / `ds_tick_open` trio in `datastore.cpp`. Tick it from the `hub_task` loop.
4. The tap handler in the relevant view calls your action function. Guard rails belong in the action
   function, not per-view — `buddy_decide` folded seven per-view checks into one canonical guard for
   exactly this reason.
5. `firmware/test/test_hub_proto/` — assert the built frame bytes.

**Hub side**
6. `Protocol.swift` — add a `DeviceCommand` case and a `parse` branch. Validate every field; return
   `nil` on anything malformed (an unknown `cmd` already returns `nil`, so an **older hub ignores your
   new command harmlessly** — that forward-compat is free, don't break it).
7. `AppDelegate.handle(_:)` — add the case. Do the work off-main if it touches AppleScript / process
   spawn / the filesystem (see the `.open` case), then reply on main.
8. Reply with `HubAck.ack(id:ok:)` or `HubAck.err(id:reason:)` if the device needs confirmation.
9. `hub/Tests/BeaconHubKitTests/ProtocolTests.swift` — parse tests, including malformed input.
10. `hub/CONTRACT.md` §B — document the command, its ack, and its error reasons.

### Ack routing trap
`hub_parse_ack` is **id-keyed and shape-agnostic**: `on_frame` hands every ack to *both*
`apply_ack` (prompt `p<n>` ids) and `ds_apply_open_ack` (session `s<n>` ids), each of which no-ops on
a non-matching id (`hub_task.cpp:116-123`). A third acked command needs its own no-op-on-mismatch
handler added to that same fan-out — there is no dispatch table, so forgetting it means your ack is
silently dropped.

### Prefer an existing channel where one fits
- A **new setting the hub owns** may fit the `config` frame pattern (chunked full-snapshot replace +
  one ack per `rev`) rather than a new command. That pattern already handles NVS persistence,
  fail-closed validation, and live re-apply.
- A **new hub-side capability per provider** belongs in `ProviderCapabilities` (§7), not a bespoke
  command.

---

## 6. Add a device-plane fetch source

1. `src/fetch/parse_<x>.{h,cpp}` — **pure** parse function over a `(const char*, size_t)` body. No
   Arduino, no networking. This is the part that gets tested.
2. `src/fetch/<x>.{h,cpp}` — the HTTP half: call `net_https_get(...)` into `fetch_scratch()` (a
   shared 8 KB buffer — do not allocate your own), then hand the body to the parser, then
   `ds_set_*()`. Return a `data_err_t`.
3. `src/core/records.h` — a new record type if it isn't weather/finance, embedding `record_hdr_t`
   **first**.
4. `src/core/datastore.{h,cpp}` — setter, getter, a `ds_set_state_*` failure transition, and a branch
   in `ds_tick_staleness`.
5. `src/core/fetch_task.cpp` — a slot index, `cadence_of()`, `slot_host()` (must return the exact
   host string you pass to `net_https_get`, or you lose TLS socket reuse), and `run_slot()`.
6. `src/config/root_ca.h` — add the root CA if the host's chain isn't already covered. **Never
   `setInsecure()`.** The bundled set is listed in `tech.md` §6.
7. `platformio.ini` — add `+<fetch/parse_<x>.cpp>` to `build_src_filter` under `[env:native]`, else
   your test suite won't link.
8. `firmware/test/test_<x>_parse/` — fixtures for the happy path, a malformed body, and an empty body.
9. `docs/tech.md` §6 cadence table — add the row.

---

## 7. Add a hub provider (a new agent ecosystem)

Follow `HookBuddyProvider` — Codex and omp both use it unchanged, differing only in descriptor,
route path, and cap seconds (`AppDelegate.swift:262-281`). A genuinely new ecosystem usually needs
only a descriptor + a route + an installer.

1. `BeaconHubKit/<X>Hooks.swift` — the managed config the installer writes (a TOML block, an
   extension file, a settings merge) and its route path constant. Keep it a pure string generator so
   it is testable.
2. `beacon-hub/HooksInstaller.swift` — an `install(providerID:)` branch. Idempotent, marker-delimited,
   timestamped `.bak` before any write.
3. `BeaconHubKit/HooksDetection.swift` — an `isInstalled` branch. Detection must check **every** piece
   the provider needs (Claude requires both the hook URL *and* the statusline shim), or Settings shows
   a false green.
4. `beacon-hub/AppDelegate.swift` `startProviders()` — construct it with a `ProviderDescriptor`
   (`id` <= 12 chars lowercase ascii, `label` <= 10 chars) and the right `capabilities`, add it to
   `providers`, wire `onPromptUndeliverable`.
5. Pick `capSeconds` by working **inward from the agent's own timeout**: hub cap < transport timeout <
   agent hook ceiling, so the hub's deny always reaches a still-open socket. Get this backwards and
   the provider degrades to fail-open. Chains in use: Claude/Codex `hub 575 < curl 585 < hook 590`;
   omp `device 25 < hub 26 < fetch 28 < handler 30`.
6. Decide the **no-verdict** behavior and document it. `{}` means "no gate" — Claude and Codex fall
   back to their own prompt; omp does **not** (it has no ask escalation and its own approval already
   ran), which is why the omp extension fails **closed** on every transport error. Getting this wrong
   either blocks the user's tools or runs commands unattended.
7. `hub/CONTRACT.md` §C — record the verified upstream shapes, with a version/commit you checked
   against.
8. Tests in `hub/Tests/BeaconHubKitTests/<X>HooksTests.swift`.

New capability planes (beyond usage/sessions/prompts) go in `ProviderCapabilities` +
`EnabledCapabilities` + the Settings toggle columns, and must be gated in `ProviderMux.publish*()`.

---

## 8. Add a settings row / persisted device setting

1. `src/core/nvs.{h,cpp}` — a typed getter/setter with an explicit default. NVS keys are <= 15 chars.
2. The consumer reads it at the point of use; `main.cpp` restores it at boot if it affects hardware
   (see `display_brightness(nvs_get_brightness(204))`).
3. `src/ui/screens/views/settings_<theme>.cpp` x 7 — the row. Interactive rows follow the existing
   pattern; **a tap that rebuilds the screen must be deferred** with `lv_async_call`, because
   `theme_set()` deletes the very object handling the event:
   ```cpp
   static void do_next_theme(void*){ theme_set((theme_index()+1)%THEME_COUNT); }
   // in the tap handler:
   lv_async_call(do_next_theme, NULL);
   ```
4. A richer control goes in an overlay panel (`theme_panel.cpp`, `wifi_panel.cpp`,
   `duration_panel.cpp` are the models) rather than inline in 7 view files.

---

## 9. Working on the UI without a camera

```bash
cd firmware
~/.beacon-pio/bin/pio run -e capture -t upload
~/.beacon-pio/bin/pio device list
python3 tools/capture/grab.py --port /dev/cu.usbmodemXXXX --out shots/ --montage
```
Streams the literal RGB565 strips LVGL flushed to the glass — 35 PNGs (7 themes x 5 screens) plus a
contact sheet. `BEACON_DEV=1` seeds deterministic data, so screens are always populated and runs are
comparable. Needs `pip install pyserial pillow numpy`. Don't hold the port open in
`pio device monitor` at the same time. `env:capture` is never shipped.

---

## 10. Conventions that are easy to violate

- **ASCII only** in firmware source and comments (`=>`, not the arrow glyph).
- **No hardcoded colors or fonts in views** — read `theme_active()` tokens or the shared `S` styles.
- **No object creation in a view's `update()`** — build creates, update mutates text/values/visibility.
- **Don't draw the page background** in a view; `chrome_attach()` already did.
- **Never feed `pct < 0`** to a bar/arc — `-1` means unavailable, render `"--"` and no fill.
- **`SAFE_INSET` (40 px) is a floor**, and nothing tappable may sit in a corner arc.
- **Hub: no force-unwraps outside tests**; never log a token or a command `hint`.
- **Commits** are Conventional Commits with scope `firmware`/`hub`/`docs`/`ci`; branches are
  `<type>/<issue#>-<kebab-summary>`. See `CONTRIBUTING.md`.
- **Docs reflect current state, not history** — edit the statement, don't append a changelog.

---

## 11. Add a Home complication

A complication is a Phase-1 renderer occupying 1 or 2 of Home's six slots (`docs/specs/2026-07-27-hub-
app-and-home-complications-design.md` §4-§5; `docs/plans/2026-07-27-home-complications-plan.md` §3-§4).
Five places, in order:

1. **`firmware/src/core/complications.cpp`** — add a row to `COMP_CATALOG[]`: `{ id, size, takes_arg }`.
   This is the **one and only** home of `size`/`takes_arg` (plan §13 item 1, settled) — do not restate
   either on `complication_t` in `comp_registry.h`, and do not let the resolver or the stack re-derive
   them; `comp_stack.cpp`'s `catalog_size()` and `comp_list_resolve()` both read this array. `id` <= 11
   chars, `[a-z0-9_-]`.
2. **`firmware/src/ui/comps/comp_<id>.cpp`** — the renderer. One file, file-static widget pointers,
   exactly `{build, update}` — the same one-instance-per-id contract a view uses
   (`screens/views/CONVENTIONS.md`); no `comp_inst_t`, never create an object in `update()`. Position
   every element at the container-LOCAL offsets in `comp_registry.h`'s table — don't re-derive them or
   hardcode the page-absolute equivalent. If your renderer is shape A (name/value/change, optionally a
   trend glyph) or shape B (icon + two lines), reuse `comp_build_shape_a`/`comp_build_shape_b` from
   `comp_common.h` rather than laying the widgets out by hand — that duplication is exactly what the
   2026-07-27 convergence sweep collapsed out of `comp_fin`/`comp_ice`/`comp_usage`/`comp_weather` and
   `comp_agents`/`comp_sonos`. Handle every non-live state via `state_view.h` (`sv_status`/`sv_dim`/
   `sv_placeholder`), and use `txt_set`/`txt_color`/`hidden_set` (`screens/screen_common.h`) so the
   500 ms tick stays diff-aware.
3. **`firmware/src/ui/comps/comp_registry.cpp`** — add the `extern const complication_t comp_<id>_reg`
   and append it to `COMP_REGISTRY[]`. `comp_find(id)` walks this array; an id present in
   `COMP_CATALOG` but absent here (no renderer yet, e.g. `chart` in Phase 1) is a **supported** state —
   the resolver just drops it.
4. **`hub/Sources/BeaconHubKit/Complications.swift`** — add the matching row to `ComplicationCatalog.all`
   (id, owner, label, size, takesArg). The hub's copy is a **preview with no compiler check against the
   device's** (the same class of drift `PageCatalog` already carries) — a checked-in fixture test
   (`ComplicationsTests.swift`) is the mitigation until Phase 3's device-reported registry; keep it in
   sync by hand until then. The device's registry always wins on a mismatch (design §6.4) — never add a
   wire field for size to "fix" this from the hub side.
5. **Tests** — `firmware/test/test_comp_list/`: extend the catalog-shape assertions if resolution rules
   are affected. Hub: extend the `ComplicationCatalog` fixture test with the new row, including its size.
   There is no `ui/comps/*.cpp` native test (LVGL-coupled, not host-linkable, `platformio.ini`'s native
   `build_src_filter` excludes the whole directory) — `test_comp_geom` covers only the shared geometry
   constants, not a specific renderer's pixels; prove those on hardware (`env:capture`, recipe §9).

### Traps
- **A complication may only read a record the device already maintains for reasons independent of the
  page list. A complication must never be the thing that causes a fetch** (`hub/CONTRACT.md` §A3). If
  your data isn't already in `DataStore` for some other reason, this is the wrong recipe.
- **`owner` is hub metadata, never a gate.** `comp_list_resolve` does not consult it, and neither may
  your renderer or the registry — the entire point of a complication is surviving its owning page being
  hidden. Do not add an `owner`-driven early return.
- **Not tappable in Phase 1** (design §9.2, provisional) — `comp_stack.cpp` clears
  `LV_OBJ_FLAG_CLICKABLE` on every container; don't add a click handler that implies otherwise.
- **The separator rule is the STACK's decision, not the renderer's** (`comp_stack.cpp`
  `build_containers`): none at slot 1, one at local y 0 otherwise. Don't draw your own.
- **One instance per id, enforced at the hub editor**, not on the device — `comp_list_resolve`'s
  duplicate-collapse rule (first occurrence wins) is the device-side backstop, not the primary UX.
- If your complication takes an `arg` (a ticker id, a provider id, …), validate it against
  `CompLimits.allowed` **at the hub editor boundary** (`ComplicationEditor.swift`) — the device-side
  `comp_entry_valid` drop is a defence, not the first line (design §10.7).
