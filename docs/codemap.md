# Beacon — code map

> **What this is:** a concern => file index, plus end-to-end traces of the four data paths. Read this
> before touching code so you edit the right file the first time. Verified against the tree at
> `4850e04` (2026-07-26).
>
> **Companions:** `AGENTS.md` (conventions) · `docs/tech.md` (NFRs + frozen contracts) · `DESIGN.md`
> (visual system) · `hub/CONTRACT.md` (wire schema) · `docs/recipes.md` (step-by-step task playbooks)
> · `docs/perf.md` (render pipeline + budgets).

---

## 1. Counts you'll want up front

| Thing | Count | Source of truth |
|---|---|---|
| Carousel screens | 6 (home, finance, ice, usage, buddy, settings) | `firmware/src/ui/carousel.cpp` `MODULES[]` |
| Themes | 7 | `firmware/src/ui/theme_catalog.h` `THEME_COUNT` |
| Per-theme views | 42 (6 screens x 7 themes) | `firmware/src/ui/screens/views/` |
| Firmware host tests | 30 suites / 191 cases | `firmware/test/test_*/` |
| Hub tests | 216 cases | `hub/Tests/` |
| Device->hub commands | 4 (`permission`, `open`, `config_ack`, `report`) | `hub/Sources/BeaconHubKit/Protocol.swift` `DeviceCommand` |
| Hub->device blocks | 5 (`usage`, `buddy`, `loc` share the status frame; `sessions` and `config` are standalone frames) | `hub/CONTRACT.md` §A/§B2 |
| Hub providers | 3 (claude, codex, omp) | `hub/Sources/beacon-hub/AppDelegate.swift` `startProviders()` |

Hard caps worth knowing before you design: **8 screens** (`s_pages[8]`/`s_dots[8]` in `carousel.cpp`),
**16 tickers** (`MAX_TICKERS`), **4 usage providers** (`USAGE_PROVIDERS_MAX`), **5 sessions**
(`BUDDY_SESSIONS_MAX`), **3 buddy entries** (`BUDDY_ENTRIES`), **1024 B** per BLE frame
(`HUB_FRAME_MAX`).

---

## 2. Firmware — concern => file

### Boot / wiring
| Concern | File |
|---|---|
| `setup()`/`loop()` wiring, boot order, provisioning overlay | `src/main.cpp` |
| Panel + safe-area geometry (`SCREEN_W/H`, `SAFE_INSET`, `CORNER_R`, GRAM offsets) | `src/config/layout.h` |
| Build flags, pinned lib versions, native-test source filter | `platformio.ini` |
| LVGL compile config (color depth, refresh period, custom heap) | `src/lv_conf.h` |
| Firmware version string (injected by `version.py`) | `src/config/version.h` |

### HAL (`src/hal/`)
`power.cpp` AXP2101 rails (must init before display) · `display.cpp` CO5300 QSPI + DCS brightness
(`0x51`) · `touch.cpp` CST92xx · `imu.cpp` QMI8658 · `audio.cpp` ES8311 (spike-only, behind
`BEACON_AUDIO_SPIKE`).

### Core (`src/core/`)
| Concern | File |
|---|---|
| **Record schema** (all domain structs + string caps + prompt/session enums) | `records.h` |
| State enum + the state-priority rule | `screen_state.h` |
| Thread-safe pub/sub store; setters/getters/staleness sweep/prompt ticks | `datastore.{h,cpp}` |
| BLE frame parse + build (all of it) | `hub_proto.{h,cpp}` |
| Hub-plane task: BLE loop, frame dispatch, `buddy_decide`/`buddy_open` | `hub_task.cpp` |
| `HubLink` transport interface (screens depend on this, not on BLE) | `hublink.h` |
| BLE peripheral implementation of `HubLink` | `hublink_ble.cpp` |
| Device->hub ticker report chunk planner | `hub_report.cpp` |
| Device-plane scheduler (weather + tickers + staleness, 1 Hz) | `fetch_task.cpp` |
| WiFi multinetwork, TLS socket reuse, `net_https_get` | `net.cpp` |
| `Beacon-setup` captive portal | `provision.cpp` |
| NVS persistence (theme, brightness, screen, tickers, wifi) | `nvs.cpp`, `config/ticker_store.cpp` |
| RTC + NTP + tz; `now_s()`/`uptime_s()` definitions | `timekeep.cpp`, `tz_map.cpp` |
| Location precedence (hub > NVS > IP geo) | `location.cpp` |
| Pure idle-phase decision (host-tested) | `idle.cpp` |

