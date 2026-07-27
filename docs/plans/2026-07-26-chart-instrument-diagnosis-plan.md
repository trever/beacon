# Plan: diagnose why the Chart page ignores its selected instrument

**Status:** open. Written 2026-07-26. Self-contained — assumes no prior session context.

## Symptom

The user set the Chart page's instrument to Nasdaq via the hub's page designer and reported the on-device
graph looked identical to S&P 500. The hub-side preview was separately confirmed wrong (hardcoded
figures) and is being fixed elsewhere — **this plan is about the device only.**

## What has already been ruled out

Do not re-check these; they were verified by inspection on 2026-07-26:

- `nasdaq` **is** a valid default ticker id (`firmware/src/config/tickers.h` ships
  `btc, eth, sp500, nasdaq, dow, mag7, gold, oil`), so a missing table row is not the cause.
- The chart screen reads the live record: `chart_editorial.cpp` `update()` calls `ds_get_series()` and
  feeds `graph_set_series`. It does not read a stale finance row.
- The fetch path is built from the resolved ticker's symbol in `resolve_chart()`
  (`firmware/src/fetch/series.cpp`), and `%`-containing symbols like `%5EIXIC` are passed as a `snprintf`
  **argument**, not a format string, so they are not reinterpreted.

## Leading hypothesis (unconfirmed)

**Nasdaq may never have been running on the device.** The user's `rev=1` push (nasdaq) was followed
within seconds by `rev=2` (sp500) during the page-config restart loop fixed in #14. The device's stored
option is currently `sym=sp500`, so the comparison may have been S&P against S&P.

If this is right there is no bug, and the fix is documentation plus possibly surfacing the active
instrument more clearly.

## Steps

1. **Confirm the current state.** `defaults read com.beacon.hub BeaconPageOpts` on the user's Mac shows
   what the hub will push. The device's own copy lives in NVS under key `pages`.
2. **Push nasdaq once**, with the #14 idempotence fix present so it does not loop. Watch the serial the
   whole time — start the capture *before* the push, since the interesting lines appear within seconds:

   ```bash
   ~/.beacon-pio/bin/python -c "
   import serial,time
   s=serial.Serial('/dev/cu.usbmodem101',115200,timeout=1)
   end=time.time()+180
   while time.time()<end:
       l=s.readline().decode('utf-8','replace').rstrip()
       if l: print(l, flush=True)
   "
   ```
3. **Read the decisive lines.**
   - `hub: pages rev=N applied (M pages); restarting` — the option reached the device.
   - `chart: ticker 'nasdaq' not in the table` or `is not a Yahoo row` — `resolve_chart` fell back.
     If either appears, the bug is in resolution: check `carousel_page_opt("chart","sym",…)` returns
     `nasdaq`, and that `ticker_table_get` is populated by the time `fetch_series` first runs.
   - `series: N pts, last=… prev=… lo=… hi=…` — compare `last` against the real Nasdaq level. S&P and
     Nasdaq differ by thousands of points, so one line settles it.
4. **If the values are S&P's while no fallback warning was logged**, instrument `resolve_chart` to log the
   resolved path and id, reflash, and repeat. The likely remaining causes, in order:
   - `fetch_series` runs before `carousel_init()` has resolved the active pages, so `carousel_page_opt`
     returns empty on the first fetch and the record is never refreshed afterwards (check the scheduler's
     first-run timing in `firmware/src/core/fetch_task.cpp`, `SRC_SERIES`, cadence `CHART_CADENCE_S` 300 s).
   - The DataStore series record is not re-seeded on instrument change, so the screen keeps rendering the
     previous instrument's points until the next successful fetch.
5. **If it is the timing case**, the fix is to re-fetch on page-config apply rather than waiting out the
   300 s cadence — or, since applying a page list restarts the device anyway, to ensure the boot-time
   fetch happens after `carousel_init()`.

## Definition of done

- The on-device graph and header follow the selected instrument, verified by a `series:` log line whose
  `last` matches the chosen index.
- If the cause was the rev-2 overwrite and no code bug exists, say so plainly and close this out — with a
  note in `docs/codemap.md` about how to verify the active instrument.
- A regression test if the cause was code. `firmware/test/test_page_config/` covers the option layer;
  resolution lives in `series.cpp`, which is device-only, so consider extracting the
  ticker-id → path/label mapping into a pure function that the `native` env can test.

## Constraints

- Build with `~/.beacon-pio/bin/pio run -e beacon` (always pass `-e beacon`).
- Tests: `~/.beacon-pio/bin/pio test -e native` (242 passing as of 2026-07-26).
- The chart interval is pinned at 15m and must stay that way: the response has to fit the shared 8 KB
  `fetch_scratch()`, where 5m measured 7789 B against 15m's 3449 B.
- Flashing needs `--upload-port /dev/cu.usbmodem101`; auto-detection picks the Bluetooth port and fails.
