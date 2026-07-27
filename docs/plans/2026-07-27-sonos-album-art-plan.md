# Plan: Sonos album art (hub rasterises, device blits) — everything after Phase A

**Status:** open. Written 2026-07-27. Self-contained — every workstream below assumes **no prior session
context** and is written to be lifted into a subagent brief almost verbatim.

**Design (source of truth, read it completely before touching anything):**
`docs/specs/2026-07-27-sonos-album-art-design.md`. It is decision-complete.

**Settled by the owner. Do not relitigate, do not "improve", do not open as a question:**

| # | Settled |
|---|---|
| 1 | **Raw big-endian RGB565 on the wire.** No image decoder on the device, ever. No `LV_USE_SJPG` flip, no lodepng, no TJpgDec. |
| 2 | **200 x 200 tile, fixed in both dimensions.** 80,000 bytes. Not 160x160, not variable. |
| 3 | **The album line is dropped when art is present.** That is the price of #2 and it is paid. |
| 4 | **No art in the Home `sonos` complication.** One consumer of the tile buffer, one lifetime. |
| 5 | **A Settings toggle disables album art** and falls back to the text-only page. This is no longer "Phase D if missed" (design §11 Q4) — it ships. |
| 6 | **Letterbox, never crop.** Pure-black bars; they are AMOLED off-pixels. |
| 7 | **Hard cut on tile change, not a crossfade,** in this shipping phase. |

**Not in scope, and owned by another track — do not open these files:**
`docs/specs/2026-07-27-ota-updates-design.md` and `docs/plans/2026-07-27-ota-updates-plan.md` are
**read-only reference** here (WS-5 makes exactly one edit to the latter, see §7). Nothing under
`firmware/src/core/ota*`, `firmware/src/ui/ota_overlay*`, `hub/Sources/beacon-hub/FirmwareUpdateService.swift`,
`ReleaseSource.swift` or `LocalBuildSource.swift` exists yet and none of it is created here.

---

## 0. Phase A is done and merged. Do not re-plan it.

Commit `9000426`, `feat(hub): decode sonos album art and rasterise it for the device (phase A)`.

**What already exists on this branch — read it, build on it, do not rewrite it:**

- `hub/Sources/beacon-hub/SonosAPI.swift` — `TrackMetadata` now carries `imageUrl`, resolved as
  `currentItem.track.imageUrl ?? container.imageUrl`, empty strings coerced to `nil`. Fixture-tested.
- `hub/Sources/beacon-hub/SonosArtRenderer.swift` — `Tile { pixels: Data (80,000 B), sha256Hex }`,
  `render(imageData:)` / `render(cgImage:)` (pure: ImageIO decode → aspect-fit letterbox on black →
  **big-endian** RGB565 row-major → SHA-256), `fetchAndRender(url:)` (ephemeral `URLSession`, **no
  `Authorization` header**, http(s)-only, 4 MB cap enforced on the wire, 5 s timeout, no redirect to a
  non-http(s) scheme).
- `hub/Tests/beacon-hubTests/SonosArtRendererTests.swift` + `SonosAPITests.swift` — 20 tests including
  the four-pixel byte-order assertion from design §1.4. That test already caught a real vertical-flip
  bug: `CGContext`'s **drawing space** is bottom-up but its **memory buffer** is top-down, and an
  earlier version added a row reversal "for symmetry" that silently produced a mirrored, entirely
  plausible-looking tile. Do not add a row reversal.

**Risk 1 is retired.** Verified against the owner's live account: a **SiriusXM radio container**
returned a populated `container.imageUrl` and rendered correctly end to end — which is precisely the
case design §10 risk 1 feared most (a radio container carrying only a station logo, at container level
rather than track level). A second room on a suspended Spotify session had no track loaded and returned
nothing; that is **inconclusive for Spotify, not negative**. WS-5 carries a follow-up capture item for
it (§8), and it is **not a blocker for anything below**.

**What Phase A did *not* do, and therefore is still to build:**

- `SonosProvider` still discards `imageUrl`. `combineNowPlaying` constructs
  `SonosNowPlaying(room:track:artist:album:playing:)` from `SonosAPI.parsePlaybackMetadata`'s result and
  **drops the fifth field on the floor**. Nothing downstream has ever seen an art URL.
- There is no live preview in the hub's Sonos settings section (design §9 Phase A's third bullet).
  Verification happened another way. **Do not build the preview** — WS-4's real device path supersedes it.

---

## 1. Wave order and file ownership

| Wave | ID | Workstream | Parallel? | Component | Branch |
|---|---|---|---|---|---|
| **A** | **WS-0** | **Shared substrate: the `sart` wire schema both ends, the art record, the device IP report, P-1's Info.plist key** | **No — single owner, strictly sequential** | both | `feat/art-wire-substrate` |
| B | **WS-1** | `LanAssetServer` + hub LAN-interface selection | yes | hub | `feat/art-lan-asset-server` |
| B | **WS-2** | Device art transport: PSRAM buffers, swap protocol, `net_lan_get`, fetch-task job | yes | firmware | `feat/art-device-transport` |
| B | **WS-3** | Device layout: the two-form `sonos` screen, capture seeding | yes | firmware | `feat/art-device-layout` |
| C | **WS-4** | Hub art pipeline: change detection, `sart` publish, Settings toggle, Local Network row | **No** — integrates B | hub | `feat/art-hub-pipeline` |
| D | **WS-5** | Convergence: end-to-end on glass, measurements, docs | **No** | both | `feat/art-convergence` |

**Why WS-0 is sequential and alone.** The `sart` frame has a parser in `firmware/src/core/hub_proto.cpp`
and an encoder in `hub/Sources/BeaconHubKit/Protocol.swift`, and **they must not be able to disagree**.
Every previous frame in this repo (`sessions`, `sdetail`, `sonos`, `pages`, `comps`) was landed by a
single owner writing both halves against one frozen `hub/CONTRACT.md` section, and the two frames that
were *not* — nothing, so far — is the reason that record is clean. WS-0 also owns
`hub/Info.plist` (prerequisite P-1) because it is on the critical path for the entire LAN plane and is
one line.

**Why WS-4 is not parallel with wave B.** It is the integrator: it calls `LanAssetServer.arm()` (WS-1),
it emits the frames WS-0 froze, and its Local Network row consumes the `sart_stat` outcomes WS-2 sends.
It cannot compile until WS-1 has merged, and it cannot be verified until WS-2 and WS-3 have.

### Files, by exclusive owner