### UI (`src/ui/`)
| Concern | File |
|---|---|
| LVGL port: draw buffer, `flush_cb`, `rounder_cb`, touch indev | `lvgl_port.cpp` |
| LVGL heap redirected to PSRAM | `lv_mem_psram.cpp` |
| Carousel: page objects, swipe/snap, 500 ms tick, theme rebuild | `carousel.cpp` |
| Pure carousel index math (host-tested) | `carousel_nav.h` |
| Runtime theme struct + `theme_set`/`theme_active`/`theme_index` | `theme.{h,cpp}` |
| **Theme token values + `THEME_COUNT` + default** | `theme_catalog.h` |
| Shared prebuilt styles (`S.eyebrow`, `S.hero`, ...) | `styles.{h,cpp}` |
| Per-theme background chrome (grid/blueprint/dots/graticule) | `chrome.cpp` |
| Token-switched gauge component (7 visual styles) | `gauge.cpp`, `gauge_style.h` |
| State-chip / dim / placeholder / age / countdown helpers | `state_view.h` |
| Screen + view function-pointer contracts | `screen.h` |
| The 7-view dispatch macro | `screens/screen_module.h` |
| Screen modules (4 lines each) | `screens/screen_<name>.cpp` |
| **The actual layouts** | `screens/views/<screen>_<theme>.cpp` |
| Shared view render helpers (clock, session rows) | `screens/views/view_common.h` |
| Per-screen record-field guide + LVGL 8.4 do/don't | `screens/views/CONVENTIONS.md` |
| Overlays: pairing passkey, wifi manager, theme picker, about, duration | `pair_overlay.cpp`, `wifi_panel.cpp`, `theme_panel.cpp`, `about_panel.cpp`, `duration_panel.cpp` |
| Screenshot harness (`env:capture`) | `capture.cpp` + `tools/capture/grab.py` |
| Fake-data seeder (`BEACON_DEV=1`) | `dev_seed.cpp` |

### Fetch (`src/fetch/`)
`weather.cpp`/`parse_weather.cpp` (Open-Meteo) · `finance.cpp`/`parse_finance.cpp` (Yahoo + Binance
mirror) · `geoip.cpp`/`parse_geoip.cpp` · `ice.cpp`/`parse_ice.cpp` (ICE D4 RIN futures; endpoint +
cadence in `config/ice.h`). **The `parse_*.cpp` half is pure and host-tested; the
non-parse half does the HTTP.** Keep that split when adding a source.

---

## 3. Hub — concern => file

`BeaconHubKit/` is pure and host-testable (no CoreBluetooth, no networking). `beacon-hub/` is the
menubar agent. Anything you want tested belongs in the kit.

### BeaconHubKit (pure)
| Concern | File |
|---|---|
| **Wire types + `DeviceCommand.parse` + `HookResponse` + `HubAck`** | `Protocol.swift` |
| Provider identity/capabilities/toggle persistence | `Providers.swift` |
| Cross-provider aggregator; short-id minting; merged frames | `ProviderMux.swift` |
| Session state machine + TTL reap | `SessionRegistry.swift` |
| Prompt FIFO queue + `qlen` + late/unknown routing | `PromptBroker.swift` |
| Claude/Codex raw usage => normalized `{pct, reset}` | `UsageNormalizer.swift` |
| Last-known-good retention, stale flag, user-facing notes | `UsageReducer.swift`, `UsagePollDecision.swift` |
| Ticker list model, chunked `config` encoder, validation, catalogs | `TickerConfig.swift`, `TickerCatalog.swift`, `TickerValidation.swift`, `TickerConfigState.swift` |
| Device ticker-report reassembly | `ReportAssembler.swift` |
| Codex managed-`config.toml` block + trust hashes | `CodexHooks.swift` |
| omp managed extension source (`beacon.ts`) | `OmpHooks.swift` |
| Claude/Codex/omp hooks-installed detection | `HooksDetection.swift` |
| Per-session terminal/editor handles for tap-to-open | `HostContext.swift` |
| First-pair failure escalation budget | `PairingEscalation.swift` |

