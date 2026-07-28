# Sonos album art — end-to-end rehearsal checklist

**Status:** open. Written 2026-07-28 by WS-5 (convergence). This is the executable form of
`docs/plans/2026-07-27-sonos-album-art-plan.md` §4 WS-5's "end-to-end rehearsal" (nine steps) and
§8 exit-gate items 2/3.

**Why this is a checklist, not a completed report.** Every step below needs a human at the physical
hardware — playing music, skipping tracks, toggling a macOS Settings pane, denying a permission,
sleeping the Mac. No agent can do any of that, and this document does not claim any step is done
unless real evidence for it exists below. **Do not mark a box checked without evidence attached** —
this project has been bitten repeatedly by documented figures/claims that were forecasts rather than
measurements (see `docs/perf.md` §3.1, `docs/codemap.md` §6).

**Legend:** `[x] DONE` — real hardware evidence exists, quoted below the step. `[ ]` — not yet run.
`[~] PARTIAL` — run, but the outcome only partially matches the scripted expectation; read the note.

---

## Prerequisites (once)

- [x] **Build and flash the current tree to the device.**
  Command: `cd firmware && ~/.beacon-pio/bin/pio run -e beacon -t upload`
  Expected: `pio run -e beacon` reports `SUCCESS` before flashing.
  Failure looks like: a compile error (check against this WS-5 report's acceptance-gate numbers), or
  the upload step failing to find the device (check USB/driver, not a code issue).
  Evidence: `pio run -e beacon` verified `SUCCESS` on this tree during WS-5 (2026-07-28) — see this
  report's acceptance-gate output. (Flashing to a physical board is the owner's step; the build that
  would be flashed is confirmed green.)

---

## The nine steps (plan §4 WS-5)

