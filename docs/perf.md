# Beacon — performance: pipeline, budgets, and how to measure

> **What this is:** the render/task pipeline as built, the measured budgets, and the instrumentation
> that exists. `docs/tech.md` §8 owns the NFR *targets*; this documents the *implementation* and how to
> check it. Numbers below are from this tree unless marked as a spike measurement.
>
> Build measured at `4850e04` (2026-07-26), `env:beacon`, Arduino core 3.3.5 / LVGL 8.4.0:
> **static RAM 77,188 B of 327,680 (23.6%)** · **flash 1,922,599 B of a 3,145,728 B OTA slot (61.1%)**.

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
          -> LVGL invalidation -> partial render into ONE draw buffer
          -> rounder_cb  (snap flush window to even coords -- CO5300 requirement)
          -> flush_cb    -> display_draw_bitmap() [blocking QSPI] -> lv_disp_flush_ready()
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

**FPS: not currently instrumented.** `LV_USE_PERF_MONITOR 0` in `src/lv_conf.h`. To measure, flip it
to `1` (it draws an FPS/CPU overlay at `LV_ALIGN_BOTTOM_RIGHT`) and rebuild. Remember it is a debug
build only — the overlay is real drawn pixels and will appear in `env:capture` screenshots.

**`LV_USE_MEM_MONITOR` cannot be enabled as configured** — it requires `LV_MEM_CUSTOM = 0`, and this
build sets `LV_MEM_CUSTOM 1` to put the LVGL heap in PSRAM. Use `heap_caps_get_free_size(MALLOC_CAP_SPIRAM)`
from the existing logs instead.

**Touch-to-visual latency** (<100 ms target) and **boot-to-first-render** (<4 s target) have no
built-in counters. Both are log-timestamp measurements: `LOGI` on the touch event vs the next
`flush_cb`, and reset-to-first-`lv_scr_load` respectively.

---

## 6. Checklist before claiming a performance change

1. `pio run` and compare the RAM/Flash line against the baseline in this doc's header.
2. Flash it and watch `int_min` in the serial log for a few minutes under a real BLE link — the
   transient minimum is the number that matters, not the instantaneous free.
3. If you touched the render path, enable `LV_USE_PERF_MONITOR` and confirm >=30 FPS during a scripted
   swipe, then turn it back off.
4. If you touched anything periodic, verify the display still sleeps (the tick pause is honored).
5. Update the baseline numbers in this doc's header if they moved.
