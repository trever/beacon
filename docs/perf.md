# Beacon — performance: pipeline, budgets, and how to measure

> **What this is:** the render/task pipeline as built, the measured budgets, and the instrumentation
> that exists. `docs/tech.md` §8 owns the NFR *targets*; this documents the *implementation* and how to
> check it. Numbers below are from this tree unless marked as a spike measurement.
>
> Build measured 2026-07-26, `env:beacon`, Arduino core 3.3.5 / LVGL 8.4.0:
> **static RAM 77,188 B of 327,680 (23.6%)** · **flash 1,923,151 B of a 3,145,728 B OTA slot (61.1%)**.
> On-device: free internal heap steady **114,484 B**, since-boot minimum **49,832 B**, PSRAM free
> **8.29 MB**. Swipe render: **~9.6 full-screen frames/s**, blit **29.5 ms/frame**, render
> **~49 ms/frame** (§2.1).

---

## 1. Task and core model

| Task | Core | Period | Stack | Work |
|---|---|---|---|---|
| `loop()` (Arduino) | 1 | `delay(5)` per iteration | default | `lv_timer_handler()`, provisioning, RTC writes, idle, IMU poll |
| `fetch` | 0 | 1000 ms | 8 KB | one HTTPS fetch per tick at most, staleness sweep, WiFi service |
| `hub` | 0 | 20 ms (50 Hz) | 8 KB | BLE loop, frame dispatch, prompt/open lifecycle ticks |

The contract that makes this work: **no I/O ever blocks Core 1.** Fetchers publish by-value snapshots
into `DataStore` under a short lock; the UI only ever reads snapshots. A slow TLS handshake or a
30-second BLE stall cannot stutter the render loop.

`fetch_task` deliberately does **one** fetch per second-tick rather than a sweep, and serializes on a
single TLS socket — internal SRAM, not CPU, is the constraint (§3).

---

## 2. Render pipeline

```
loop()  -> lvgl_port_tick() -> lv_timer_handler()
          -> LVGL invalidation -> partial render into ONE draw buffer (PSRAM, big-endian RGB565)
          -> rounder_cb  (snap flush window to even coords -- CO5300 requirement)
          -> flush_cb    -> DISPLAY_BLIT -> draw16bitBeRGBBitmap -> writeBytes
                            -> spi tx_buffer = the PSRAM buffer itself [blocking QSPI @80 MHz]
                         -> lv_disp_flush_ready()
```

Key facts, all in `src/ui/lvgl_port.cpp` and `src/lv_conf.h`:

- **One draw buffer**, `466 x 47 px x 2 B = 43,804 B`, allocated in **PSRAM** (`BEACON_LVGL_PSRAM`).
  A second buffer was removed (#65 M1): `flush_cb` is synchronous, so LVGL never renders into B while
  A is flushing — B was pure dead weight. *(`tech.md` §6 still describes two buffers; the code is the
  truth.)*
- **The LVGL heap is also in PSRAM** — `LV_MEM_CUSTOM 1` routed to `lv_mem_psram.cpp`. All widget
  objects and styles live there, which is why 5 resident screens x 7 themes' worth of layout is
  affordable at all.
- `LV_DISP_DEF_REFR_PERIOD 30` ms caps the refresh at **~33 FPS**; `LV_INDEV_DEF_READ_PERIOD 30` ms
  caps touch sampling. `delay(5)` in `loop()` means LVGL is pumped ~200x/s, so the 30 ms period is the
  real governor — the target is >=30 FPS (`tech.md` §8), so this is deliberately just above it.
- **Partial render only. There is no full-screen framebuffer.** A full-screen repaint is ~10 flush
  strips; anything that dirties the whole screen every tick costs 10 QSPI blits.

### 2.1 The blit path (measured — do not "simplify" this)

`flush_cb` selects its blit via `DISPLAY_BLIT` in `ui/lvgl_port.cpp`, and that selector is
**hard-paired with `LV_COLOR_16_SWAP`**:

| `LV_COLOR_16_SWAP` | LVGL renders | flush calls | cost |
|---|---|---|---|
| `0` (library default) | native-endian RGB565 | `draw16bitRGBBitmap` | byte-swaps **every pixel** out of PSRAM into a 2 KB staging buffer before each blocking QSPI chunk |
| **`1` (this build)** | big-endian RGB565 | `draw16bitBeRGBBitmap` | `writeBytes` sets `spi tx_buffer` to the PSRAM buffer directly — **no per-pixel pass, no copy** |

Changing one without the other reverses every pixel's colour bytes. Both are set in
`platformio.ini` `[env:beacon]`, with `ESP32QSPI_FREQUENCY=80000000` (the GFX library defaults to
40 MHz; 80 is verified on glass).

Measured on the `env:perf` auto-swipe benchmark (§5), full-screen repaints:

| Build | blit/frame | throughput | frames/s |
|---|---|---|---|
| Library default (40 MHz, swapping blit) | 59 ms | 7.4 MB/s | 7.5 |
| + zero-copy BE blit | 40 ms | 10.9 MB/s | ~9 |
| + QSPI 80 MHz (**current**) | **29.5 ms** | **14.7 MB/s** | **~9.6** |

Two findings worth keeping:
- **The bus was never the original bottleneck** — 7.4 MB/s against a ~20 MB/s ceiling. The software
  byte-swap was ~60% of blit time. Raising the clock first would have looked disappointing.
- **S3 SPI DMA can source from PSRAM.** The zero-copy path proves it; no bounce buffer needed.
- Also verified heap-neutral and TLS-safe: 120 s soak with WiFi up, handshakes to Open-Meteo and
  Yahoo succeeding, zero warnings, heap unchanged from the pre-change figures.

**Render, not blit, is now the ceiling.** Splitting `lv_timer_handler()` gives ~49 ms render vs
~29 ms blit per frame. LVGL rasterising into a *PSRAM* draw buffer dominates, so even a free blit
caps out near 20 FPS — the 30 FPS NFR (`tech.md` §8) is not reachable for a full-screen slide by
shaving the bus further. The open options are a smaller **internal-SRAM** draw buffer (hazardous —
§3) or a cheaper page transition (crossfade/instant instead of a slide), which is a `DESIGN.md`
motion decision rather than a code one.

### What actually repaints
`carousel.cpp`'s `tick_cb` runs every **500 ms** and calls `update()` on the **visible screen only**,
then restyles the dots. Views are written to mutate text/values in place, so a tick with unchanged
data invalidates nothing and costs no flush. **A view that rewrites a label with identical text still
invalidates it** — LVGL doesn't diff strings. If you add a hot view, compare before setting.

Custom-draw widgets (analog face, scope traces, chrome) repaint via `lv_obj_invalidate()`. Each one
invalidates its whole bounding box, so an oversized transparent draw object is the classic accidental
full-screen repaint.

### Idle behavior (#60)
`carousel_set_tick_paused(true)` pauses the 500 ms timer while the panel is dim or asleep — no
`update()` means no invalidation means no QSPI traffic, so the panel can actually idle. Resume runs one
immediate `update()` so a wake is never up to 500 ms stale. **Any new periodic UI work must respect
this pause**, or it defeats display sleep.

---

## 3. Memory: the real constraint

Internal SRAM is the scarce resource. PSRAM (8 MB) is effectively free by comparison.

| Measurement | Value | Source |
|---|---|---|
| Static internal RAM at link | **77,188 B / 327,680** (23.6%) | `pio run` this tree |
| Free internal heap at boot | ~253 KB | `tech.md` §2 (P2 hardware) |
| Steady-state free internal heap | ~115 KB | `tech.md` §2 |
| **Transient minimum** under active BLE + cert TLS + LVGL | **~53 KB** | `tech.md` §2 |
| Guideline floor | **60 KB** | `tech.md` §8, `HEAP_FLOOR` in `lvgl_port.cpp` |
| PSRAM free | ~8.38 MB | `tech.md` §2 |
| Flash (app slot) | **1.92 MB / 3.0 MB** (61.1%) | `pio run` this tree |

**The ~53 KB transient sits below the 60 KB guideline.** It is stable in practice but there is no
headroom to spend casually. Concretely:

- Anything new that must live in **internal** SRAM (DMA buffers, task stacks, BLE/TLS state) eats
  directly into that margin. Prefer PSRAM (`heap_caps_malloc(..., MALLOC_CAP_SPIRAM)`).
- The 8 KB `fetch_scratch()` buffer is **shared by every fetcher** (#65 M6) for this reason. Don't
  allocate a second body buffer.
- One theme's styles/fonts are resident at a time. Fonts are flash-resident and glyph-subset; the
  ~1.2 MB of remaining flash is the budget for new fonts and screens.
- LVGL draw buffers must stay in PSRAM. With them in internal SRAM the min free heap collapsed to
  ~44 KB and **TLS fetches timed out** — that's what `BEACON_LVGL_PSRAM` exists to prevent.

### 3.1 Sonos album art — measured, 2026-07-28 (replaces design §3.4/§4.1's estimate)

Source: serial captures from an end-to-end hardware run the same day (Sonos -> hub -> TLS fetch ->
RGB565 render -> LAN serve -> BLE `sart` -> device -> glass, `docs/plans/2026-07-27-sonos-album-art-plan.md`).
**Everything in this subsection is a measurement or an arithmetic derivation from measurements shown in
full — no figure here is a forecast.**

| Measurement | Value |
|---|---|
| PSRAM total | 8,388,608 B |
| PSRAM free at boot, before the LVGL draw buffer | 8,384,400 B |
| LVGL draw buffer | 43,804 B |
| PSRAM free, steady state (sonos page built, art live) | ~8,121,252–8,121,908 B |
| Sonos tile buffers (2 x 200x200x2, by contract — `SONOS_TILE_BYTES` x 2) | 160,000 B |
| Rendered tile size on the wire (hub log `fetch ok ... bytes=80000`) | 80,000 B |
| **Lowest internal heap observed (`int_min`), art feature resident** | **43,816 B** |

**PSRAM delta, shown in full:**

```
free after the LVGL draw buffer  = 8,384,400 - 43,804              = 8,340,596 B   (derived, not
                                                                       independently logged, but the
                                                                       draw buffer is the very next
                                                                       PSRAM allocation after boot)
steady-state delta               = 8,340,596 - 8,121,908 (upper)   = 218,688 B  (minimum)
                                  = 8,340,596 - 8,121,252 (lower)   = 219,344 B  (maximum)
minus the tile buffers           = 218,688..219,344 - 160,000      = 58,688..59,344 B  UNACCOUNTED FOR
```

So the sonos page's steady-state PSRAM cost is **~218.7–219.3 KB**, of which the 160,000 B tile pair
accounts for most but not all of it: **~58.7–59.3 KB is not explained by the draw buffer or the tile
buffers**, and design §4.1's own budget for the rest of the sonos widget tree (`lv_img_dsc_t` + widget
~320 B, the hidden no-art container ~400 B) is nowhere near large enough to close that gap. This is
**not attributed to a cause here** — the leading hypothesis (untested) is that "steady state with the
sonos page built" was captured after `on_theme()`'s boot-time build of every compiled carousel screen
(§4: *"All five screens are built and resident, on every theme switch"* — that count is itself stale,
see `docs/codemap.md` §1's 7-screen count), not sonos alone, so the delta may include other screens'
widget trees rather than being purely a sonos cost. **Flagged for the owner; do not treat 218.7–219.3 KB
as "the sonos page's cost" without isolating it from total boot allocation first.**

**Internal heap — read this against §3's table above, not in place of it.** Today's hardware run
logged `int_min` = **43,816 B** with the Sonos album-art feature present (tile buffers allocated, LAN
fetch task active). That is:
- Below `tech.md` §2's own ~53 KB P2 measurement (no Sonos art).
- Below this file's header callout of 49,832 B (a different specific build, 2026-07-26, also no Sonos
  art) — which itself already disagreed with `tech.md`'s ~53 KB by ~3 KB before today.
- **~16 KB below the 60 KB guideline floor** (`tech.md` §8).

**This number is not corrected in place and the budget is not rewritten to match it.** It is reported as
observed, with the art feature present, so the owner can decide whether 43,816 B is an art-specific
regression (a plausible candidate: `net_lan_get`'s plain-`WiFiClient` socket plus lwIP pbufs during a
tile fetch, §4.5 estimated this at "~4-8 KB transient") or a tighter capture of a margin that was
already this thin. See `docs/codemap.md` §6 for the full reconciliation of the three heap figures.

**The two-buffer swap protocol (plan §4 WS-2, §5) is confirmed live on real hardware, not only under
the host race test.** `firmware/test/test_sonos_art/` layer 2 proves the gate (`sonos_art_may_write`,
`sonos_art_back_idx`) is correct *under contention*, with two real `std::thread`s hammering the real
`ds_lock_t` — but that is still a host simulation of two cores, not the genuine article. Today's
hardware captures are the first evidence the real Core-0 fetch task and the real Core-1 LVGL repoint
actually use that gate as designed:

```
dev:  [BEACON] I sonos_art: gen=5 published idx=1
dev:  [BEACON] I sonos_art: gen=6 published idx=0
```

`idx` alternates 1 then 0 across two consecutive real publishes, exactly as `sonos_art_back_idx`
requires (`back_idx(front) != front`, plan §5 layer 1). Four publishes were observed in total (`gen` 1,
3, 5, 6), each logged at exactly 80,000 bytes on the wire (`hub: [beacon-hub] art fetch ok
digest=... bytes=80000`) with a distinct digest — 200x200x2 RGB565 confirmed by measurement. **What
this does not confirm:** the specific rapid-fire stress case (5+ track skips inside 10 s, plan §4 WS-5
step 3 / layer 3) — the pacing of today's four publishes was not a scripted burst, so a torn tile under
genuine two-writes-within-one-tick pressure remains unconfirmed. See
`docs/plans/2026-07-27-sonos-album-art-rehearsal.md` step 3.

**Tile-change render/blit time: NOT YET MEASURED.** Design §3.4's estimate and the plan's WS-3 trap note
independently derive **~9 ms render + ~5.4 ms blit** by scaling this file's measured full-screen numbers
(§2.1: ~49 ms render / ~29.5 ms blit) by the tile's share of panel area (40,000 / 217,156 px ≈ 18.4%).
**That arithmetic is not a measurement of the tile-change repaint itself** — no on-device timestamp
around an actual `lv_img_set_src` repoint + flush was captured today. Getting a real number needs either
a `LOGI` pair bracketing the `update()` repoint branch in `sonos_editorial.cpp` or an `env:perf`-style
flush-profiler run with a scripted track change. Neither has been done. Do not cite ~9 ms/~5.4 ms as
measured; it is a derived estimate carried over from the design, unchanged.

---

## 4. Where the current headroom and costs are

Verified characteristics of this build, useful when planning work:

**All five screens are built and resident, on every theme switch.** `on_theme()`
(`carousel.cpp:43-54`) does `lv_obj_clean` + `chrome_attach` + `build()` + `update()` for **every**
page, not just the visible one — deliberately, so a page scrolling into view never shows LVGL's
default `"Text"`. Consequences:

- A theme switch rebuilds 5 widget trees synchronously. It is visible but brief; it is not free.
- Every screen you add costs its widget tree in the PSRAM pool permanently.
- `tech.md` §6's "only the visible screen is built" is **stale** — do not plan against it.

**The 500 ms tick is coarse.** Nothing on screen updates faster than 2 Hz today. A per-second clock is
fine; a smooth animation is not served by this timer — use an LVGL animation or a dedicated
`lv_timer` and make sure it honors the idle pause.

**Network is already optimized** in two non-obvious ways worth preserving:
- `slot_host()` lets the scheduler drain same-host due slots back-to-back so one TLS handshake serves
  a whole sweep (#61); `net_close_idle()` drops the socket when the sweep goes quiet. **A host-string
  mismatch in `slot_host()` silently loses the reuse** (correctness is unaffected, cost is not).
- BLE writes are **acknowledged** (`.withResponse`). `withoutResponse` packets drop under WiFi+BLE
  coexistence congestion and corrupt multi-chunk frames — a hardware finding, not a preference. The
  data rate is a frame per ~30 s, so the round-trips are free.

**The 30 s heartbeat** resends the full frame even when nothing changed; the mux dedups its own
outputs, so per-change frames are already gated (`ProviderMux.publish*` compares against `last*`).

---

## 5. Instrumentation that exists

**Heap, from the device, no flags needed:**
- `fetch_task` logs every 10 s: `heap: int_free=… int_min=… psram_free=… up=… time=…`
- `hub_task` logs every ~10 s: `hub: conn=… int_free=… min=…` (running minimum since boot — this is
  the number to watch against the 60 KB floor)
- `lvgl_port_begin()` logs the chosen buffer region + size + free internal heap at boot, and warns if
  it starts below the floor.

```bash
cd firmware && ~/.beacon-pio/bin/pio device monitor    # 115200, ctrl-] to exit
```

**Frame cost: `env:perf`.** The measurement build — `env:beacon` plus a flush profiler
(`ui/lvgl_port.cpp`) and a continuous auto-swipe (`ui/carousel.cpp` `autoswipe_cb`). It logs once a
second:

```
perf: hdlr 787ms blit 319ms/1014ms (31%) strips=121 ~11fullframes \
      blit/frame=29072us rend/frame=42512us 4601KB/s loop=52/s
```

`hdlr` = total time inside `lv_timer_handler()`; `blit/frame` and `rend/frame` split that per
full-screen-equivalent repaint, which is what tells you whether the next win is on the bus or in the
rasteriser.

```bash
cd firmware && ~/.beacon-pio/bin/pio run -e perf -t upload && ~/.beacon-pio/bin/pio device monitor
```

The auto-swipe exists because **hand-swiping cannot produce comparable numbers** — capture windows
kept coming back fully idle, and swipe speed varies per attempt. Driving `lv_obj_scroll_by` on a timer
exercises the identical path (scroll animation → `SCROLL_END` → `show()` → `recenter()`) reproducibly.
The device cycles screens by itself under `env:perf`; that is the benchmark, not a fault. Flash
`env:beacon` to get normal behaviour back. To A/B a flag, `build_unflags` it in `[env:perf]` first.

**LVGL's own FPS overlay** is a separate option: `LV_USE_PERF_MONITOR` in `src/lv_conf.h` (default
`0`). It draws real pixels, so it also lands in `env:capture` screenshots — prefer the serial
profiler, which costs nothing visually and gives the render/blit split the overlay can't.

**`LV_USE_MEM_MONITOR` cannot be enabled as configured** — it requires `LV_MEM_CUSTOM = 0`, and this
build sets `LV_MEM_CUSTOM 1` to put the LVGL heap in PSRAM. Use `heap_caps_get_free_size(MALLOC_CAP_SPIRAM)`
from the existing logs instead.

**Touch-to-visual latency** (<100 ms target) and **boot-to-first-render** (<4 s target) have no
built-in counters. Both are log-timestamp measurements: `LOGI` on the touch event vs the next
`flush_cb`, and reset-to-first-`lv_scr_load` respectively.

**Lesson from the Sonos album-art build: a multi-process pipeline needs a log at every "do nothing"
outcome, not just at the failures you anticipated.** The art path crosses three process/task boundaries
(hub Swift process -> BLE -> device `hub_task` -> device `fetch_task`), and every stage has a
legitimate reason to produce no output: an unchanged URL, an unchanged tile digest, art disabled, the
`sonos` page not in the device's page list, WiFi down, no Sonos client secret configured. **A hub gated
on a missing credential and a hub happily idling because nothing changed emit identical evidence: no
`sart` frame, no LAN request, no BLE traffic.** A full green test suite (hub `swift test` + firmware
`pio test -e native`, hundreds of cases across both) shipped this pipeline before it was run on real
hardware, and the investigation that day spent its time downstream of the actual fault — the gate was
at the very first hop, and everything past it was, correctly, doing nothing. The fix (`79d6a1b`,
`feat(hub): make the sonos art pipeline observable`) was not a code fix; it was
a log line at every decision point (`SonosArtDecision`'s `doNothing`/`clear`/`publish`, the
`LanAssetServer` arm outcome, `net_lan_get`'s per-attempt result, the `sart_stat` sent back) so that
"broken" and "healthy but idle" stopped looking the same on the wire and in the log. **The general
rule:** when a pipeline spans more than one process and has more than one point where "nothing to do"
is a correct outcome, instrument every one of those points *before* the first end-to-end run, not
after the first confusing one — the alternative is debugging by process of elimination across a
process boundary you can't single-step through.

---

## 6. Checklist before claiming a performance change

1. `pio run` and compare the RAM/Flash line against the baseline in this doc's header.
2. Flash it and watch `int_min` in the serial log for a few minutes under a real BLE link — the
   transient minimum is the number that matters, not the instantaneous free.
3. If you touched the render path, enable `LV_USE_PERF_MONITOR` and confirm >=30 FPS during a scripted
   swipe, then turn it back off.
4. If you touched anything periodic, verify the display still sleeps (the tick pause is honored).
5. Update the baseline numbers in this doc's header if they moved.