### 1. Device IP report on connect
**Do:** Power-cycle or reconnect the device to the hub over BLE; watch the device's serial log.
Command: `cd firmware && ~/.beacon-pio/bin/pio device monitor` (115200 baud, Ctrl-] to exit).
**Expected:** A `cmd:"report","what":"device"` frame goes out once BLE connects, initially with no `ip`
(WiFi has not joined yet), then again once `WiFi.localIP()` resolves.
**Failure looks like:** no `what:"device"` report at all (check `hub_report.cpp`'s
`hub_emit_device_report` wiring to `hub_task.cpp`'s `!s_reported` site), or an `ip` that never updates
after WiFi joins.

- [x] **DONE.** `hub/CONTRACT.md` §B4 records a real hardware capture (2026-07-27): `device report sent
  (ip=(none))` at **~3.3 s**, `wifi up ... ip=192.168.1.19` at **~12.2 s** — the device's first report of
  a connection routinely carries no `ip` at all (WiFi joins ~9 s later), and the device re-emits once its
  live address stops matching what the connection was told. This is the evidence CONTRACT.md itself cites
  for why the report is "repeatable, last-writer-wins," not one-shot — read that section before assuming
  "once per connection" (the plan's own WS-0 file-list description says "once per connection"; the
  frozen contract text is the one that was corrected against real hardware and is authoritative).

### 2. First real art tile, cloud service with real cover art
**Do:** Play a track on the followed room from a cloud streaming service with real per-track cover art.
**Expected:** `sart` S1 goes out on the wire; the device performs exactly one LAN GET; the tile appears
on glass within roughly 1.5 s of the track change; the device sends `sart_stat ok:true`; the hub's
Settings > Device tab "Local Network" row reads `.ok`.
**Failure looks like:** no `sart` frame (check `SonosArtPublisher`/`SonosProvider.onArtURL` wiring); a
LAN GET that never completes (check `net_lan_get` and the Local Network TCC prompt, step 7 below); a
`sart_stat` with `ok:false` and some `err` other than what step 7 expects.

- [x] **DONE.** Confirmed end-to-end on real hardware 2026-07-28: Sonos -> hub -> TLS fetch -> RGB565
  render -> LAN serve -> BLE `sart` -> device -> glass, confirmed hub-side by log and device-side by the
  owner's eyes. Three real defects were found only because this step was actually run on hardware, and
  all three are fixed and merged as of this tree (`09c7c5f`): (1) ATS blocked plain-`http://` Sonos art
  URLs — fixed by `SonosArtDecision.httpsUpgraded` (a scheme upgrade, not an ATS exception); (2) a
  `sart` URL turned away by a shut BLE gate was dropped forever instead of retried — fixed with a
  deferred-URL replay (`09c7c5f`); (3) the pipeline had no diagnostics, so a credential-gated hub and a
  healthy-idle hub produced identical evidence — fixed by `79d6a1b` (see `docs/perf.md` §5's
  instrumentation lesson).

  **Matched hub/device log pairs, same generation on both ends** (real captures, not reconstructed):
  ```
  hub:  [beacon-hub] art fetch ok digest=305fd681 bytes=80000
  hub:  [beacon-hub] art armed gen=5 serving on port 58870
  dev:  [BEACON] I sonos_art: gen=5 published idx=1
  dev:  [BEACON] I hub: sart_stat gen=5 ok=1 err= sent=1

  hub:  [beacon-hub] art fetch ok digest=223a9633 bytes=80000
  hub:  [beacon-hub] art armed gen=6 serving on port 58882
  dev:  [BEACON] I sonos_art: gen=6 published idx=0
  dev:  [BEACON] I hub: sart_stat gen=6 ok=1 err= sent=1
  ```
  Log formats verified against source: `hub/Sources/beacon-hub/SonosArtPublisher.swift:255,295`
  (`"[beacon-hub] art fetch ok digest=... bytes=..."`, `"...armed gen=... serving on port ..."`) and
  `firmware/src/core/sonos_art.cpp:196` / `hub_task.cpp:369` (`"sonos_art: gen=%u published idx=%u"`,
  `"hub: sart_stat gen=%u ok=%d err=%s sent=%d"`). This establishes, for the first time on real
  hardware rather than a host test: **the `gen` the hub mints is the exact one the device consumes and
  acknowledges** (WS-0's wire, WS-1's server, WS-2's transport and WS-3's repoint agree with each
  other); **`sart_stat ok=1` returns**, so the device->hub ack path and the Local Network row's `.ok`
  signal both have real evidence behind them; and **every publish measured exactly 80,000 bytes** with
  a distinct digest — 200x200x2 RGB565 confirmed by measurement, not only by contract. Four successful
  publishes were observed in total (`gen` 1, 3, 5, 6); `gen` 2 and 4 do not appear in this evidence, and
  no cause is asserted for that here (see step 4's SiriusXM note for one candidate mechanism — S2 clears
  produce no `sart_stat` at all, by design, so a missing `gen` in this log is not on its own evidence of
  a bug).

  **Still not individually captured:** the exact ~1.5 s landing-latency figure from track-change to
  pixels-on-glass was not measured or logged today — do not cite a specific latency number for this
  step; none exists yet.

### 3. Rapid track skips (torn-tile stress)
**Do:** Skip 5+ tracks in under 10 seconds on the followed room.
**Expected:** no torn tile (no frame showing two different images' pixels at once); superseded `gen`s
emit no `sart_stat` at all (silent withdraw, matching CONTRACT.md §D); the final tile on glass matches
the final track; `int_min` in the serial log does not walk downward across the skip burst (no leak).
**Failure looks like:** a visibly split/garbled tile (the two-buffer swap protocol — plan §4 WS-2 — has
a bug); a `sart_stat` for a `gen` that was superseded before it finished downloading; the tile lagging
behind the currently-playing track after the burst settles; `int_min` trending down run over run.

- [~] **PARTIAL.** Today's captures (step 2's log pairs) show `idx` alternating **1 then 0** across
  consecutive real publishes (`gen=5 published idx=1`, then `gen=6 published idx=0`) — the two-buffer
  swap doing its real job on **hardware**, not only under the host race test in
  `firmware/test/test_sonos_art/` layer 2. That layer-2 test (two real `std::thread`s racing through
  the real `ds_lock_t`) proves the gate is correct *under contention*; this is the first evidence that
  the real fetch task and the real LVGL repoint actually *use* that gate as designed. **What this does
  not confirm:** the specific rapid-fire scenario this step scripts — 5+ skips inside 10 seconds — was
  not described as the pacing of today's four publishes, so the torn-tile stress case (two writes
  racing within one 500 ms tick) is still unconfirmed. Layer 3 (plan §5) — deliberate rapid skipping
  while watching the glass — is the only thing that closes this out, and it still needs to be run.