### beacon-hub (app)
| Concern | File |
|---|---|
| **Everything wired together**; frame send; heartbeat; command handling | `AppDelegate.swift` |
| CoreBluetooth central, link phases, chunked writes, line reassembly | `BeaconCentral.swift` |
| localhost HTTP server on `127.0.0.1:8765`, path routes | `LocalIngestServer.swift` |
| Claude provider: hooks + statusline + oauth usage | `ClaudeCodeProvider.swift` |
| Generic hook-driven provider (Codex + omp share it) | `HookBuddyProvider.swift` |
| Usage poll loop across providers | `UsagePoller.swift` |
| Claude token refresh ladder | `ClaudeTokenRefresher.swift` |
| Menubar menu + view model | `MenubarController.swift`, `HubViewModel.swift` |
| Settings window / panels / ticker editor | `SettingsPanel.swift`, `HubPanel.swift`, `TickerEditorView.swift` |
| Per-provider hooks install | `HooksInstaller.swift` |
| Tap-to-open focus tiers (Warp url > editor reuse > bundle open) | `SessionFocus.swift` |
| CoreLocation fix => `loc` frame | `LocationProvider.swift` |
| Login item (`SMAppService`) | `LoginItem.swift` |

---

## 4. The four data paths, end to end

### A. Device-plane data (weather, finance) — no hub involved
```
fetch_task (Core 0, 1 Hz)
  -> picks the oldest-due slot, preferring one on the already-open TLS host (#61)
  -> fetch_weather() / fetch_finance(i)   [net.cpp: one TLS socket, serialized]
  -> parse_weather.cpp / parse_finance.cpp  (pure, host-tested)
  -> ds_set_weather() / ds_set_finance_if()   [forces ST_LIVE, stamps last_updated]
  -> ds_tick_staleness(now)  promotes ST_LIVE => ST_STALE at the source's stale_s
carousel tick_cb (Core 1, 500 ms, paused while idle)
  -> MODULES[current]->update() -> view update() -> ds_get_*() by-value snapshot
```

### B. Hub-plane data (usage, buddy, sessions, loc)
```
Claude/Codex/omp hook or statusline POST
  -> LocalIngestServer route (127.0.0.1:8765)
  -> provider (ClaudeCodeProvider / HookBuddyProvider) -> ProviderSink
  -> ProviderMux merges + dedups -> onUsage / onBuddy / onSessions
  -> AppDelegate.sendFrame(StatusFrame(...)) / SessionsFrame(...).encoded()
  -> BeaconCentral.send()  [chunked to MTU, .withResponse]
--- BLE ---
  -> hublink_ble RX -> hub_reassembler_feed (split on '\n')
  -> hub_task.on_frame()  [ack? config? loc? sessions? else status]
  -> hub_parse_status / hub_parse_sessions / hub_parse_loc
  -> ds_set_usage / ds_set_buddy / ds_apply_sessions / location_set_from_hub
  -> screens read via ds_get_usage() / ds_get_buddy()
```
Resend triggers: `onReady` (re)connect full frame (+`loc`, +sessions, +ticker config), 30 s heartbeat
(no `loc`), and any mux change.