| Path | Owner |
|---|---|
| `hub/Info.plist` | **WS-0** (adds `NSLocalNetworkUsageDescription`; nobody else opens this file) |
| `hub/CONTRACT.md` | **WS-0** (new §A4 for `sart`, `sart_stat` + `report what:"device"` in §B) |
| `hub/Sources/BeaconHubKit/Protocol.swift` | **WS-0** (frozen after WS-0 merges) |
| `firmware/src/core/records.h`, `datastore.{h,cpp}`, `hub_proto.{h,cpp}` | **WS-0** (frozen after WS-0 merges) |
| `firmware/test/test_sart_proto/` | **WS-0** |
| `firmware/src/core/hub_report.{h,cpp}` | **WS-0** (device report gains `what:"device"`) |
| `hub/Sources/beacon-hub/LanAssetServer.swift`, `LanInterface.swift` | **WS-1** |
| `hub/Sources/beacon-hub/PowerAssertions.swift` | **WS-1** |
| `hub/Tests/beacon-hubTests/LanAssetServerTests.swift`, `LanInterfaceTests.swift` | **WS-1** |
| `firmware/src/core/sonos_art.{h,cpp}`, `net_lan.{h,cpp}` | **WS-2** |
| `firmware/src/core/fetch_task.cpp`, `hub_task.cpp` | **WS-2** |
| `firmware/test/test_sonos_art/`, `firmware/platformio.ini` | **WS-2** (wave B's only `platformio.ini` writer) |
| `firmware/src/ui/screens/views/sonos_editorial.cpp` | **WS-3** |
| `firmware/src/ui/dev_seed.{h,cpp}` | **WS-3** |
| `hub/Sources/BeaconHubKit/SonosArtDecision.swift`, `LocalNetworkCheck.swift` | **WS-4** |
| `hub/Sources/beacon-hub/SonosArtPublisher.swift` | **WS-4** |
| `hub/Sources/beacon-hub/SonosProvider.swift`, `AppDelegate.swift` | **WS-4** |
| `hub/Sources/beacon-hub/SonosSettingsView.swift`, `DeviceTab.swift`, `HubViewModel.swift` | **WS-4** |
| `docs/codemap.md`, `docs/recipes.md`, `docs/perf.md`, `DESIGN.md` | **WS-5** |

**Two files are touched by more than one workstream and both are serialized by the wave order, not by
convention:** `firmware/src/core/hub_task.cpp` (WS-0 adds the `what:"device"` emit; WS-2 adds the `sart`
dispatch — WS-0 has merged before WS-2 branches) and `hub/Sources/beacon-hub/AppDelegate.swift` (WS-4
only, in wave C, after every wave-B branch has merged).

---

## 2. Shared invariants — paste this whole section into every brief

### Step 0 — how to start, and the two ways this went wrong today

Worktrees are cut from **`main`**, which does **not** contain any of this work. Before writing a line:

```bash
git -C <worktree> reset --hard feat/sonos-page-and-yahoo-symbol-search
git -C <worktree> rev-parse HEAD     # must print ad888af89d7f378b0bcca6345c68bad66043b607
ls <worktree>/hub/Sources/beacon-hub/SonosArtRenderer.swift \
   <worktree>/firmware/src/ui/screens/views/sonos_editorial.cpp \
   <worktree>/docs/specs/2026-07-27-sonos-album-art-design.md
```

All three marker files must exist. If the SHA differs or any marker is missing, **stop and report** —
do not proceed and do not try to reconcile.

- **Do NOT `git merge`.** Merging `main` into a branch reset from this one produced multi-file conflicts
  today and, in one case, silently duplicated whole declarations into a Swift file that no longer
  compiled. `reset --hard` to the named branch is the only supported start.
- **NEVER use `git stash`.** `refs/stash` is a single ref shared across every worktree of a repository.
  Two agents popped each other's changes today. If you need to set work aside, commit it on your own
  branch.
- **NEVER run `yes`, and never pipe into an interactive command.** Thirty-four orphaned `yes` processes
  burned ~1500% CPU for sixteen minutes on the owner's machine today. If a command wants confirmation,
  find its non-interactive flag (`-y`, `--force`, `--non-interactive`) or **report that it needs one**.
- Do not commit, push, or open a PR unless your brief says to.

### Acceptance gate — every workstream, before claiming done

```bash
cd <worktree>/firmware && ~/.beacon-pio/bin/pio test -e native    # 0 failures
cd <worktree>/firmware && ~/.beacon-pio/bin/pio run   -e beacon   # SUCCESS
cd <worktree>/hub      && swift build && swift test               # 0 failures
```

**Always pass `-e beacon`.** A bare `pio run` also builds `[env:native]`, which has no `main()` and
reports `FAILED` — a red build that means nothing.

Run one firmware suite with `~/.beacon-pio/bin/pio test -e native -f "*test_sonos_art*"`.

**Current floors (2026-07-27, branch `ad888af`):**

| Metric | Floor |
|---|---|
| hub tests | **485** |
| firmware tests | **295** |
| Swift deprecation warnings | **0** |
| `pio run -e beacon` | **SUCCESS** |

Never go below any of them. Each workstream states its own new floor as this baseline plus its stated
delta. A workstream that adds tests but leaves the total unchanged has deleted coverage somewhere and
must explain it.

**Measure the deprecation counter only on a clean build.** An incremental build reports 0 regardless,
because the compiler does not re-emit diagnostics for unchanged modules:

```bash
cd <worktree>/hub && rm -rf .build && swift build 2>&1 | grep -ci "deprecat" || true   # must print 0
```

### Repo conventions that are easy to violate

- **A new non-header firmware `.cpp` that host tests link must be added to `build_src_filter` under
  `[env:native]` in `firmware/platformio.ini`,** or the suite fails with an undefined symbol. This is
  the single most common "new suite doesn't build" cause in this repo.
- Files in `build_src_filter` must be Arduino-free, or must fence their hardware half with
  `#if !BEACON_NATIVE`. `firmware/src/config/ticker_store.cpp:100` and `firmware/src/core/ds_lock.h`
  are the working precedents.
- **ASCII only** in firmware source and comments (`=>`, never the arrow glyph).
- **No secrets, ever** — this repo is public. Never log a token, a path token, or a URL containing one.
- Read `firmware/src/ui/screens/views/CONVENTIONS.md` before editing anything under `views/`. It is the
  authority there: `build()` creates, `update()` changes text/values/show-hide only and is **read-only
  w.r.t. layout**.
- Conventional Commits: `type(scope): subject`, lowercase imperative, scopes `firmware`/`hub`/`docs`/`ci`.

---

## 3. Decisions this plan settles that the design left implicit

A cold agent would have to guess each of these. They are settled here; the reasoning is recorded so a
reviewer can overturn one on purpose rather than by accident.

**D-1. The device must report its IP, and this project owns that frame.**
Design §7 adopts OTA §7's security model "unchanged", which includes *"accept only connections whose
remote endpoint matches the device's IP as reported in D1"*. **D1 does not exist.** `cmd:"report"`
guards `what == "tickers"` on both ends (`hub_report.cpp`; `Protocol.swift DeviceCommand.parse:378`),
so the hub has never learned the device's IP. This is not optional garnish: the hub also needs the
device's IP to pick *which of its own interfaces* to advertise in the URL, on a Mac with Wi-Fi +
Ethernet + a VPN `utun` + a Thunderbolt bridge. **WS-0 adds `cmd:"report","what":"device"` carrying
`ip` only.** OTA's Phase 0 widens the same frame with `fw`/`slot`/`slotsz`/`appsz`/`hatch`/`pend`; that
widening is additive and this plan does not do it.

**D-2. `gen` is an identity, not an ordering. The device compares with `!=`.**
The hub's `gen` counter lives in memory and restarts after a hub relaunch (design §5: *"Hub relaunch:
in-memory cache is gone"*). A device still holding `gen = 7` would then be handed `gen = 1` and, under
a `>` comparison, would ignore it forever. **The device treats `gen` as an opaque tile identity:
`rec.gen != rec.seen_gen` means "re-point", full stop.** uint32 wrap is a non-issue under the same rule.

**D-3. The art state lives in its own record, not in `sonos_rec_t`.**
`hub_parse_sonos` is documented as a **full snapshot** — every call fills `*out` fresh and the caller
in `hub_task.cpp:236` passes a bare stack struct, so any field added to `sonos_rec_t` is **zeroed by
every `sonos` frame**. Putting `gen`/`idx`/`seen_gen` there would silently clear the art roughly every
five seconds, and the symptom would be a tile that flickers away for no reason. A separate
`sonos_art_rec_t` with its own `ds_set_sonos_art()` / `ds_get_sonos_art()` / `ds_sonos_art_seen()` is
also what enforces design §2.3's *"absence of a `sart` frame must never mean clear the art"*.

**D-4. `LanAssetServer.arm()` cannot return a `URL` synchronously.**
The OTA plan sketches `func arm(...) -> URL`. `NWListener` assigns an ephemeral port asynchronously —
`listener.port` is nil until the listener reaches `.ready`. The real signature is completion-based:

```swift
func arm(_ data: Data, contentType: String, peer: IPv4Address,
         ttl: TimeInterval, maxServes: Int,
         completion: @escaping (Result<URL, LanAssetServer.ArmError>) -> Void)
func disarm()
```

This is a divergence from the OTA plan's prose, not from its intent. WS-5 records it.

**D-5. The sleep assertion is a first-class injectable seam, so "the art path takes none" is testable.**
Design §7.2 requires a test asserting the art path takes no `.idleSystemSleepDisabled` assertion, and
"the source file contains no `beginActivity`" is not a test. WS-1 introduces
`hub/Sources/beacon-hub/PowerAssertions.swift`:

```swift
protocol PowerAsserting: AnyObject { func begin(_ reason: String) -> UUID; func end(_ token: UUID) }
enum PowerAssertions { static var shared: PowerAsserting = ProcessInfoPowerAssertion() }
```

`LanAssetServer` **takes no `PowerAsserting` parameter and never references `PowerAssertions`** — a
compile-time fact. The behavioural test swaps in a `PowerAssertionSpy`, runs a full art
arm → serve → disarm cycle, and asserts `spy.beginCount == 0`. OTA's WS-3 later uses the same seam from
the other side to assert its own path takes exactly one. **This seam is the deliverable that makes
design §7.2 checkable; do not inline the assertion into `FirmwareUpdateService` later without it.**

**D-6. The toggle clears, it does not go quiet.**
Turning album art off in Settings must **publish S2 with a fresh `gen`**, then stop arming. Merely
ceasing to send `sart` would leave the last tile on the glass forever, because absence never clears
(design §2.3). Turning it back on republishes from a cleared cache.

**D-7. `imageUrl` reaches the publisher on its own hook, not by widening `onUpdate`.**
`SonosProvider.onUpdate` is a five-positional-argument closure whose payload is deliberately
"the raw tuple the plan's brief specifies, not a wire/frame type", and `combineNowPlaying` suppresses
the callback entirely when the tuple is unchanged (`guard np != lastSent`). Art that changes while the
text does not — a station rotating cover images under one title — would be swallowed. **WS-4 adds a
separate `var onArtURL: ((String?) -> Void)?` fired from `combineNowPlaying` with its own
last-URL comparison, before and independent of the `lastSent` text gate.**

**D-8. `sart` is CONTRACT.md §A4; OTA's `ota` block moves to §A5.**
§A3 is complications. The OTA plan claims §A4 for `ota`; album art lands first and takes it. WS-5 makes
the one-line correction in `docs/plans/2026-07-27-ota-updates-plan.md` (§7).

**D-9. A `sart` frame that arrives with no tile buffers allocated is dropped silently.**
Buffers are allocated in the `sonos` screen's `build()`. `carousel_init()` runs in `setup()` **before**
`hub_task_start()`, and `on_theme()` builds *every* page, not just the visible one — so if `sonos` is in
the page list, its buffers exist before BLE can deliver a frame. If it is not in the list, `build()`
never runs, no bytes are allocated, and a stray `sart` must **not** fetch and must **not** emit a
`sart_stat`. This matches CONTRACT.md §D's silent-withdraw precedent.

---

## 4. The workstreams

### WS-0 — the shared substrate (wave A, sequential, single owner)

#### Goal

Freeze the `sart` / `sart_stat` wire in one head: `hub/CONTRACT.md` §A4, the Swift encoder/decoder, the
firmware parser/builder, the device-side art record, the device IP report, and P-1's Info.plist key.
Nothing renders and nothing downloads at the end of this workstream — but the parser and the encoder are
provably the same shape, and every wave-B workstream has a compiling seam to build against.

#### Files to touch

- `hub/Info.plist` — add, beside the existing `NSBluetoothAlwaysUsageDescription`:
  ```xml
  <key>NSLocalNetworkUsageDescription</key>
  <string>Beacon Hub serves album art and firmware images to your Beacon device over your local network. Nothing leaves your Mac except the images themselves.</string>
  ```
  **Read the comment above `NSBluetoothAlwaysUsageDescription` first**: this plist is embedded into the
  binary via a linker `__info_plist` section declared in `hub/Package.swift`, *and* copied into the
  bundle by `hub/build-app.sh:127`. Both paths pick the change up automatically; **do not add a second
  copy of the key anywhere and do not touch `Package.swift` or `build-app.sh`.** Confirm with:
  `./build-app.sh && plutil -p "Beacon Hub.app/Contents/Info.plist" | grep LocalNetwork`.
- `hub/CONTRACT.md` — new **§A4** (`sart`, S1/S2, caps, the absence-never-clears rule, the
  no-escapable-characters property from design §2.1), and `sart_stat` + `report what:"device"` in §B.
  Copy design §2.2/§2.3's byte tables verbatim, including the reasoning for why this is a separate frame
  (design §10 risk 6 exists because someone will propose folding it into `sonos`).
- `hub/Sources/BeaconHubKit/Protocol.swift`:
  - `public struct SonosArtFrame: Codable` → `{"sart":{"gen":N,"url":"..."},"v":1}` with `url` omitted
    for S2. `JSONEncoder(.sortedKeys)`, newline-terminated, matching every other hub→device frame.
    **No shrink loop** — every byte is drawn from `[0-9a-f.:/htp]`, none of which JSON escapes, so the
    139 B worst case is provable rather than measured. Add an `encoded()` that asserts
    `count <= 1024` in a test, not at runtime.
  - `DeviceCommand` gains `case sartStat(gen: UInt32, ok: Bool, err: String?)` and
    `case deviceReport(ip: String?)`. Parse `cmd == "sart_stat"` and `cmd == "report"` with
    `what == "device"`. **Leave the existing `what == "tickers"` guard exactly as it is** — it is what
    makes an older hub drop a newer report cleanly.
- `firmware/src/core/records.h`:
  ```c
  #define SONOS_TILE_W      200
  #define SONOS_TILE_H      200
  #define SONOS_TILE_BYTES  (SONOS_TILE_W * SONOS_TILE_H * 2)   /* 80000 */
  #define SONOS_ART_URL_LEN 97    /* 96 chars + NUL (CONTRACT §A4 cap) */
  #define SONOS_ART_ERR_LEN 16    /* 15 chars + NUL */
  typedef struct {
    uint32_t gen;       /* hub-minted tile identity; 0 = no art has ever been published */
    uint32_t seen_gen;  /* Core 1 writes this back after re-pointing the lv_img */
    uint8_t  idx;       /* which buffer the record currently points at (0 or 1) */
    bool     have;      /* a complete, length-verified tile is present in buf[idx] */
  } sonos_art_rec_t;
  ```
  With a comment stating **D-2** (identity, not ordering) and **D-3** (why this is not in `sonos_rec_t`).
- `firmware/src/core/datastore.{h,cpp}` — `ds_get_sonos_art()`, `ds_publish_sonos_art(uint32_t gen,
  uint8_t idx)`, `ds_clear_sonos_art()` (S2 — sets `have=false`, bumps nothing else),
  `ds_sonos_art_seen(uint32_t gen)`. All under the existing `s_lock`; all pure struct copies, no I/O
  under the lock (`tech.md` §6).
- `firmware/src/core/hub_proto.{h,cpp}`:
  ```c
  typedef struct { uint32_t gen; char url[SONOS_ART_URL_LEN]; bool has_url; } hub_sart_t;
  bool   hub_parse_sart(const char* json, size_t len, hub_sart_t* out, bool* had_sart);
  size_t hub_build_sart_stat(char* buf, size_t cap, uint32_t gen, bool ok, const char* err);
  size_t hub_build_device_report(char* buf, size_t cap, const char* ip);
  ```
- `firmware/src/core/hub_report.{h,cpp}` + `firmware/src/core/hub_task.cpp` — emit the `what:"device"`
  report once per connection, **alongside** the existing ticker report at the `!s_reported` site
  (`hub_task.cpp:188`), using the same latch-only-on-full-success discipline. IP from
  `WiFi.localIP().toString()`; emit **no** `ip` key when WiFi is down rather than an empty string.
- `firmware/test/test_sart_proto/test_main.cpp` — new suite.
- `hub/Tests/BeaconHubKitTests/ProtocolTests.swift` — extend.

#### Files NOT to touch

`firmware/src/ui/**` (WS-2/WS-3), `firmware/src/core/fetch_task.cpp` and `net*.{h,cpp}` (WS-2),
`hub/Sources/beacon-hub/**` in its entirety (WS-1/WS-4), `hub/Package.swift`, `hub/build-app.sh`,
`docs/**` except nothing (this workstream writes no docs; WS-5 does).

#### Acceptance gate

```bash
cd <wt>/firmware && ~/.beacon-pio/bin/pio test -e native && ~/.beacon-pio/bin/pio run -e beacon
cd <wt>/hub      && rm -rf .build && swift build 2>&1 | grep -ci deprecat || true   # 0
cd <wt>/hub      && swift test
```

**Floors: hub >= 497 (485 + >= 12), firmware >= 309 (295 + >= 14), 0 deprecation warnings, `-e beacon`
SUCCESS.**

Required coverage beyond the count:

- **A byte-exact S1 round-trip.** Encode `SonosArtFrame(gen: 7, url: "http://192.168.1.42:54321/a/" +
  32 hex)` in Swift, assert the exact bytes, then feed **those same bytes** to `hub_parse_sart` in the
  firmware suite as a string literal. The two assertions must reference the same literal; if a future
  change breaks one, it must break both.
- **S1 at the cap.** `gen = 4294967295`, a 96-byte `url` → **exactly 139 bytes including `\n`**. Assert
  the number, not just `< 1024`.
- **S2 (no `url`)** → 34 bytes; `has_url == false`; the parser leaves `out->url` empty.
- **S3** `sart_stat` ok and err forms; `err` at the 15-byte cap (`conn_refused`) → 75 bytes.
- **Over-cap `url`** (97+ chars on the wire) is rejected or truncated deterministically — pick
  rejection, and test it. A truncated URL is a guaranteed-failing fetch that looks like a network fault.
- **Absence never clears:** a `sonos` frame arriving after a `sart` leaves `sonos_art_rec_t` untouched.
  This is D-3's regression test and it is the single most valuable test in this workstream.
- **`gen` identity, not ordering:** `seen_gen = 7`, new `gen = 1` → must be treated as new.
- **Back-compat both directions** (design §2.4). Three assertions, and they are about what must *not*
  change: (a) a `sart` frame handed to `hub_parse_status` returns false and fills nothing — the
  old-firmware path, identical to how `sessions`/`sdetail`/`sonos`/`comps`/`pages` each landed;
  (b) `DeviceCommand.parse` still returns `nil` for an unknown `cmd`; (c) `report` with
  `what:"tickers"` parses exactly as it does today, byte for byte.

#### Traps

- **`frame_has()` dispatch is a substring scan, and order matters.** `on_frame` in `hub_task.cpp`
  dispatches on `"\"config\""`, `"\"pages\""`, `"\"comps\""` **before** falling through to
  `hub_parse_status`, and the header comment on `hub_parse_comps` says in as many words that a frame not
  dispatched before the fall-through is silently swallowed. WS-2 adds the `"\"sart\""` dispatch; WS-0
  only supplies the parser. Say so in the header comment so WS-2 cannot miss it.
- **`HUB_FRAME_MAX` is 1024 and longer frames are silently dropped.** Nothing here comes close, but the
  assertion belongs in the test, not in a comment.
- Do not add a `w`/`h` to the frame (design §2.3: the tile is 200x200 by contract) and do not add a
  digest (design §2.3 explains at length why art deliberately diverges from OTA here).
- `hub_proto.cpp` is already in `[env:native]`'s `build_src_filter`. `hub_report.cpp` is too. **No
  `platformio.ini` change is needed in this workstream** — if you think you need one, you have put code
  in the wrong file.

#### Rollback

One commit. Reverting it removes an unused wire schema and one Info.plist key; nothing else in the tree
references either. This is the cheapest revert in the project and it is the reason it goes first.

---

### WS-1 — `LanAssetServer` (wave B, parallel)

#### Goal

**Build the general LAN byte-serving component the OTA design specified and album art needs first.**
Write it for generality: OTA will serve a **~1.8 MB firmware image** through this exact type, and its
brief (`docs/plans/2026-07-27-ota-updates-plan.md` WS-3) is written on the promise that *"the extension
surface is almost certainly nothing at all on the server's own API"*. **The server must never learn what
a pixel is** (design §1.5), and it must never learn what a firmware image is either.

#### Files to touch

- `hub/Sources/beacon-hub/LanAssetServer.swift` — **new.**
- `hub/Sources/beacon-hub/LanInterface.swift` — **new.** Picks the hub's own IPv4 address to advertise:
  enumerate interfaces via `getifaddrs`, choose the one whose `(addr & mask) == (deviceIP & mask)`.
  Split the arithmetic into a pure function over `(addr, netmask, deviceIP)` triples so it is testable
  without a network stack; keep only the `getifaddrs` walk impure.
- `hub/Sources/beacon-hub/PowerAssertions.swift` — **new.** See D-5. Tiny.
- `hub/Tests/beacon-hubTests/LanAssetServerTests.swift`, `LanInterfaceTests.swift` — **new.**

#### Files NOT to touch

`hub/Sources/beacon-hub/LocalIngestServer.swift` — **its 127.0.0.1 binding and POST-only routing are
security properties, not an accident.** Do not widen it, do not refactor a shared base class out of it,
do not "deduplicate" the response writer into it. Copy the response-writer shape from
`LocalIngestServer.swift:176-184` if you like; do not couple to it. Also off limits:
`hub/Sources/BeaconHubKit/**` (WS-0 froze `Protocol.swift`; WS-4 owns the new Kit files),
`SonosProvider.swift`, `AppDelegate.swift`, all of `firmware/`.

#### What exists vs what to build

Exists: `LocalIngestServer` as the working `NWListener` reference (lifecycle, rebind, response writer).
Nothing else. `LanAssetServer` does not exist in any form.

Build, to design §2.1 + §7 + §7.1:

```swift
final class LanAssetServer {
    enum ArmError: Error, Equatable { case listenerFailed(String), noRoutableInterface, alreadyArmed }
    func arm(_ data: Data, contentType: String, peer: IPv4Address,
             ttl: TimeInterval, maxServes: Int,
             completion: @escaping (Result<URL, ArmError>) -> Void)
    func disarm()
    var onServed: ((Bool) -> Void)?    // one call per completed/failed serve, for the caller's telemetry
}
```

Rules, every one of them an acceptance item:

1. **GET only. One route shape: `/a/<32-hex>`.** Anything else → 404, connection closed. No query
   parsing, no `Range`, no directory logic, no compression.
2. Fixed `Content-Length`, `Connection: close`, caller-supplied `Content-Type` (art passes
   `application/octet-stream` — see design §1.5 for why not `image/*`).
3. **Ephemeral port** (`NWEndpoint.Port.any`), armed only for the transfer, **never at rest**.
4. **128-bit single-use path token**: 32 hex chars from `SecRandomCopyBytes`, compared in **constant
   time** (a fixed-length XOR-accumulate over both byte arrays; not `==`, not `hasPrefix`).
5. **Source-address restriction**: accept only a remote endpoint matching `peer`; additionally reject any
   remote outside RFC1918 / link-local. Drop before reading a byte.
6. **`maxServes` and `ttl` are caller arguments, not constants.** Art passes `maxServes: 1, ttl: 30`;
   OTA will pass `3` and `600`. Nothing in the type may assume either.
7. **`disarm()` is idempotent** and is called on: first successful serve reaching `maxServes`, TTL
   expiry, or explicitly by the caller. After it, the listener is gone and the token is dead.
8. **No sleep assertion. No `PowerAssertions` reference of any kind.** See D-5.
9. **Payload-size agnostic.** No `80_000`, no `SONOS_`, no `Tile`, no `firmware`, no `ota` anywhere in
   this file, in any identifier or comment. The file header comment should name **both** callers.
10. Log id + outcome only. **Never the token, never the URL, never the payload.**

#### Acceptance gate

```bash
cd <wt>/hub && rm -rf .build && swift build 2>&1 | grep -ci deprecat || true   # 0
cd <wt>/hub && swift test
cd <wt>/firmware && ~/.beacon-pio/bin/pio test -e native && ~/.beacon-pio/bin/pio run -e beacon  # unchanged
```

**Floors: hub >= 509 (497 after WS-0 + >= 12), firmware 309 unchanged, 0 deprecation warnings.**

Required coverage — these are the tests OTA's WS-3 is explicitly told not to re-write, so they must be
here and they must be real (drive a genuine loopback `URLSession` GET against the armed listener, not a
mocked handler):

- Correct token serves the exact bytes once; the second request 404s (`maxServes: 1`).
- Wrong token → 404. Token differing in the last character → 404.
- `POST` to the correct path → 404.
- Path with a query string appended → 404.
- After `disarm()`, the port is closed (connection refused / no listener).
- TTL expiry disarms without a serve.
- **The generality proof, which is this workstream's headline deliverable:** the same `arm()` call
  round-trips a **2 KB `image/jpeg`** payload *and* a **1.8 MB `application/octet-stream`** payload with
  `ttl: 600, maxServes: 3`. Both, in one test file. OTA's plan makes this an acceptance item and points
  at this workstream for it.
- **`testArtSizedArmTakesNoSleepAssertion`** — install a `PowerAssertionSpy`, run arm → serve → disarm,
  assert `spy.beginCount == 0`. (D-5. The equivalent OTA-side assertion is not this workstream's.)
- `LanInterface`: a pure-function table of `(ifaceAddr, netmask, deviceIP) -> match?` covering
  `192.168.1.x/24` matching, `10.x` not matching a `192.168.x` device, two candidate interfaces where
  only one contains the device, and **zero matches → `noRoutableInterface`, never a guess**.

#### Traps

- **`NWListener.port` is nil until `.ready`.** D-4. Build the URL in the `.ready` state handler, not at
  the end of `arm()`.
- **macOS 15+ TCC.** WS-0 lands `NSLocalNetworkUsageDescription`; if you are testing against a `swift
  test` binary rather than the signed bundle, a LAN bind can still be denied. **Loopback tests are not
  affected** — write the unit tests against `127.0.0.1` and leave real-LAN verification to WS-5's
  on-glass rehearsal. Do not conclude from a green `swift test` that Local Network permission works.
- **Constant-time compare is the whole point of the token.** `String ==` short-circuits on the first
  differing byte. Compare fixed-length `[UInt8]` with an accumulating XOR and a single final zero check.
- **Do not hold the payload weakly or copy it per connection.** One `Data` for the armed window; a
  1.8 MB copy per connection is a real cost at OTA scale.
- **`allowLocalEndpointReuse`** is set on `LocalIngestServer` because it binds a fixed port. An
  ephemeral-port listener does not need it; do not cargo-cult it across.

#### Rollback

Two commits: (`PowerAssertions` + `LanInterface` + tests), (`LanAssetServer` + tests). Both are unused by
anything until WS-4 wires them, so either reverts cleanly. **Once OTA takes a dependency on
`LanAssetServer`, check for other callers before reverting it** — that is the shared-component tax and
it starts the moment this merges.

---

### WS-2 — device art transport (wave B, parallel)

#### Goal

The two PSRAM tile buffers, the cross-core swap protocol, the plain-HTTP LAN GET on `fetch_task`, and
the `sart` dispatch on `hub_task`. **This is the only genuinely concurrent object in the whole design
(design §10 risk 4), and its failure mode is a rare, unreproducible torn tile that no ordinary test will
catch.** Everything about the swap that can be a pure function must be a pure function.

#### Files to touch

- `firmware/src/core/sonos_art.{h,cpp}` — **new.** Owns the buffers, the pending job, and — crucially —
  the pure decision helpers. Split so the whole decision surface is host-testable:
  ```c
  /* ---- pure, host-tested, no Arduino, no LVGL, no allocation ---- */
  uint8_t sonos_art_back_idx(uint8_t front_idx);            /* 1 - front */
  bool sonos_art_may_write(uint32_t published_gen, uint32_t seen_gen,
                           uint32_t ms_since_publish, uint32_t ack_timeout_ms);
  bool sonos_art_should_repoint(uint32_t rec_gen, uint32_t seen_gen);   /* rec_gen != seen_gen */
  bool sonos_art_length_ok(int http_status, long content_length, size_t received);
  bool sonos_art_job_supersedes(uint32_t pending_gen, bool pending_present, uint32_t new_gen);
  const char* sonos_art_err_for(data_err_t e);              /* -> the frozen 6-value vocabulary */

  /* ---- device half, fenced with #if !BEACON_NATIVE except where noted ---- */
  bool     sonos_art_alloc(void);      /* 2 x heap_caps_malloc(SONOS_TILE_BYTES, MALLOC_CAP_SPIRAM) */
  uint8_t* sonos_art_buf(uint8_t idx); /* NATIVE TOO -- see the test section */
  void     sonos_art_post_job(uint32_t gen, const char* url);  /* hub_task -> fetch_task */
  void     sonos_art_clear(void);                              /* S2 */
  void     sonos_art_service(void);                            /* called from fetch_task each 1 s loop */
  ```
- `firmware/src/core/net_lan.{h,cpp}` — **new.**
  ```c
  /* Plain-HTTP LAN GET straight into a caller buffer. No TLS: a WiFiClientSecure costs a
     ~40-50KB mbedtls handshake (net.cpp:21) against a 46,428 B observed internal-heap floor.
     OTA's WS-2 later extends this with a streaming variant that feeds Update.write(). */
  data_err_t net_lan_get(const char* url, uint8_t* out, size_t expect_len,
                         const char** err_out, volatile bool* abort_flag);
  ```
- `firmware/src/core/hub_task.cpp` — dispatch `"\"sart\""` **before** the loc/status fall-through,
  alongside `"\"config\""` / `"\"pages\""` / `"\"comps\""`. On S1: `sonos_art_post_job(gen, url)`.
  On S2: `ds_clear_sonos_art()`. **Never download here** — an 8 s worst case on a 20 ms loop would stall
  permission-prompt round trips, which is the entire reason that loop runs at 50 Hz.
- `firmware/src/core/fetch_task.cpp` — call `sonos_art_service()` once per 1 s iteration. **Not gated on
  `timekeep_has_time()`** (art needs no clock) but **gated on `net_is_up()`** — a job posted while WiFi
  is down answers `err:"no_wifi"` immediately, without attempting a connect (design §8).
- `firmware/platformio.ini` — add `+<core/sonos_art.cpp>` to `[env:native]`'s `build_src_filter`.
  **`net_lan.cpp` is Arduino-coupled and must NOT be added** — keep every testable decision in
  `sonos_art.cpp` so `net_lan.cpp` is a thin socket loop with nothing to unit-test.
- `firmware/test/test_sonos_art/test_main.cpp` — **new.** See §5.

#### Files NOT to touch

`firmware/src/ui/**` (WS-3 owns `sonos_editorial.cpp` and `dev_seed.cpp`), `firmware/src/core/net.{h,cpp}`
(the TLS path is not yours; `net_lan` is a separate file for exactly that reason),
`firmware/src/core/records.h` / `hub_proto.*` / `datastore.*` (WS-0 froze them — if you need a change
there, **stop and report** rather than editing), all of `hub/`.

#### The swap protocol, restated as implementable rules

Straight from design §4.3, with the failure that each rule exists to prevent:

1. The record carries `{gen, idx, seen_gen, have}` under the existing DataStore mutex. `idx` selects
   which buffer the `lv_img_dsc_t` points at.
2. **Core 0 only ever writes the buffer the record does *not* point at.** Prevents a torn tile
   structurally: the write target is never the displayed buffer, so nothing incomplete is ever shown.
3. Core 0 publishes `(idx, gen)` **only** on a complete, length-verified download — `200` **and**
   `Content-Length == 80000` before reading a byte, **and** exactly 80,000 bytes received. The read is
   additionally capped at 80,000 regardless of the header, so a lying `Content-Length` cannot overrun.
4. Core 1's 500 ms tick re-points `lv_img` when `gen != seen_gen`, then writes back `seen_gen = gen`.
5. **Core 0 must not begin writing the back buffer until `seen_gen == published_gen`, or 3,000 ms have
   elapsed since the publish.** The timeout covers the case where the `sonos` page is not currently
   built — nobody will ever ack, and nobody is reading the buffer either, so proceeding is safe. **The
   default on any doubt is: do not start writing.** "Two tracks cannot change within one tick" is a
   timing assumption and rapid track changes are explicitly in scope.
6. **Latest-wins.** At most one art job is held. A newer `gen` replaces a pending job; if a download is
   already running, it sets an abort flag checked on **every** socket read. **A superseded `gen` emits
   no `sart_stat`** — matching CONTRACT.md §D's silent-withdraw precedent.

**Coupling to record for the future:** if the crossfade (design §11 Q2) ever ships, both tiles are read
during the transition, so `seen_gen` must be written at **crossfade end**, not at swap start. Put that
sentence in `sonos_art.h`, not only here.

#### Deadlines and budgets

Connect **3 s**, per-read idle **3 s**, overall hard abort **8 s** (design §4.5) — an order of magnitude
tighter than OTA because the payload is 22x smaller and the user is looking at the screen.

Allocation: both buffers `heap_caps_malloc(SONOS_TILE_BYTES, MALLOC_CAP_SPIRAM)` on the `sonos` screen's
first `build()`, **never freed** (design §4.2 — there is no allocation in the steady state, so there is
nothing to leak and nothing to fragment). If `sonos` is not in the page list, `build()` never runs and
**not one byte is allocated**. Handle `sonos_art_alloc()` failing: log loudly, leave `have=false`
forever, and treat every subsequent `sart` as D-9 (drop, no stat).

#### Acceptance gate

```bash
cd <wt>/firmware && ~/.beacon-pio/bin/pio test -e native -f "*test_sonos_art*"
cd <wt>/firmware && ~/.beacon-pio/bin/pio test -e native && ~/.beacon-pio/bin/pio run -e beacon
cd <wt>/hub      && swift build && swift test    # unchanged: 497
```

**Floors: firmware >= 327 (309 after WS-0 + >= 18), hub 497 unchanged, `-e beacon` SUCCESS.**

Required coverage: the whole of §5 below, plus `sonos_art_err_for` mapping every `data_err_t` the LAN
path can produce onto exactly one of the frozen six (`conn_refused`, `timeout`, `http`, `size`, `net`,
`no_wifi`) — **`timeout` and `conn_refused` must never collapse into one value**; they are precisely the
evidence WS-4's Local Network row consumes (design §2.3).

#### Traps

- **The 5 s task watchdog will panic-reboot the device if you busy-read.** `CONFIG_ESP_TASK_WDT_
  CHECK_IDLE_TASK_CPU0=y`, `TIMEOUT_S=5`, `PANIC=y`. `net.cpp`'s cooperative drain
  (`read_body_bytes`, issue #92) exists because `Stream::timedRead` busy-spins with no yield and starved
  IDLE0 on this exact task. **Gate every read on `available()` and `vTaskDelay(pdMS_TO_TICKS(1))` when
  the socket is empty.** This is not optional and it is not a performance nicety.
- **Read straight from the socket into PSRAM.** `WiFiClient::read(tile + off, n)` memcpy's from lwIP's
  pbufs directly. **Zero staging bytes** — do not reuse `fetch_scratch()` here, and do not allocate a
  chunk buffer. Unlike OTA, art needs no sector alignment.
- **`CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=4096`** — any allocation of 4096 B *or less* is forced into
  internal DRAM. 80,000 B is well over, so `heap_caps_malloc(..., MALLOC_CAP_SPIRAM)` behaves; but do
  not "optimise" by allocating small helper buffers and expecting PSRAM.
- **`on_frame`'s fall-through swallows anything you forget to dispatch.** Add the `sart` check beside the
  `comps` check, and add a test that a `sart` frame does not reach `hub_parse_status`.
- **Never call `ds_*` from inside a socket read loop.** Publish once, at the end, on success.
- The abort flag must be `volatile` and checked on every read, not once per 4 KB.

#### Rollback

Three commits: (`sonos_art.{h,cpp}` + `test_sonos_art` + `platformio.ini`), (`net_lan.{h,cpp}`),
(`hub_task`/`fetch_task` wiring). Reverting the third leaves two tested, unreferenced modules and a
device that never downloads — a clean degraded state, and **the one to reach for first if anything on
the device misbehaves in the field.**

---

### WS-3 — device layout: the two-form `sonos` screen (wave B, parallel)

#### Goal

The 466x466 layout in both forms, and the capture seeding that lets anyone see them without a hub, a
network, or a Sonos account.

#### Files to touch

- `firmware/src/ui/screens/views/sonos_editorial.cpp` — the only view file. `THEME_COUNT` is **1**
  (`firmware/src/ui/theme_catalog.h:21`), so there is exactly one visual treatment to build.
- `firmware/src/ui/dev_seed.{h,cpp}` — **`dev_seed.cpp` seeds no Sonos data at all today.** Add a seeded
  `sonos_rec_t` (room/track/artist/album/playing) *and* a synthetic tile, behind the existing
  `BEACON_DEV` guard. See the capture section.
- `firmware/platformio.ini` — **do not touch.** WS-2 is wave B's only writer. If you need a new capture
  env, hand the stanza to WS-5 rather than editing it here.

#### Files NOT to touch

`firmware/src/core/**` in its entirety (WS-0 and WS-2 own it — you *read* `ds_get_sonos_art()` and
`sonos_art_buf()`, you do not modify them), `firmware/src/ui/comps/comp_sonos.cpp` — **the Home
complication does not show art, settled** (design §3.5, decision 4 above); `firmware/src/ui/capture.cpp`,
all of `hub/`.

#### The two forms

**Both are built in `build()` as two containers; `update()` only toggles `LV_OBJ_FLAG_HIDDEN`.**
`views/CONVENTIONS.md` allows `update()` to change text/values/show-hide and requires it to be
**read-only w.r.t. layout**, so re-aligning widgets per tick is not available. The cost is ~6 extra LVGL
objects out of the PSRAM pool — a few hundred bytes, once.

Existing offsets in this file are expressed as `lv_obj_align(o, LV_ALIGN_TOP_LEFT, SAFE_INSET,
SAFE_INSET + N)`, i.e. `N = y - 40`. Keep that idiom.

**The masthead change applies to BOTH forms** — the top 104 px is byte-identical whether or not there is
art, which is what makes the switch read as quiet rather than as a jump:

- `s_room` stays at `SAFE_INSET + 34` (y=74), mono + accent, letter-space 2.
- **`s_state` moves from `LV_ALIGN_BOTTOM_LEFT` to the masthead row, right-aligned:**
  `lv_obj_align(s_state, LV_ALIGN_TOP_RIGHT, -SAFE_INSET, SAFE_INSET + 34)`. Its right edge lands at
  x=426 = 466-40, satisfying `DESIGN.md`'s rule that edge-spanning rows keep end content >= 40 px from
  the side edges. Keep the existing colour logic (`accent` when playing, `ink_dim` when paused, `ink_dim`
  when `sv_dim`).
- `s_rule` (the hairline) stays at `SAFE_INSET + 64` (y=104), 386 x 1.

**Art form** (design §3.2) — used when `art.have && art_enabled`:

| Widget | Position | Font / style |
|---|---|---|
| tile (`lv_img`) | `LV_ALIGN_TOP_LEFT, 133, SAFE_INSET + 84` → x 133..333, y 124..324 | `lv_img_dsc_t`, `LV_IMG_CF_TRUE_COLOR`, 200x200 |
| `s_track_art` | `SAFE_INSET, SAFE_INSET + 304` (y=344) | `S.display` (f_display 30), width 386, `LV_LABEL_LONG_DOT` |
| `s_artist_art` | `SAFE_INSET, SAFE_INSET + 350` (y=390) | `S.body` (f_body 18), width 386, `LV_LABEL_LONG_DOT` |

**No album line in this form.** Tile centre x = 233 = 466/2. Every tile edge is >= 124 px from a panel
edge, nowhere near the corner arcs (`CORNER_R` 90).

**No-art form** (design §3.3) — **phase 1's shipped layout, verbatim, plus the masthead change.** Used
when the hub sent S2, when no `sart` has ever arrived, when the Settings toggle is off, or when every
fetch has failed and there is no previous tile. Track at `SAFE_INSET + 82` (y=122), artist at
`SAFE_INSET + 140` (y=180), **album returns** at `SAFE_INSET + 176` (y=216). A 200 px void above
stranded text would read as a missing element rather than as composition, which is why this is a second
form and not "the art form with the tile hidden".

`no_track` (loading, or nothing playing) is **unchanged**: placeholders, no play-state claim, no tile,
and always the no-art form.

**Hub-offline** (design §8): the tile keeps showing the last art, **dimmed**, via
`lv_obj_set_style_img_opa(tile, LV_OPA_40, 0)`, alongside the existing text dimming and status chip.
Opacity, not recolour: on a black canvas, reducing opacity toward black *is* dimming, at no extra draw
pass. Blanking would assert "nothing playing", which is a different and false claim.

#### The `update()` contract for the tile

```
art = ds_get_sonos_art();
if (sonos_art_should_repoint(art.gen, art.seen_gen)) {
    dsc.data = sonos_art_buf(art.idx);
    lv_img_set_src(tile, &dsc);
    lv_obj_invalidate(tile);
    ds_sonos_art_seen(art.gen);          // the ack half of WS-2's rule 5 -- do not skip it
}
```

**`ds_sonos_art_seen()` is the ack Core 0 waits on.** If this line is dropped by a refactor, Core 0 stops
writing after the first tile and art silently freezes on track two. Comment it as load-bearing.

#### Capture seeding (this is how anyone sees the work)

`dev_seed.cpp`'s `seed()` currently sets weather/finance/usage/buddy/sessions and **nothing for Sonos**,
so `env:capture` renders the sonos screen in its `no_track` placeholder state today. Add:

- A seeded `sonos_rec_t`: room `"KITCHEN"`, track `"Black Hole Sun"`, artist `"Soundgarden"`, album
  `"Superunknown"`, `playing = true`, `hdr.last_updated = now`.
- A **synthetic tile** written into `sonos_art_buf(0)` and published with `ds_publish_sonos_art(1, 0)`.
  Make it a deterministic pattern with **known exact colours in known exact places**, not noise:
  a 4-quadrant red / green / blue / black field plus a 1 px white diagonal. Then the capture PNG is a
  byte-order oracle (see §6) and a geometry oracle at the same time.
- Gate the seed on `BEACON_DEV` exactly as the rest of `seed()` is.
- Extend the existing long-press state driver (`longpress_cb`, case 2/3 is the hub plane) so a long press
  on the sonos screen cycles LIVE → HUB_OFFLINE, which exercises the dimmed tile without a hub.

#### Acceptance gate

```bash
cd <wt>/firmware && ~/.beacon-pio/bin/pio run -e beacon      # SUCCESS
cd <wt>/firmware && ~/.beacon-pio/bin/pio run -e capture     # SUCCESS -- this build must also compile
cd <wt>/firmware && ~/.beacon-pio/bin/pio test -e native     # 309, unchanged by this workstream
cd <wt>/hub      && swift build && swift test                # unchanged: 497
```

**Floors: firmware 309 and hub 497, both unchanged by this workstream (view code is not host-testable);
both `-e beacon` and `-e capture` SUCCESS.** A workstream with no test delta must say so explicitly in its report and name
what covers it instead — here, that is §6's capture evidence.

**A capture PNG of both forms is a required deliverable of this workstream**, not of WS-5. Flash
`-e capture`, run `python3 tools/capture/grab.py --port <port> --out shots/`, and attach
`shots/editorial_SONOS.png`. If hardware is unavailable to the executing agent, say so plainly in the
report and hand the capture to WS-5 — **do not claim the layout is verified without the image.**

#### Traps

- **`extern const screen_view_t sonos_editorial_view = { build, update };` — the `extern` is required.**
  In C++ a namespace-scope `const` has internal linkage; omitting it compiles cleanly and then fails at
  link with `undefined reference` from `SCREEN_MODULE_SIMPLE`'s dispatch table.
- **Never create objects in `update()`.** Both containers exist after `build()`; `update()` toggles
  `LV_OBJ_FLAG_HIDDEN` and sets text.
- `lv_img_dsc_t` must be a **file-static that outlives the widget** — LVGL stores the pointer, it does
  not copy the descriptor. A stack-local descriptor renders garbage or crashes.
- `LV_IMG_CF_TRUE_COLOR` with `LV_COLOR_DEPTH 16` + `LV_COLOR_16_SWAP=1` means the buffer is **big-endian
  RGB565, high byte first**. `docs/perf.md` §2.1: *"Changing one without the other reverses every pixel's
  colour bytes."* The hub already emits big-endian (Phase A, tested). Do not byte-swap anything here.
- **`on_theme()` rebuilds every page**, so `build()` can run more than once. Buffer allocation must be
  idempotent (`if (already_allocated) return true;`) or a theme change leaks 160 KB. `THEME_COUNT` is 1
  today, which makes this a latent bug rather than a live one — write it correctly anyway.
- A tile change dirties 40,000 px ≈ **9 ms render + 5.4 ms blit** against `docs/perf.md`'s measured
  full-screen figures — roughly half of one full-screen blit, once per track. **Do not pause the
  carousel tick and do not suppress anything.**

#### Rollback

Two commits: (the two-form layout), (the dev-seed/capture additions). Reverting the first restores
phase 1's shipped text-only screen exactly, which is also what the Settings toggle falls back to — so
this revert is *cosmetically identical to the toggle being off* and is safe to reach for at any time.

---

### WS-4 — hub art pipeline, Settings toggle, Local Network row (wave C)

#### Goal

Turn a Sonos `imageUrl` into a `sart` frame the device can act on, at most once per genuine tile change,
with a Settings toggle that turns the whole thing off and a Connection row that tells the truth about
Local Network permission.

**Do not branch this until WS-1, WS-2 and WS-3 have merged.**

#### Files to touch

- `hub/Sources/BeaconHubKit/SonosArtDecision.swift` — **new, pure.** Everything about *whether* to
  publish, so it is host-testable without a network, a CDN, or CoreGraphics:
  ```swift
  public enum SonosArtAction: Equatable { case doNothing, clear, publish }
  public struct SonosArtCacheState: Equatable {
      public var lastImageUrl: String?
      public var lastTileDigest: String?
      public var lastPublishedAt: Date?
      public var gen: UInt32
  }
  public enum SonosArtDecision {
      public static func urlStep(newImageUrl: String?, state: SonosArtCacheState,
                                 artEnabled: Bool, now: Date, debounce: TimeInterval) -> SonosArtAction
      public static func digestStep(newDigest: String, state: SonosArtCacheState) -> SonosArtAction
      public static func nextGen(_ current: UInt32) -> UInt32
  }
  ```
- `hub/Sources/BeaconHubKit/LocalNetworkCheck.swift` — **new, pure.** Outcome-derived, because there is
  no API to query (design §0, OTA plan §3):
  ```swift
  public enum LanServeOutcome: Equatable { case neverAttempted, served, deviceErr(String) }
  public enum LocalNetworkCheck {
      public static func derive(_ o: LanServeOutcome) -> (state: CheckState, message: String?)
  }
  ```
- `hub/Sources/beacon-hub/SonosArtPublisher.swift` — **new.** The impure half: holds
  `SonosArtCacheState`, calls `SonosArtRenderer.fetchAndRender`, calls `LanAssetServer.arm`, emits the
  `sart` frame via a closure the `AppDelegate` supplies, consumes `sart_stat`.
- `hub/Sources/beacon-hub/SonosProvider.swift` — add `var onArtURL: ((String?) -> Void)?`, fired from
  `combineNowPlaying` **before and independently of** the `guard np != lastSent` text gate (D-7).
- `hub/Sources/beacon-hub/AppDelegate.swift` — construct the publisher; wire
  `provider.onArtURL`; route `DeviceCommand.sartStat` and `.deviceReport`; store the device IP;
  **re-publish on BLE (re)connect with a fresh token and a fresh `gen`** at the same site as
  `pushSonosFrame()` (`AppDelegate.swift:585`).
- `hub/Sources/beacon-hub/SonosSettingsView.swift` — the **Album art** toggle (Sources tab, in the
  existing Sonos section).
- `hub/Sources/beacon-hub/DeviceTab.swift` — a third `StatusRow` in `connectionSection`, "Local
  Network", beside Bluetooth and Device connected, with an **Open Settings** action pointing at the
  Privacy pane. Follow the existing `StatusRow` + `RowSeparator` idiom exactly.
- `hub/Sources/beacon-hub/HubViewModel.swift` — the published properties the two views bind to.
- Tests: `hub/Tests/BeaconHubKitTests/SonosArtDecisionTests.swift`,
  `LocalNetworkCheckTests.swift`, `hub/Tests/beacon-hubTests/SonosArtPublisherTests.swift`.

#### Files NOT to touch

`hub/Sources/beacon-hub/LanAssetServer.swift` and `LanInterface.swift` — **WS-1's, and their promise to
OTA is that they need no change for a second caller. If you find a genuine gap, report it rather than
editing.** Also: `hub/Sources/beacon-hub/SonosArtRenderer.swift` and `SonosAPI.swift` (Phase A's, done),
`LocalIngestServer.swift`, `hub/Sources/BeaconHubKit/Protocol.swift` (WS-0 froze it), all of `firmware/`.

#### Change detection — design §5, verbatim, because it is the difference between one BLE frame per track and one every five seconds

The provider polls every **5 s**. Two levels:

1. **URL level (cheap, first).** If `imageUrl` is byte-identical to the last one processed, **stop**.
   No HTTPS GET, no CoreGraphics, no BLE frame, no device work. This kills ~99% of ticks at zero cost.
2. **Tile level (correct, second).** If the URL changed, fetch and rasterise, then compare
   `Tile.sha256Hex` against the last published tile's digest. **Equal digest → no new `gen`, no arm, no
   frame.** This is what makes an expiring-signature URL cost one HTTPS GET instead of a BLE frame plus
   a device download plus a screen repaint.

**What identifies "same art" is the tile's bytes, not its URL.** Cloud services mint art URLs with
expiring signatures, so the same album can produce a different URL on consecutive polls; conversely a
station can serve one generic URL for every track. Keying on the URL alone gets both cases wrong.

`gen` increments **only** on a tile-digest change.

**Debounce:** do not arm or publish for a tile that has been current for **less than 2 s**. With the
current 5 s poll this is a no-op — which is exactly why it should be written down now, so a future
faster poller does not turn a scrub through a playlist into twenty listener arms.

**Cache invalidation:**

| Trigger | Effect |
|---|---|
| Tile digest differs from the last published | new `gen`, arm, **S1** |
| `imageUrl` absent / fetch fails / decode fails | `gen`+1, **S2** (no url) — art cleared, explicitly |
| Followed room changes | `groupCache` is already dropped by `setSelectedRoom`; next tick re-resolves and almost certainly republishes |
| **BLE (re)connect** | **re-arm with a fresh token and re-push S1 with a fresh `gen`.** Not optional: the device's tile lives in RAM, a rebooted device has none, the hub cannot tell a reconnect from a reboot, and the previous token is single-use and expired anyway. Mirrors how `sessions`/`sdetail`/`sonos` are all re-sent on connect. |
| Hub relaunch | in-memory cache is gone; first poll republishes (and see D-2 — the device must not care that `gen` went backwards) |
| **Album art toggled off** | `gen`+1, **S2**, then stop arming entirely (D-6) |

#### Arm parameters — strictly tighter than OTA on every axis (design §7.1)

`ttl: 30` (not 600), `maxServes: 1` (not 3), `contentType: "application/octet-stream"`,
`peer:` the device's reported IP. **And the gate that is a real gate, not a comment: arm only while the
`sonos` page is in the device's page list *and* the BLE link is up.** No Sonos page → the listener is
never created, not once. Read `hub/Sources/beacon-hub/PageConfigStore.swift` for the authoritative page
list; do not re-derive it.

**No sleep assertion.** `SonosArtPublisher` must never call `PowerAssertions.shared.begin`. Design §7.2:
taking `.idleSystemSleepDisabled` every three minutes all day would stop the user's Mac from ever
sleeping — a silent, user-hostile regression in an unrelated subsystem, caused entirely by sharing a
component.

#### The art fetch must not carry the Sonos credential

Design §6.2, and this is a security rule, not a detail. `imageUrl` is an absolute URL on a **third
party's CDN**, named by a **third-party JSON field**. `SonosProvider.api()` unconditionally attaches
`Authorization: Bearer` (`SonosProvider.swift:251`) — **it must not be reused for this.** Phase A's
`SonosArtRenderer.buildRequest` already builds a bare, header-free request on its own `URLSession`; use
it and do not route around it. In both the CDN case and the local-library case
(`http://<player-ip>:1400/getaa?...`) **no credential leaves the Mac and none reaches the device.**

#### Settings copy the user can actually read

Design §7.3's last bullet: because art arms the listener far more often than OTA will, the LAN listener
should be described in Settings, not only in a design document. The toggle's subtitle should say, in
plain words, that album art briefly opens a local-network connection so the device can fetch the image,
and that turning it off leaves the text-only page. **Do not say "TCP listener".**

#### Acceptance gate

```bash
cd <wt>/hub && rm -rf .build && swift build 2>&1 | grep -ci deprecat || true   # 0
cd <wt>/hub && swift test
cd <wt>/firmware && ~/.beacon-pio/bin/pio test -e native && ~/.beacon-pio/bin/pio run -e beacon
```

**Floors: hub >= 534 (509 after WS-0/WS-1 + >= 25), firmware 327 unchanged, 0 deprecation warnings.**

Required coverage:

- `SonosArtDecision`: identical URL → `doNothing` (the ~99% case, asserted first); changed URL →
  `publish`; nil URL → `clear`; a **different URL with an identical digest** → `doNothing` and **no
  `gen` bump** (the expiring-signature case, and the one a naive implementation gets wrong); art
  disabled → `clear` once then `doNothing`; the 2 s debounce in both directions.
- `SonosArtPublisher`: a `LanAssetServerSpy` records arm parameters — assert `ttl == 30`,
  `maxServes == 1`, `contentType == "application/octet-stream"`. Assert **no arm at all** when the
  `sonos` page is absent from the page list, and **no arm** when the link is down.
- **`testArtPublishTakesNoSleepAssertion`** — a `PowerAssertionSpy` sees `beginCount == 0` across a full
  publish cycle (D-5, design §7.2's acceptance item from the art side).
- The toggle: off → exactly one S2 emitted, then silence; on → republish.
- Reconnect → fresh `gen`, fresh arm, S1 re-pushed.
- `LocalNetworkCheck.derive`: `neverAttempted` → `.checking`; `served` → `.ok`;
  `deviceErr("timeout")` → `.bad` naming **Local Network permission**;
  `deviceErr("conn_refused")` → `.bad` naming the **macOS firewall**. **These two strings are the whole
  payoff of prerequisite P-1** — a generic "network error" for either throws it away. One test per value
  in the frozen six.
- `SonosProvider.onArtURL` fires when the art URL changes but the track text does not (D-7).

#### Traps

- **`combineNowPlaying`'s `guard np != lastSent` will swallow art-only changes** if you hang the art
  hook off `onUpdate`. D-7.
- **The URL host is the *hub's* LAN IP, not the device's.** The OTA design's H2 example uses the same
  address for both, which is a copy error in that document. Use `LanInterface` (WS-1) to pick the
  interface whose subnet contains the device's reported IP, and **fail the publish with a clear message
  if none matches, rather than guessing.**
- **Use the IPv4 literal, never a `.local` hostname.** The device has no mDNS resolver wired and adding
  one to this path is exactly the wrong dependency. The 96 B `url` cap was sized for a literal.
- **No pre-flight reachability probe.** Ruled closed for OTA on 2026-07-27 and it applies here for the
  same reason: a hub→device probe tests the wrong direction, and a green pre-flight followed by a hung
  transfer moves suspicion away from the cause. Arm, publish, and let it fail with a specific error.
- On any art failure, **publish S2, not silence.** The device must be told the art is gone (design §6.3).
- Log id + outcome only. **Never the token, never the art URL** (it is third-party and may carry
  identifiers), never a payload.

#### Rollback

Three commits: (the two pure Kit files + tests), (`SonosArtPublisher` + `SonosProvider` hook + tests),
(`AppDelegate` wiring + the two views). Reverting the third leaves tested, unreferenced components and a
hub that never publishes art — the device falls back to the no-art form on its own, because nothing
arrives. **That is the same end state as the Settings toggle being off**, which means this revert is
already a tested configuration.

---

### WS-5 — convergence, measurement, docs (wave D)

#### Goal

Prove it on real glass with a real Sonos account, replace the design's estimates with measurements, and
land the documentation changes design §12 lists.

#### Files to touch

- `docs/codemap.md` §1 — hub→device blocks **7 → 8** (`sart`); device→hub commands **6 → 8**
  (`sart_stat`, `report what:"device"`). Add the end-to-end art trace beside the four existing ones.
- `docs/recipes.md` §4 ("Add or change a hub → device frame field") — add `sart` as the worked example
  of a frame that needs **no shrink loop**, and why (design §2.1's no-escapable-characters property).
- `docs/perf.md` §3 — the **measured** PSRAM cost and the **measured** tile-change render/blit time,
  replacing design §3.4's estimate. Also record the observed internal-heap minimum across a listening
  session; design §4.1 claims ~4–8 KB transient and 0 permanent, and `docs/tech.md` principle 1 is
  evidence over assertion.
- `DESIGN.md` §Components — the Sonos art tile as a component, with the two-form rule.
- `docs/plans/2026-07-27-ota-updates-plan.md` — **exactly two one-line corrections**: its new CONTRACT
  block is **§A5**, not §A4 (D-8), and `LanAssetServer.arm` is completion-based, not
  synchronously-URL-returning (D-4). Do not restructure that plan.

#### End-to-end rehearsal (not optional, and not automatable)

1. Flash `-e beacon`. Confirm the device reports its IP (`what:"device"`) on connect — serial log.
2. Play a track on the followed room from a **cloud service with real cover art**. Confirm: `sart` S1 on
   the wire, one LAN GET, tile on glass within ~1.5 s, `sart_stat ok:true`, Local Network row `.ok`.
3. **Skip tracks rapidly** (5+ in 10 s). Confirm: no torn tile, superseded `gen`s emit nothing, the final
   tile matches the final track, and the heap does not walk.
4. Play the **SiriusXM station** that Phase A verified. Confirm the container-level logo renders.
5. **Follow-up capture, carried from Phase A:** get a Spotify session with a track actually loaded and
   record whether `imageUrl` is populated. Phase A's Spotify result was *inconclusive* (suspended
   session, no track), not negative. Record the answer in the PR body either way. **This is an
   observation, not a gate.**
6. **Turn the Settings toggle off.** Confirm S2 lands, the device switches to the no-art form, and the
   listener is never armed again (verify with `lsof -nP -iTCP -sTCP:LISTEN | grep beacon-hub` at rest —
   only 8765 should be present).
7. **Deny Local Network permission** (System Settings → Privacy & Security → Local Network → Beacon Hub
   off). Confirm the device reports `err:"timeout"` with zero bytes and the Connection row goes `.bad`
   naming Local Network. **Test the denied path, not only the granted one** — this is the failure P-1
   exists to make visible, and art exercises it many times a day instead of once a month.
8. Quit the hub mid-transfer. Confirm the device's read stalls into `err:"timeout"` and the **old tile
   stays**.
9. Put the Mac to sleep while music is playing. Confirm the device goes `ST_HUB_OFFLINE`, the tile dims
   to `LV_OPA_40` rather than blanking, and — the point of D-5 — **the Mac actually slept.**

#### Acceptance gate

Full gate, all three commands, plus the rehearsal above with serial logs or photos attached, plus a
capture PNG of both forms.

#### Rollback

Docs only plus the two OTA-plan lines. Nothing here is revertible-for-behaviour.

---

## 5. How the two-buffer swap gets tested without LVGL

`[env:native]` has no Arduino and no LVGL. That is not an obstacle here, because **almost none of the
swap protocol is LVGL.** The design's §4.3 is four rules about integers and a mutex; exactly one line of
it touches LVGL (`lv_img_set_src`). The split below is the design decision that makes it testable, and
it is WS-2's job to hold the line:

**Layer 1 — pure decision functions (`test_sonos_art/`, ~12 cases).**
`sonos_art_may_write`, `sonos_art_back_idx`, `sonos_art_should_repoint`, `sonos_art_length_ok`,
`sonos_art_job_supersedes`, `sonos_art_err_for` are all `(integers) -> bool/uint8/const char*` with no
state. Cases that must exist:

- `may_write` is **false** while `seen_gen != published_gen` and `ms_since_publish < 3000`.
- `may_write` is **true** at exactly 3000 ms with no ack (the page-not-built case).
- `may_write` is **true** the instant `seen_gen == published_gen`, regardless of elapsed time.
- `back_idx(0) == 1`, `back_idx(1) == 0`, and **`back_idx(front) != front` for both** — the property, not
  just the values.
- `should_repoint` is true for `gen=1, seen=7` (D-2: identity, not ordering) and false for `gen==seen`.
- `length_ok` rejects `status != 200`, rejects `content_length != 80000`, rejects `received != 80000`,
  accepts only all three.
- `job_supersedes`: a newer `gen` replaces a pending job; an identical `gen` does not re-post.

**Layer 2 — the concurrency itself, natively, with two real threads.**
This is the part people assume is untestable and it is not. `core/datastore.cpp` is already in
`[env:native]`'s `build_src_filter` and `core/ds_lock.h` is `std::mutex` on the host. So:

- Expose `sonos_art_buf(uint8_t idx)` on the native build too, backed by two plain `malloc`s (fence only
  the `heap_caps_malloc` call, not the accessor).
- The test spawns two `std::thread`s: a **writer** (Core 0) that repeatedly runs
  `may_write → fill the back buffer with a single repeated generation stamp → ds_publish_sonos_art`, and
  a **reader** (Core 1) that repeatedly runs `ds_get_sonos_art → should_repoint → read every byte of
  buf[idx] → ds_sonos_art_seen`.
- **The invariant the reader asserts: every byte of the buffer it was pointed at is the same stamp.**
  A torn tile is precisely "two stamps in one buffer". Run it for a few hundred publishes. Use a small
  tile size in the test (e.g. 4 KB) so the loop is fast; the protocol is size-independent.
- Add a second run with the writer *deliberately ignoring* `may_write` — it **must fail**, and that
  negative case is what proves the positive case is not vacuous. Assert the failure inside the test
  (count torn reads, expect `> 0`), do not leave it as a commented-out experiment.

This is a genuine race test, not a simulation: it uses the real `ds_lock_t`, the real record, and the
real decision functions. What it cannot exercise is the ESP32's two physical cores and their cache
coherency — which is why layer 3 exists.

**Layer 3 — on hardware, WS-5's rehearsal step 3.** Skip 5+ tracks in 10 seconds and look at the glass.
The only failure this can catch that layer 2 cannot is a memory-ordering effect between the two physical
cores, and the mitigation for that is that **every publish and every read goes through the DataStore
mutex**, which is a full barrier on both. If a torn tile ever appears in the field, the first hypothesis
is that someone read `sonos_art_buf()` outside the mutex-guarded `ds_get_sonos_art()` snapshot.

**What is NOT tested and must be stated in the PR:** the actual `lv_img_set_src` call, LVGL's internal
handling of a `TRUE_COLOR` descriptor whose data pointer changed, and the 500 ms tick cadence. Those are
covered by §6's capture evidence and the on-glass rehearsal, not by any suite.

---

## 6. What `env:capture` can and cannot prove

`env:capture` (`firmware/platformio.ini` `[env:capture]`, `firmware/tools/capture/grab.py`,
`firmware/src/ui/capture.cpp`) mirrors the **real RGB565 strips LVGL flushes to the panel** into a
466x466 frame and streams them over USB-CDC. These are the literal pixels sent to the glass, not a
re-render. It produced a real pixel diff for the complications work.

### It can prove

- **Exact geometry of both forms.** Tile at x 133..333 / y 124..324, the masthead's right-aligned play
  state ending at x=426, the hairline at y=104, track/artist baselines, safe-area compliance, nothing in
  the corner arcs. A ±1 px error is visible in the PNG.
- **That the two forms share the top 104 px byte-identically.** Capture both, diff the top strip. This is
  design §3.2's stated goal — "the switch reads as quiet rather than as a jump" — and it is the only way
  to check it that is not an opinion.
- **Byte order, end to end on the device side.** This is the non-obvious one and it is worth spelling
  out. The tile bytes bypass LVGL's rasteriser entirely — they go into an `lv_img_dsc_t` and are
  composited by LVGL into the flush buffer, and `capture_blit` byte-swaps on the way out precisely
  because `LV_COLOR_16_SWAP=1`. So a seeded tile whose quadrants are **known** pure red / green / blue /
  black will come back as pure red / green / blue / black in the PNG **if and only if** the device's
  interpretation of the buffer is big-endian. Get it wrong and red comes back as a dark blue-green. That
  closes the loop with Phase A's four-pixel hub-side test: the hub proves it *emits* big-endian, capture
  proves the device *consumes* big-endian, and neither test alone catches a mismatch.
- **The dimmed-on-hub-offline treatment** (`LV_OPA_40`), via the long-press state driver.
- **The no-art form is unchanged from what shipped**, by diffing against a capture taken before the
  change.
- Regression protection for all of the above, cheaply, on every future change.

### It cannot prove

- **Anything involving the LAN, BLE, or the hub.** Capture is `BEACON_DEV=1` with seeded records; no
  frame is parsed, no socket is opened. The wire is WS-0's tests' problem and WS-5's rehearsal's.
- **The two-buffer swap.** Capture takes a still after letting the screen settle ~200 ms; a torn tile is
  a transient during a write. §5 layer 2 and WS-5 step 3 cover this.
- **Timing.** Not the ~15 ms tile-change cost, not the ~1.5 s art-lands latency, not the 500 ms tick.
- **That real album art looks right.** This is design §10 **risk 7** — *"this is the first raster image in
  a product whose stated visual language is 'type carries hierarchy; no boxes/cards'"* — and a synthetic
  four-quadrant test pattern says nothing about whether a 200 px photographic square sits well next to
  Space Grotesk and a hairline rule. **A human must look at real covers on the real panel**, at least a
  dark one, a light one, a busy one, and a non-square station logo (to see the letterbox).
- **TCC / Local Network behaviour**, which is a macOS-side property with no device-side signal beyond
  `err:"timeout"`.
- **That the art is the *right* art** for the track — capture seeds a fixed pattern.

### The human-eyes list, explicitly

Risk 7 (does it look right), letterbox on a wide station logo, upscaling softness on a small source,
tile-change flicker on a real track skip, and the Settings copy reading like plain English. Everything
else in the visual layer has a mechanical check.

---

## 7. Docs this implies (WS-5)

Design §12's list, unchanged, plus the two OTA-plan corrections from D-4 and D-8. Reuse the existing
`docs/` structure — `docs/specs/`, `docs/plans/`, `docs/research/`, `docs/spikes/`. **Never create a new
top-level doc directory.**

---

## 8. Exit gate for the whole project

1. All three acceptance commands green from a clean tree, with the final floors:
   **hub >= 534, firmware >= 327, 0 deprecation warnings on a clean build, `pio run -e beacon` SUCCESS.**

   Per-wave arithmetic, so nobody has to re-derive it: baseline 485/295 → WS-0 (+12/+14) → **497/309**
   → wave B branches all start there; WS-1 (+12/0) and WS-2 (0/+18) and WS-3 (0/0) merge to
   **509/327** → WS-4 (+25/0) → **534/327**.
2. Capture PNGs of both forms attached, plus the top-104 px diff.
3. WS-5's nine-step rehearsal completed, including the **denied**-Local-Network path and the
   Mac-actually-slept check.
4. `docs/perf.md` carries **measured** PSRAM and tile-change render/blit numbers, not estimates.
5. `hub/CONTRACT.md` §A4 and §B match the code on both sides, and `docs/codemap.md`'s counts are right.
6. The Spotify follow-up capture is recorded in the PR body as an observation (pass or fail).

---

## 9. Open items — settled 2026-07-27, before WS-0 was dispatched

All three are now decided. Each entry keeps the original question so a reviewer can overturn a call on
purpose rather than by accident.

1. **D-1: does this project add the `what:"device"` report, or does art ship without an exact-IP peer
   restriction?** This plan assumes it adds it, because the hub *also* needs the device's IP to choose
   which of its own interfaces to advertise, so the alternative is not "slightly weaker security" but
   "cannot build the URL reliably on a multi-homed Mac". The cost is ~60 lines across
   `hub_report.cpp` / `hub_task.cpp` / `Protocol.swift` plus tests, and it makes OTA's Phase 0 smaller.
   **SETTLED: yes — album art opens the frame, carrying `ip` only, exactly as WS-0 specifies.** OTA's
   Phase 0 widens the same frame additively with `fw`/`slot`/`slotsz`/`appsz`/`hatch`/`pend`. This is the
   established extend-rather-than-create pattern (`sessions`, `sdetail`, `sonos`, `comps`, `pages` each
   landed the same way), and the ordering is arbitrary — whichever project shipped first would own it.
2. **The Settings toggle's default.** Design §11 Q4 recommends the toggle but does not say which way it
   ships. **SETTLED: default ON,** confirmed by the owner. Art is the feature; a default-off toggle means
   nobody sees it, and the duty-cycle concern (design §7.1) is already mitigated to
   strictly-tighter-than-OTA on every axis. WS-4 ships first-run with art enabled; the toggle exists for
   the network-conscious case, not as a gate on the feature.
3. **Does the hub's `gen` need to survive a hub relaunch?** **SETTLED: no.** D-2 makes persistence
   unnecessary (the device compares `gen` by inequality, never by ordering) and the reconnect rule
   republishes regardless, so a relaunched hub converges on its own. D-2's `!=` rule stays either way —
   it is precisely what makes the device correct when the counter *does* reset, so persisting `gen`
   would buy log-readability and nothing else.