### 4. SiriusXM station (Phase A's verified case)
**Do:** Play the SiriusXM station on the followed room that Phase A verified against the owner's live
account.
**Expected (as scripted):** the container-level station logo renders on glass.
**Failure looks like:** no art at all for a SiriusXM station (container-level `imageUrl` not reaching
the publisher), or the wrong image.

- [~] **PARTIAL — real finding, not a clean pass.** Today's hardware run (2026-07-28) established that
  SiriusXM serves art from (at least) two different hosts, and they behave differently:
  `pri.art.prod.streaming.siriusxm.com` (the channel-logo fallback) serves a certificate that does
  **not** match its own hostname, so a genuine TLS fetch of it fails — and the pipeline **correctly
  degrades to the no-art form** rather than crashing or showing garbage (design §6.3's failure-mode
  contract, confirmed working). `albumart.siriusxm.com` (the per-track art) serves the identical image
  and **does** succeed over TLS. So the literal scripted expectation ("the container-level logo
  renders") did not hold for the channel-logo host; what actually happened is a different, per-track
  host succeeding while the channel-logo fallback fails safely. **This is a real result worth keeping
  as-is, not a gap to paper over** — record both host behaviors in the PR body rather than claiming a
  clean pass on the original wording.

  **Observable consequence, recorded honestly rather than smoothed over:** because the channel-logo
  host's TLS failure triggers an S2 clear per design §6.3, **the tile intermittently blanks between
  tracks on a SiriusXM station** whenever a track resolves to the failing host. This is specified
  behaviour operating correctly, not a defect — but it is a real, user-visible effect, and the owner has
  been asked whether the publisher should instead **keep the previous tile through a failed fetch**
  rather than clearing to the no-art form. **That question is open. No source file was changed for
  this entry** — do not treat the blanking as a bug to silently patch; it is a design trade-off the
  owner needs to decide.
  **Note on step numbering:** the brief that produced this checklist described this evidence as "part
  of [rehearsal step] 5" (the Spotify follow-up capture). Content-wise it is SiriusXM, not Spotify, so
  this document attributes it to step 4 instead and leaves step 5 fully open below. Flagged rather
  than silently going along with a step number the evidence doesn't support.

### 5. Spotify follow-up capture (carried from Phase A)
**Do:** Get a Spotify session on the followed room with a track actually loaded (not a suspended
session with nothing playing), and record whether `imageUrl` comes back populated.
**Expected:** an observation either way, not a gate — Phase A's own Spotify result was *inconclusive*
(suspended session, no track loaded), not negative.
**Failure looks like:** nothing to fail here in the pass/fail sense; the only bad outcome is not
recording the answer at all.

- [ ] **Not yet run.** No Spotify evidence — inconclusive or otherwise — was produced today. This is
  still exactly where Phase A left it: open, and not a blocker for anything else in this project.

### 6. Settings toggle off
**Do:** In the hub's Sonos settings section, turn the "Album art" toggle off.
**Expected:** exactly one S2 (`sart` with `gen` only, no `url`) goes out; the device switches to the
no-art form; the listener is never armed again. Verify the last part at rest with:
`lsof -nP -iTCP -sTCP:LISTEN | grep beacon-hub` — only port 8765 (the hooks `LocalIngestServer`) should
appear; no ephemeral `LanAssetServer` port should ever show up while idle.
**Failure looks like:** the last tile stays on glass forever (absence-never-clears working against you
because S2 was never actually sent — D-6); a `LanAssetServer` port lingering in the `lsof` output after
the toggle is off (the listener should be armed only for a transfer, never at rest, per WS-1's design).

- [ ] Not yet run.

### 7. Deny Local Network permission (the failure P-1 exists to catch)
**Do:** System Settings -> Privacy & Security -> Local Network -> turn "Beacon Hub" off. Then trigger an
art publish (change tracks).
**Expected:** the device reports `err:"timeout"` with zero bytes received; the hub's Settings > Device
tab "Local Network" row goes `.bad`, naming Local Network permission specifically (not a generic
"network error" — `LocalNetworkCheck.derive` is the whole payoff of this test, per plan §4 WS-4).
**Failure looks like:** `err:"conn_refused"` instead of `"timeout"` (the two must never collapse into
one value — that distinction is precisely what separates a firewall block from a TCC denial); a row
that says something generic instead of naming Local Network; no row change at all.

- [ ] **Not yet run — explicitly the most important unchecked box.** This is the failure mode P-1
  (`NSLocalNetworkUsageDescription`) exists to make visible, and per the plan, art exercises this path
  "many times a day instead of once a month" (unlike OTA, which would hit it rarely). Test the denied
  path, not only the granted one.

### 8. Quit the hub mid-transfer
**Do:** Start a track change (art fetch in flight), then quit Beacon Hub before the LAN GET completes.
**Expected:** the device's read stalls into `err:"timeout"`; the **old tile stays on glass** (absence of
a new `sart` outcome must never clear existing art).
**Failure looks like:** the tile blanking or showing a torn/partial image; the device hanging instead of
timing out (check the 3 s connect / 3 s idle-read / 8 s hard-abort deadlines, plan §4 WS-2).

- [ ] Not yet run.

### 9. Mac sleeps while music is playing
**Do:** Put the Mac to sleep (Apple menu > Sleep, or lid-close on a laptop) while a track with art is
actively playing.
**Expected:** the device transitions to `ST_HUB_OFFLINE`; the tile **dims** to `LV_OPA_40` (opacity, not
a blank — asserting "nothing playing" would be false while the last art is still valid); and — the
actual point of this step, per D-5 — **the Mac genuinely sleeps** rather than being held awake by the
art pipeline.
**Failure looks like:** the Mac fails to sleep at all (an `.idleSystemSleepDisabled` power assertion is
leaking from somewhere in the art path — `LanAssetServer` and `SonosArtPublisher` must both take none,
per D-5); the tile blanking instead of dimming; the device not reflecting `ST_HUB_OFFLINE` at all.

- [ ] Not yet run. `hub/Tests/beacon-hubTests/`'s `PowerAssertionSpy`-based tests
  (`testArtSizedArmTakesNoSleepAssertion`, `testArtPublishTakesNoSleepAssertion`) are the automated
  proxy for "the art path takes no assertion" and both are green in this tree's `swift test` run — but
  a passing spy test is not the same claim as "the Mac actually slept," which is what this step alone
  can prove.

---

## Observed hardware conditions (not part of the nine steps, worth recording anyway)

**The device's USB-CDC serial port disconnects and re-enumerates frequently under load** — roughly once
per two log lines during today's captures, with a single reader and no contention on the port. It made
device-side observation unreliable and cost real time during today's session. This is recorded as an
**observed condition, not a diagnosed fault** — no investigation has been done into the cause (power,
driver, cable, or firmware-side). It matters beyond today's logging inconvenience because
`docs/plans/2026-07-27-ota-updates-plan.md`'s recovery path assumes USB is available when something has
gone wrong; if the port is this flaky under ordinary BLE+LAN load, that assumption may need its own
verification before OTA leans on it.

---

## Summary

| Step | Status | 
|---|---|
| 1. Device IP report | DONE |
| 2. First real art tile (cloud art) | DONE |
| 3. Rapid track skips | PARTIAL — swap mechanism confirmed live on hardware; rapid-fire stress case unconfirmed |
| 4. SiriusXM station | PARTIAL — real finding, see note |
| 5. Spotify follow-up capture | not yet run |
| 6. Settings toggle off | not yet run |
| 7. Deny Local Network permission | not yet run — highest-priority remaining step |
| 8. Quit hub mid-transfer | not yet run |
| 9. Mac sleeps during playback | not yet run |

**Exit-gate reminder** (plan §8): items 2 and 3 of the whole-project exit gate — capture PNGs of both
screen forms, and this nine-step rehearsal including the denied-Local-Network path and the
Mac-actually-slept check — are not satisfied until every row above reads DONE with attached evidence.