### C. Permission round-trip (device -> hub -> agent)
```
view tap  -> buddy_decide(approve)          [hub_task.cpp: the single canonical guard]
  -> hub_build_permission() -> g_link->send()
  -> DeviceCommand.parse -> AppDelegate.handle(.permission)
  -> ProviderMux.resolve(shortId:) -> broker route -> provider.resolvePrompt(nativeID:)
  -> provider fulfills the HELD HTTP connection with HookResponse.permission(...)
  -> AppDelegate sends HubAck.ack(ok:) / HubAck.err
  -> device hub_parse_ack -> hub_apply_ack -> PROMPT_SENT_OK | PROMPT_TOO_LATE
  -> ds_tick_buddy_prompt clears after BUDDY_CONFIRM_HOLD_S
```
Fail-safe ladder: device shows `BUDDY_PROMPT_EXPIRY_S` 590 s; hub caps per provider (Claude/Codex
~575-590 s, omp 26 s); a prompt the device never showed returns **no verdict**, never a deny.

### D. Ticker config (hub -> device) and report (device -> hub)
```
hub: TickerEditor -> tickerStore.save (bumps rev) -> ConfigFrame.chunks (<=900 B each) -> send
device: hub_parse_config_chunk -> hub_config_accum_step -> ticker_table_apply (NVS)
        -> ds_reseed_finance (new ids, ST_LOADING) -> ticker_table_gen() bump
        -> fetch_task rebuilds its slot set, marks all finance due
        -> hub_build_config_ack -> hub
device (once per connection, after the first inbound frame):
        hub_report_plan/hub_build_report_frame -> cmd:"report" chunks
hub:    ReportAssembler -> adopted ONLY if tickerStore.isPristine (rev 0, no rows)
```

---

## 5. Test topology

**Firmware (`env:native`, Unity, no Arduino/LVGL).** One folder per suite, each with its own
`main()`. Device-only code is fenced with `#if !BEACON_NATIVE`. A non-header-only source must be
listed in `platformio.ini`'s `build_src_filter` to be linked into test binaries — forgetting this is
the usual "undefined symbol" in a new suite.

```bash
~/.beacon-pio/bin/pio test -e native                      # all 29 suites
~/.beacon-pio/bin/pio test -e native -f "*test_hub_proto*" # one
```

**Hub (XCTest).** `BeaconHubKitTests` for pure logic (the bulk); `beacon-hubTests` for app-target
types that still avoid CoreBluetooth.

```bash
cd hub && swift test
```

**What is *not* covered by either:** LVGL layout, real BLE, real HTTP, the AXP/CO5300 bring-up. Those
need hardware — `pio run -t upload` + `pio device monitor`, or the `env:capture` screenshot sweep for
visual review.

---

## 6. Known doc/code drift (as of `4850e04`)

Cross-check these before trusting a doc statement:

| Doc says | Code actually does | Where |
|---|---|---|
| "two draw buffers, each ~1/10 screen" (`tech.md` §6) | **one** buffer, 466x47, in PSRAM — `flush_cb` is synchronous so B was dead weight (#65 M1) | `ui/lvgl_port.cpp:11-20` |
| "Only the visible screen is built" (`tech.md` §6) | `on_theme()` builds **all 5** pages and updates each; only `update()` is visible-only | `ui/carousel.cpp:43-54` |
| Repo layout `firmware/beacon/src/` (`tech.md` §12) | actual is `firmware/src/` | tree |
| Screen ids include `"NOW"` (`ui/screen.h:25`) | no now-playing screen exists (deferred past P4) | `ui/carousel.cpp:16` |
| Python **3.13** required (`firmware/README.md`) | any 3.10-3.13 works; this machine's venv is 3.12 | `~/.beacon-pio` |
| Buddy hook timeout "~30s" (`DESIGN.md` §Coding Buddy) | ~590 s hold for Claude/Codex, 26 s for omp | `hub/CONTRACT.md` §D |
| Theme id is `dotmatrix`; view files are named `*_calm.cpp` | both are correct and both are load-bearing — see `docs/recipes.md` §3 | `theme_catalog.h:36` vs `views/` |
