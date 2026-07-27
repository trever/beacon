# Plan: OTA firmware updates (hub serves, device installs)

**Status:** open. Written 2026-07-27. Self-contained — every workstream below assumes no prior session
context and is written to be lifted into a subagent brief almost verbatim.

**Design (source of truth, read it before touching anything):**
`docs/specs/2026-07-27-ota-updates-design.md`. It is decision-complete. Do **not** relitigate: the hub
fetches over TLS and serves the image to the device over the LAN; rollback + SHA-256 checksum ship in
the first cut; there is no post-update confirmation card; nothing ever auto-installs; the release
source is a Settings field defaulting to `trever/beacon`; the local-build path is an explicit
**Install current build** button; `SHA256SUMS` is added to the release workflow.

**Not in scope, and owned by another track — do not open these files:**
`docs/specs/2026-07-27-hub-app-and-home-complications-design.md`,
`docs/plans/2026-07-27-home-complications-plan.md`, and anything under
`firmware/src/ui/screens/views/home_editorial.cpp` that the complications track is editing.

---

## 0. The ordering constraint that dominates this plan

**The GPIO18 recovery hatch must ship in a USB-flashed image before any OTA-delivered image can
exist.** If the first OTA lands on firmware without the hatch and that image is broken, recovery is
USB + the ROM loader on a board that has **no reset button**.

The design enforces this in code, not by discipline (§0.2, §6.1, §13): the device advertises
`hatch:true` in its `what:"device"` report and **the hub refuses to send any `ota` frame to a device
that did not**. That interlock is part of the hatch workstream's acceptance gate, not a later nicety.

Consequences baked into the wave order below:

1. Phase 0 and WS-1 are **strictly sequential, single owner each**. Nothing runs in parallel with
   them. This is also what makes the firmware file boundaries trivial — Phase 0 and WS-1 may edit
   `hub_proto.cpp` / `hub_task.cpp` / `records.h` freely because nobody else is in the tree.
2. The parallel wave (WS-2…WS-5) may only start after WS-1 is merged **and a `firmware-v*` tag
   carrying the hatch has been built**. A hatch that is not on the device is not a hatch.
3. The first real OTA of any kind happens in WS-6, under the rehearsal procedure in §8 — never
   ad hoc.

---

## 1. Wave order and file ownership

| Wave | ID | Workstream | Parallel? | Component | Branch |
|---|---|---|---|---|---|
| A | **Phase 0** | Prerequisites + shared substrate (P-1, P-2, wire schema, hardware checks, seams) | **No** — single owner, sequential | both | `feat/ota-phase0-substrate` |
| B | **WS-1** | GPIO18 recovery hatch + Tier C, flashed and verified over USB | **No** — single owner, sequential | firmware | `feat/ota-recovery-hatch` |
| C | **WS-2** | Device OTA client: LAN GET, streaming SHA-256, `Update`, Tier A gate, overlay | yes | firmware only | `feat/ota-device-client` |
| C | **WS-3** | Hub `LanAssetServer` + release/local-build fetch + transfer orchestration | yes | hub (`AppDelegate` owner) | `feat/ota-lan-asset-server` |
| C | **WS-4** | Hub UI: Settings **Firmware** section, install controls, failure alert | yes | hub (view layer only) | `feat/ota-hub-settings-ui` |
| C | **WS-5** | `SHA256SUMS` in `release-firmware.yml` | yes | ci | `ci/ota-release-sha256sums` |
| D | **WS-6** | Convergence, docs, measurements, end-to-end + first-OTA rehearsal | **No** | both | `feat/ota-convergence` |

**The one hard file rule for wave C:** `hub/Sources/beacon-hub/AppDelegate.swift` belongs to **WS-3
only**. WS-4 must not open it. The seam that makes that possible (`FirmwareUpdateState` +
four closures on `HubViewModel`) is landed by Phase 0 precisely so the two hub workstreams never
touch the same declaration.

### Files, by exclusive owner

| Path | Owner |
|---|---|
| `hub/Info.plist` | Phase 0 |
| `.github/workflows/release-firmware.yml` | Phase 0 (one line: `FIRMWARE_VERSION`), then WS-5 (`SHA256SUMS`) |
| `hub/CONTRACT.md` | Phase 0 |
| `firmware/src/core/records.h`, `datastore.{h,cpp}`, `hub_proto.{h,cpp}` | Phase 0 |
| `firmware/src/core/hub_task.cpp` | Phase 0 (D1 emit), WS-1 (`hatch` flip), WS-2 (`ota` dispatch) — all serialized |
| `firmware/test/test_ota_proto/` | Phase 0 |
| `hub/Sources/BeaconHubKit/Protocol.swift`, `FirmwareUpdateState.swift` | Phase 0 |
| `firmware/src/core/ota_hatch.{h,cpp}`, `firmware/test/test_ota_hatch/`, `firmware/src/main.cpp` | **WS-1** |
| `firmware/README.md` | WS-1 |
| `firmware/src/core/ota.{h,cpp}`, `ota_gate.{h,cpp}`, `ota_offer.{h,cpp}`, `ota_rollback.cpp`, `net_lan.{h,cpp}` | **WS-2** |
| `firmware/src/ui/ota_overlay.{h,cpp}`, `firmware/test/test_ota_gate/`, `test_ota_offer/` | **WS-2** |
| `firmware/platformio.ini` | WS-2 (wave C's only firmware workstream) |
| `hub/Sources/beacon-hub/LanAssetServer.swift`, `FirmwareUpdateService.swift`, `LocalBuildSource.swift`, `AppDelegate.swift` | **WS-3** |
| `hub/Sources/BeaconHubKit/ReleaseSource.swift` | **WS-3** |
| `hub/Sources/beacon-hub/FirmwareSettingsView.swift`, `HubViewModel.swift`, `SettingsPanel.swift`, `MenubarController.swift` | Phase 0 creates, **WS-4** extends |
| `docs/tech.md`, `docs/perf.md`, `docs/codemap.md`, `docs/recipes.md` | **WS-6** (except `recipes.md` §10, which WS-1 adds) |

---

## 2. Shared invariants (paste into every brief)

- **Acceptance gate, every workstream, before claiming done:**
  ```bash
  cd /path/to/worktree/firmware && ~/.beacon-pio/bin/pio test -e native   # 0 failures
  cd /path/to/worktree/firmware && ~/.beacon-pio/bin/pio run   -e beacon  # SUCCESS
  cd /path/to/worktree/hub      && swift build && swift test              # 0 failures
  ```
  **Always pass `-e beacon`.** A bare `pio run` also builds `[env:native]`, which has no `main()` and
  reports `FAILED` — a red build that means nothing.
  **Current floors: hub 362 tests, firmware 257 tests.** Never go below them. Each workstream states
  its own new floor below; a workstream that adds tests but leaves the total unchanged has deleted
  coverage somewhere and must explain it.
- Run a single firmware suite with `~/.beacon-pio/bin/pio test -e native -f "*test_ota_hatch*"`.
- **A new non-header firmware `.cpp` that host tests link must be added to `build_src_filter` under
  `[env:native]` in `firmware/platformio.ini`,** or the suite fails with an undefined symbol. This is
  the single most common "new suite doesn't build" cause in this repo.
- Files listed in `build_src_filter` must be Arduino-free, or must fence their hardware half with
  `#if !BEACON_NATIVE` (`firmware/src/config/ticker_store.cpp:100` is the working precedent).
- **ASCII only** in firmware source and comments (`=>`, never the arrow glyph).
- **No secrets, ever** — this repo is public. No tokens in source, fixtures, logs, or commit messages.
- Hub: **no force-unwraps outside tests**; never log a command hint or a token.
- Commits are Conventional Commits with scope `firmware` / `hub` / `docs` / `ci`; branches
  `<type>/<kebab-summary>` (`CONTRIBUTING.md`). No linked issue is required in this fork.
- Docs reflect current state, not history — edit the statement, do not append a changelog.
- Do not create new top-level doc directories. Plans go in `docs/plans/`, specs in `docs/specs/`.
- `HUB_FRAME_MAX` is **1024 B** (`firmware/src/core/hub_proto.h:21`) and the device **silently drops**
  a longer frame. Every new frame below is budgeted against it in the design §6.2; do not exceed.

---

## 3. Phase 0 — prerequisites and shared substrate

**Sequential. Single owner. Nothing else starts until this is merged.**

### Goal

Land the two verified prerequisites that silently break OTA if missed, the complete BLE wire layer
(D1–D4, H1–H3) on both sides with tests and no behaviour, the seams that let the two hub workstreams
run in parallel without touching the same file, and the two hardware measurements the design could
not resolve without a schematic. Phase 0 has standalone value on its own: a "Device firmware
v0.12.10" row in Settings and a release workflow whose version string is finally correct.

### Files to touch

Hub:
- `hub/Info.plist` — add `NSLocalNetworkUsageDescription`.
- `hub/Sources/beacon-hub/SettingsPanel.swift` — a **Local Network** `StatusRow` in the existing
  **Connection** section (`SettingsPanel.swift:52-64`), beside Bluetooth and Device connected.
- `hub/Sources/beacon-hub/HubViewModel.swift` — `setupLocalNetwork: CheckState`, the
  `firmware: FirmwareUpdateState` published property, and the four closure seams below.
- `hub/Sources/beacon-hub/FirmwareSettingsView.swift` — **new**. A `FirmwareSettingsSection(model:)`
  view holding only the read-only **Device firmware** row for now. Model it on the existing
  `SonosSettingsSection` in `SonosSettingsView.swift`; adding it to `SettingsPanel` costs exactly one
  line, which is what keeps WS-4 out of `SettingsPanel.swift`.
- `hub/Sources/BeaconHubKit/FirmwareUpdateState.swift` — **new**, pure value type.
- `hub/Sources/BeaconHubKit/Protocol.swift` — `DeviceCommand` cases + the hub->device `ota` frame encoder.
- `hub/Sources/beacon-hub/AppDelegate.swift` — route the new `DeviceCommand` cases into
  `model.firmware`. Nothing else.
- `hub/Tests/BeaconHubKitTests/ProtocolTests.swift`, `hub/Tests/BeaconHubKitTests/FirmwareUpdateStateTests.swift` (**new**).
- `hub/CONTRACT.md` — new **§A3** (`ota` frame) and additions to **§B** (`ota_ack`, `ota_go`,
  `ota_stat`) and **§B3** (`report` `what:"device"`, including the `hatch` interlock).

Firmware:
- `firmware/src/core/records.h` — `ota_rec_t` + the frozen caps.
- `firmware/src/core/datastore.{h,cpp}` — `ds_set_ota()` / `ds_get_ota()`.
- `firmware/src/core/hub_proto.{h,cpp}` — `hub_build_device_report()`, `hub_parse_ota()`,
  `hub_build_ota_ack()`, `hub_build_ota_go()`, `hub_build_ota_stat()`.
- `firmware/src/core/hub_task.cpp` — emit D1 once per connection, beside `send_ticker_report()`.
- `firmware/test/test_ota_proto/test_main.cpp` — **new suite**.
- `firmware/platformio.ini` — nothing new needed (`hub_proto.cpp` and `datastore.cpp` are already in
  `build_src_filter`); confirm rather than assume.

CI:
- `.github/workflows/release-firmware.yml` — **one line only**, the `FIRMWARE_VERSION` fix.

### Files NOT to touch

`firmware/src/main.cpp` (WS-1 owns the `setup()` edit), anything named `ota_hatch*`, `ota_gate*`,
`ota.{h,cpp}`, `net_lan*`, `ota_overlay*`, `LanAssetServer.swift`, `FirmwareUpdateService.swift`,
`docs/tech.md`, `docs/codemap.md`, `docs/perf.md`, `docs/recipes.md`, and the complications-track
files listed at the top of this plan.

### What already exists vs what must be built

Exists:
- Two 3 MB OTA slots and `otadata` (`firmware/partitions.csv`) — **no repartition is needed and none
  may be done**; repartitioning wipes NVS (WiFi creds, tickers, pages, theme, brightness) on exactly
  the devices OTA exists to serve.
- `cmd:"report"` with `what:"tickers"`, emitted once per connection on the first inbound frame
  (`hub_task.cpp:150`, `s_reported` latch-only-on-success). D1 rides the same emission point.
- `DeviceCommand.parse` guards `(obj["what"] as? String) == "tickers"` and returns `nil` otherwise
  (`Protocol.swift:370`), so today's hub already drops a `what:"device"` report harmlessly.
- The Info.plist is embedded into the binary via a linker `__info_plist` section
  (`hub/Package.swift:28-35`) **and** copied into the bundle (`hub/build-app.sh:127`). Both paths read
  the same file, so one edit covers both — but verify the built `.app` actually carries the key.

Must be built: everything else in this section.

### P-1 — `NSLocalNetworkUsageDescription`

macOS 15+ gates local-network access behind TCC. Without the key the behaviour is a **silent
denial**: the device's LAN GET presents as a hang with no diagnostic on either end.

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Beacon Hub serves firmware updates to your Beacon device over your local network. The image
never leaves your network and no data is sent anywhere else.</string>
```

Add the Local Network row to the Settings **Connection** section, and **test the denied path, not
only the granted one** (§0.3, risk 4).

> **Settled 2026-07-27 (§9 item 6) — implement exactly this and do not go hunting for an API.** macOS
> exposes no public way to query Local Network TCC state, so the row cannot be a direct check like
> Bluetooth's. The row is **outcome-derived** — `.checking` until a LAN transfer has been attempted,
> `.ok` after any successful connection from the device, `.bad` after a connect that never produces
> a peer, with the fix button opening
> `x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork` (the same idiom
> `SettingsLinks.swift` already uses for Bluetooth). The evidence that drives it arrives for free once
> WS-2 lands the split `err` vocabulary (§9 item 11): `timeout` at 0% is the TCC-denial shape and
> `conn_refused` is the firewall shape, so the row does not need its own probe. Denied-path test:
> revoke Local Network for the hub in System Settings, run a transfer, and confirm the row goes `.bad`
> with actionable text rather than the transfer hanging.

### P-2 — the `FIRMWARE_VERSION` prefix mismatch

`.github/workflows/release-firmware.yml:25` sets `FIRMWARE_VERSION: ${{ github.ref_name }}`, which on
a tag push is `firmware-v0.1.0`, while the artifacts published in the same job are
`beacon-v0.1.0-app.bin` (line 31 strips the prefix separately). The device reports
`firmware-v0.1.0` and the release is `v0.1.0`. Comparing those two strings is how a permanent "you
are already up to date" — or a permanent update loop — gets born.

```yaml
env:
  FIRMWARE_VERSION: ${GITHUB_REF_NAME#firmware-}   # firmware-v0.1.0 => v0.1.0
```

**This must land before any version comparison exists anywhere.** `firmware/version.py` and
`firmware/src/config/version.h` need no change; they already fall back to `"dev"` for local builds.

### The wire layer (D1–D4, H1–H3)

Exactly the frames in design §6.1. Freeze these caps in `firmware/src/core/records.h`:

```c
#define OTA_VER_LEN     16   // `ver`/`fw` <= 15 B + NUL
#define OTA_SHA_HEX_LEN 65   // exactly 64 hex + NUL
#define OTA_URL_LEN     97   // <= 96 B + NUL
#define OTA_ERR_LEN     16   // <= 15 B + NUL
```

`ota_rec_t` in `records.h` carries only what the UI needs across cores — `phase`, `pct`, `rev`, `ver`,
`err`, `size`. The URL and the SHA-256 stay transient on the Core-0 fetch task and **never** enter the
DataStore (design §5.1).

> **The design does not say how progress crosses cores** — §5.1 calls the session struct transient,
> while §8 requires an LVGL overlay on Core 1 showing phase and percent. Every other cross-core value
> in this codebase moves as a DataStore snapshot ("never block the UI loop", `CLAUDE.md`). Phase 0
> resolves it by putting the display-facing fields in `ota_rec_t`, which is why the record is Phase 0
> work and not WS-2 work.

Wire notes that must be honoured:

- `hub_build_device_report()` must be **pure** (plain args in, bytes out) because `hub_proto.cpp` is
  in `build_src_filter` and compiles on the host. The caller in `hub_task.cpp` supplies
  `FIRMWARE_VERSION`, the running partition label, the other slot's size, the running image size, the
  STA IP, `hatch`, and `pend`.
- `hatch` and `pend` follow the repo's **emit-only-when-set** convention (like `qlen` and `stale`);
  absent means false. On the Swift side the property **must be `Optional` and `nil`, not `false`** —
  synthesized `Codable` omits `nil` but encodes `false` (`docs/recipes.md` §4 step 5).
- Phase 0 emits D1 **without** `hatch` — correct and honest, because Phase 0 firmware has no hatch.
  WS-1 flips it.
- Phase 0 lands the H1/H2/H3 **parser** and the D2/D3/D4 **builders** with tests, but **does not
  dispatch `ota` frames in `hub_task.cpp`'s `on_frame`**. A Phase 0 device that somehow receives one
  ignores it, which is right: the hub will never send one to a device with no `hatch`.
- **D4's `err` vocabulary is `{net, conn_refused, hash_mismatch, write, too_big, bad_image, timeout,
  aborted}`.** `conn_refused` is an addition to design §6.1 (settled, §9 item 11): it separates a
  rejected SYN — the macOS firewall shape — from `timeout`, which is connected-but-never-answered, the
  Local Network TCC shape. 12 B, inside the frozen 15 B `err` cap, additive within `"v":1`. Freeze the
  full list in `hub/CONTRACT.md` §B now, even though WS-2 is what emits them.
- Test the absent case for every optional field, and assert the built-frame bytes exactly — that is
  what `test_hub_proto` does and what makes this codec trustworthy.

### The hub seams (this is what makes wave C parallel-safe)

`hub/Sources/BeaconHubKit/FirmwareUpdateState.swift`, pure and host-testable:

```swift
public struct FirmwareUpdateState: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable { case released, localBuild }
    public struct LocalBuild: Equatable, Sendable { public var mtime: Date; public var bytes: Int }
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case available(version: String, bytes: Int)
        case transferring(step: String, pct: Int)   // `step` mirrors D4 `phase`
        case failed(reason: String)
    }
    public var deviceVersion: String?      // D1 `fw`
    public var deviceSlot: String?         // D1 `slot`
    public var deviceSlotBytes: Int?       // D1 `slotsz`
    public var deviceIP: String?           // D1 `ip`
    public var hasHatch: Bool = false      // D1 `hatch` -- false unless explicitly true
    public var pendingVerify: Bool = false // D1 `pend`
    public var source: Source = .released
    public var repo: String = "trever/beacon"
    public var phase: Phase = .idle
    public var lastCheck: Date?
    public var localBuild: LocalBuild?

    /// The §6.1 safety interlock. This is the ONLY place the rule lives.
    public var canOfferUpdate: Bool { hasHatch }
    public var blockedReason: String? {
        hasHatch ? nil
                 : "Update unavailable: this firmware predates the recovery hatch. "
                 + "Flash once over USB to enable updates."
    }
}
```

Note `LocalBuild` is a struct, not a tuple — a tuple property breaks synthesized `Equatable`.

`HubViewModel` gains, in Phase 0:

```swift
@Published var firmware = FirmwareUpdateState()
@Published var setupLocalNetwork: CheckState = .checking
var onFirmwareSourceChange: ((FirmwareUpdateState.Source) -> Void)?
var onFirmwareRepoChange:   ((String) -> Void)?
var onFirmwareCheckNow:     (() -> Void)?
var onFirmwareInstall:      (() -> Void)?
```

All four start `nil` and no-op. **WS-3 assigns them in `AppDelegate`; WS-4 calls them from the view.**
Neither workstream needs the other's file to compile. This surface is frozen by Phase 0 — a wave-C
workstream that wants to change it must say so rather than edit it unilaterally.

### The two hardware checks (§4.4.1) — the design could not resolve these without a schematic

Both are measurements on the real unit. Do them **in Phase 0**, before WS-1 writes a line of hatch
code, and paste the raw serial lines into the Phase 0 PR body.

**HC-1 — GPIO18 resting polarity. Zero code changes required.**

`buttons_begin()` already logs exactly what is needed (`firmware/src/hal/buttons.cpp:20-21`):

```
buttons: prev(gpio0)=1 next(gpio18)=1 (expect 1 = released)
```

Procedure:
```bash
cd firmware
~/.beacon-pio/bin/pio run -e beacon -t upload
~/.beacon-pio/bin/pio device monitor      # 115200; Ctrl-] to exit
```
1. Boot with **nothing held**. Record `next(gpio18)=?`.
2. Power off (hold PWR ~5-6 s), then power on (press PWR ~1 s) **while holding the user button**, and
   keep holding until the log line appears. Record `next(gpio18)=?`.

| Outcome | Meaning | Action |
|---|---|---|
| released `1`, held `0` | Active LOW as assumed; `INPUT_PULLUP` + `digitalRead()==LOW` is correct | WS-1 proceeds as designed |
| released `0` | The board idles GPIO18 LOW. **The hatch as designed would fire on every boot and ping-pong between slots** — recoverable only over USB (design §9) | **STOP. Do not ship the hatch.** Escalate to the owner. Do not "just invert it" unless step 2 reads `1`, which would mean an active-HIGH button |
| both reads identical | GPIO18 is not this unit's user button | **STOP.** Escalate |

Step 2 doubles as a rehearsal of the recovery gesture itself, so it is worth doing even if you are
confident about step 1. GPIO18 is not a strapping pin (GPIO0/3/45/46 are), so holding it through a
power cycle is safe.

**HC-2 — is GPIO18 readable before `power_begin()`?**

The hatch reads GPIO18 before the AXP2101 rails are configured. The button is a plain switch to
ground read through the ESP32's *internal* pull-up, so it should not depend on any AXP rail — but the
design is explicit that "should not" is not "measured".

Build a **throwaway instrumented image** in a scratch worktree (do not commit it). In
`firmware/src/main.cpp`, immediately after `enableLoopWDT();`:

```c
pinMode(18, INPUT_PULLUP);
delay(5);                                          // let the internal pull-up charge the pad
LOGI("hc2: pre-power gpio18=%d", digitalRead(18));
```

and immediately after the existing `delay(120);` that follows `power_begin()`:

```c
LOGI("hc2: post-power gpio18=%d", digitalRead(18));
```

Run **four** boots: two with the button released, two with it held from before power-on until both
lines print. Record all eight numbers.

| Outcome | Action |
|---|---|
| `pre == post` in all four runs | The hatch goes at the top of `setup()` exactly as design §4.4.2 specifies |
| `pre != post` in any run | The hatch moves to **immediately after `power_begin()`** (after its `delay(120)`), which costs only the AXP stage's coverage — still before display, LVGL, WiFi and BLE. Record the measurement and the reason in `docs/tech.md` §3 so it survives the next person who tidies `setup()` |

Two things that make this measurement trustworthy: the `delay(5)` after `pinMode` (without a settle
the first read can float, and you would misdiagnose a float as a polarity fault), and the fact that
the existing `LOGI("boot - core=%s", ...)` line prints before both probes — if you can see that line,
USB CDC has enumerated and neither probe's output is being eaten.

**Then discard the instrumented build and reflash `env:beacon`.**

### Acceptance gate

```bash
cd firmware && ~/.beacon-pio/bin/pio test -e native    # >= 271 cases (257 + >= 14 new), 0 failures
cd firmware && ~/.beacon-pio/bin/pio run   -e beacon   # SUCCESS
cd hub      && swift build && swift test               # >= 378 cases (362 + >= 16 new), 0 failures
```

Plus, non-automatable and required:
- HC-1 and HC-2 raw serial lines pasted into the PR body, with the outcome row named.
- The built `.app` carries `NSLocalNetworkUsageDescription`:
  `./build-app.sh release && plutil -p .build/Beacon\ Hub.app/Contents/Info.plist | grep LocalNetwork`
  (adjust the path to whatever `build-app.sh` emits).
- Settings shows a **Device firmware** row populated from a real device connection, and the Local
  Network row renders in both the granted and revoked states.
- `hub/CONTRACT.md` §A3/§B/§B3 written, and every field cap in it matches `records.h` byte for byte.

### Traps

- **The frame budget.** `HUB_FRAME_MAX` is 1024 B and a longer frame is dropped *silently*. Design
  §6.2 puts the worst cases at H2 247 B and D1 167 B, but assert them in the tests — build each frame
  with every field at its cap and assert `n < 1024`. That is the mistake that already bit `sessions`.
- **`report` chunk continuity.** D1 rides the same once-per-connection emission point as the ticker
  report but is **not** part of its chunk stream. Emit it as its own complete frame; do not fold it
  into `hub_report_plan`'s part numbering.
- **`s_reported` latches only on full success** (`hub_task.cpp:151`). Keep that discipline for D1 — a
  half-sent report must be retried on the next connection, not silently dropped.
- **Emit-only-when-set on the Swift side is an `Optional`, not a `false`.** Getting this wrong makes
  `hatch:false` appear on the wire, which reads as "the hub has an opinion about the hatch" and will
  confuse the interlock's test matrix.
- **`FIRMWARE_VERSION` is a shell expansion inside `env:`.** `${GITHUB_REF_NAME#firmware-}` is not
  GitHub Actions expression syntax; it is shell parameter expansion evaluated by the step's shell.
  Confirm it actually expands in the built artifact (the About panel's version string is the tell)
  rather than assuming — if it lands as a literal, use a `run:` step that writes to `$GITHUB_ENV`.
- Do **not** touch `LocalIngestServer.swift`. Its `requiredLocalEndpoint = 127.0.0.1:8765` binding and
  POST-only routing are security properties (design §2.1, §7).

### Rollback story

Phase 0 is four independent commits: the Info.plist/Settings change, the workflow one-liner, the wire
layer, and the seams. If any one fails QA, revert that commit alone. The wire layer is inert (nothing
dispatches `ota` frames yet) and the seams are `nil` closures, so reverting either is a no-op on
device behaviour. The `FIRMWARE_VERSION` fix is the one piece that must **not** be reverted in
isolation once a version comparison exists downstream.

---

## 4. WS-1 — the GPIO18 recovery hatch (Tier C)

**Sequential. Single owner. Runs after Phase 0 is merged, before anything in wave C. Must be flashed
and verified over USB, and must ship in a `firmware-v*` tag, before any OTA-delivered image exists.**

### Goal

Put the sole software recovery path onto the device: hold the user button (GPIO18) through a power
cycle and the device boots the other OTA slot. Make its correctness a first-class, host-tested
property, make its presence visible in every serial session, and make the `hatch:true` interlock real
so the hub can refuse to update a hatch-less device.

### Files to touch

- `firmware/src/core/ota_hatch.h` — **new**. The pure decision + the hardware entry point declaration.
- `firmware/src/core/ota_hatch.cpp` — **new**. Pure `ota_hatch_decide()` at file scope; the Arduino
  half fenced with `#if !BEACON_NATIVE` (precedent: `firmware/src/config/ticker_store.cpp:100`).
- `firmware/test/test_ota_hatch/test_main.cpp` — **new suite**.
- `firmware/platformio.ini` — add `+<core/ota_hatch.cpp>` to `[env:native]`'s `build_src_filter`.
- `firmware/src/main.cpp` — the `ota_hatch_check()` call site.
- `firmware/src/core/hub_task.cpp` — flip D1's `hatch` from absent to `ota_hatch_ran()`.
- `firmware/README.md` — the two recovery gestures, written for a human looking at a device that is
  not working.
- `docs/recipes.md` §10 — one bullet: do not move or remove `ota_hatch_check()` from the top of
  `setup()`, with the every-boot log line named as the tell.

### Files NOT to touch

Everything owned by Phase 0's wire layer beyond the single `hatch` argument. No `ota.{h,cpp}`, no
`ota_gate*`, no overlay, no hub files at all, no `docs/tech.md` (WS-6 adds the bring-up step 0).

### What already exists

- `PIN_BTN_NEXT 18` in `firmware/src/config/pins.h:21`, already driven `INPUT_PULLUP` and polled as
  `BTN_EVT_NEXT` by `hal/buttons.cpp` — the firmware already treats GPIO18 as a free, pulled-up input
  to ground.
- The repo's precedent for boot-critical pure logic: `core/button.h`'s `btn_poll`, `core/idle.cpp`,
  `ui/carousel_nav.h`. `ota_hatch_decide()` matches that pattern exactly.
- An existing boot escape hatch — **holding a finger on the glass** through boot forces the
  provisioning portal (`main.cpp:103-109`, 30 samples x 20 ms). **It is already taken. Do not overload
  it, do not merge the two.** They are independent gestures on independent hardware; a user reaching
  for network recovery must not get a firmware rollback.
- Every `halt:` path in `setup()` (`main.cpp:96,98,115,118`) `return`s before LVGL starts. That is why
  they all automatically fail WS-2's Tier A gate — and it is also why the hatch must run above all of
  them.

### What to build

**1. The pure decision (`ota_hatch_decide`).** Signature per design §4.4.4, adjusted for one problem
the design leaves open (see Traps): keep it about the **gesture only**.

```c
// Pure. No Arduino, no esp_ota. Host-tested in test_ota_hatch/.
#define OTA_HATCH_SAMPLES 75    // x 20 ms = 1.5 s
#define OTA_HATCH_MIN_LOW 68    // ~90% of samples must read LOW
bool ota_hatch_decide(int low_samples, int total);
```

Test table (minimum): exactly `OTA_HATCH_MIN_LOW` of `OTA_HATCH_SAMPLES` => true (boundary, inclusive);
one below => false; `0/75` => false; `75/75` => true; `total == 0` => false; `low > total` => false
(defensive); a short window (`68/68`) => decide on the ratio the caller passes, and assert whichever
semantic you choose is the one documented in the header. Aim for **>= 8 cases**.

**2. The hardware half**, fenced `#if !BEACON_NATIVE`:

```c
void ota_hatch_check(void);   // sample GPIO18, act, log -- called from the top of setup()
bool ota_hatch_ran(void);     // true once ota_hatch_check() has executed this boot
```

- `pinMode(PIN_BTN_NEXT, INPUT_PULLUP)`, `delay(5)` to let the pull-up charge, then 75 reads at 20 ms.
  `enableLoopWDT()` guards `loop()`, not `setup()`, so a 1.5 s blocking sample here is safe — the
  existing touch hatch already blocks 600 ms further down.
- If `ota_hatch_decide()` is true: `esp_ota_get_next_update_partition(NULL)`, then
  `esp_ota_set_boot_partition(other)`. **Check the return.** If it errors, log the error and continue
  booting normally — do not restart.
- On success: `LOGI` and `ESP.restart()`.
- **Log on every boot, pass or fail:**
  `ota: hatch gpio18 low=0/75 other=app1 -> no`. If a refactor drops the call, the missing line is the
  tell, and it is visible in every serial session anyone ever runs.
- `ota_hatch_ran()` returns a static bool set at the top of `ota_hatch_check()`.

**3. The call site**, per design §4.4.2 — or immediately after `power_begin()` + its `delay(120)` if
HC-2 said so:

```c
void setup() {
  Serial.begin(115200);
  delay(300);
  LOGI("boot - core=%s", ESP_ARDUINO_VERSION_STR);
  enableLoopWDT();

  ota_hatch_check();     // <== HERE. Before nvs_begin(), before power_begin(), before everything.

  nvs_begin();
  ...
```

What the hatch may depend on at that point and nothing else: `pinMode`/`digitalRead` on GPIO18, the
`esp_ota_*`/`esp_partition` API (live from the first line of `app_main`; **it does not need
`nvs_flash_init()`** — NVS is a different partition and `initArduino()` has already run it), `Serial`,
`millis()`/`delay()`. **Not** `Wire`, AXP2101, display, LVGL, our NVS layer, WiFi, BLE, RTC, touch, or
IMU. That property is what anyone editing `setup()` must preserve, and it is why `docs/recipes.md`
§10 gets a bullet about it.

**4. The interlock.** `hatch` in D1 is sourced from `ota_hatch_ran()`, **not** a hardcoded `true`.
That is strictly stronger than what the design asks for and costs nothing: `hatch:true` then means
"the hatch actually executed on this boot", not "somebody believes it is compiled in". A refactor that
deletes the call site turns the flag off automatically and the hub stops offering updates — which is
exactly the behaviour you want from a safety interlock.

### Acceptance gate

```bash
cd firmware && ~/.beacon-pio/bin/pio test -e native -f "*test_ota_hatch*"   # >= 8 cases, 0 failures
cd firmware && ~/.beacon-pio/bin/pio test -e native                          # >= 279 cases, 0 failures
cd firmware && ~/.beacon-pio/bin/pio run   -e beacon                         # SUCCESS
cd hub      && swift build && swift test                                     # >= 378, unchanged
```

On hardware, all four required:
1. `~/.beacon-pio/bin/pio run -e beacon -t upload` then monitor: **`ota: hatch ... -> no` appears on
   every normal boot**, above the `buttons:` line and above any `halt:` line.
2. The interlock, negative case: with the **Phase 0** firmware still on the device (no `hatch` in
   D1), the hub shows *"Update unavailable: this firmware predates the recovery hatch. Flash once over
   USB to enable updates."* and offers nothing. Capture this before flashing WS-1's build — it is the
   only free opportunity to see the interlock's blocked state in the wild.
3. The interlock, positive case: after flashing WS-1's build, the hub's Device firmware row loses the
   warning.
4. The gesture, on a device whose **other slot is not yet valid**: hold GPIO18 through a power cycle
   and confirm the log reads `-> yes` followed by a `set_boot_partition` error and a **normal boot**,
   not a restart loop. A fresh USB `merge_bin` flash only writes app0, so app1 is stale or erased and
   `esp_image_verify()` inside `esp_ota_set_boot_partition()` will correctly refuse it. **This is the
   expected result, not a bug** — and it is the cheapest possible proof that the failure path is safe.

Plus: `firmware/README.md` documents both gestures, and a `firmware-v*` tag carrying this build is
published before wave C starts.

### Traps

- **`esp_ota_get_state_partition()` is not a bootability check.** A slot flashed over USB reads
  `ESP_OTA_IMG_UNDEFINED` and is perfectly bootable. The only correct check is the return value of
  `esp_ota_set_boot_partition()`, which runs `esp_image_verify()` internally (segment table, checksum
  byte, appended SHA-256 — this tree's images have `hash_appended = 1` — and `chip_id`, which is 9 for
  ESP32-S3). Use the call as both the check and the action.
- **With rollback enabled, `esp_ota_set_boot_partition()` refuses a slot marked invalid/aborted**
  (`ESP_ERR_OTA_ROLLBACK_INVALID_STATE`). So after an automatic Tier A revert, a later hatch press
  cannot roll back *into* the image that was just reverted away from. That is correct and desirable —
  do not "fix" it.
- **The hatch's own correctness is the one remaining unrecoverable class** (design §4.4.3, §13). If it
  is present but wrong — wrong pin, inverted polarity, unreachable threshold, silently removed by a
  refactor — there is no second chance. That is the whole reason for the pure decision function, the
  test suite, and the every-boot log line.
- **Do not merge with the touch hatch** (see above).
- Adding `ota_hatch.cpp` to `build_src_filter` without fencing its Arduino half breaks every native
  suite at once, not just the new one.
- `ota_hatch.cpp`'s pure half must not `#include <Arduino.h>` at file scope — put the include inside
  the `#if !BEACON_NATIVE` block.

### Rollback story

One commit, one file pair plus a call site. Reverting it removes the call, the log line, and the
`hatch` flag — the hub immediately stops offering updates, which is the correct degraded state. The
only thing that cannot be reverted cheaply is a published `firmware-v*` tag; if the hatch build turns
out to be wrong after tagging, tag a fix rather than deleting the release.

---

## 5. Wave C — the parallel workstreams

All four start from the merged WS-1 tree. WS-2 is the only firmware workstream; WS-3/WS-4/WS-5 do not
touch `firmware/` at all except WS-3 reading (never writing) `firmware/.pio/build/beacon/firmware.bin`
as the local-build source.

---

### WS-2 — device OTA client

#### Goal

The device receives an `ota` go frame, streams the image over plain HTTP from the hub's LAN address,
verifies SHA-256 as it writes, installs into the inactive slot, reboots, and either marks itself valid
at 120 s or is automatically rolled back. Plus the overlay the user watches while it happens.

#### Files to touch

- `firmware/src/core/ota_gate.{h,cpp}` — **new**, pure Tier A decision.
- `firmware/src/core/ota_offer.{h,cpp}` — **new**, pure offer validation.
- `firmware/src/core/ota_rollback.cpp` — **new**, the `verifyRollbackLater()` override and the
  mark-valid call, deliberately in its own tiny file so it is greppable and hard to delete by accident.
- `firmware/src/core/net_lan.{h,cpp}` — **new**, `net_lan_get_stream()`: plain-HTTP streaming GET.
- `firmware/src/core/ota.{h,cpp}` — **new**, the session state machine on the Core-0 fetch task.
- `firmware/src/ui/ota_overlay.{h,cpp}` — **new**, the takeover card.
- `firmware/src/ui/overlays.h` — register the overlay with `ui_dismiss_top_overlay()`'s stack.
- `firmware/src/core/hub_task.cpp` — dispatch `ota` frames in `on_frame`, send D2/D3/D4.
- `firmware/src/core/fetch_task.cpp` — hand the OTA session a turn on the Core-0 loop.
- `firmware/src/ui/screens/views/settings_editorial.cpp` — the passive **FIRMWARE v0.12.10 > v0.13.0**
  row and its tap handler (design §8.1). Also the `NEW` chip on the settings dot in
  `firmware/src/ui/carousel.cpp` — see §10 open question 2, the part that disappears if the answer
  changes.
- `firmware/platformio.ini` — `build_src_filter` entries for `ota_gate.cpp` and `ota_offer.cpp`; and a
  new `[env:otaselftest]` (below).
- `firmware/test/test_ota_gate/test_main.cpp`, `firmware/test/test_ota_offer/test_main.cpp` — **new**.

#### Files NOT to touch

Anything under `hub/`. `firmware/src/core/net.cpp` (the LAN GET is a new file; `net_close_idle()` is
already exported in `net.h:42`). `firmware/src/core/ota_hatch.*` and `main.cpp` (WS-1's). Any doc under
`docs/` — WS-6 owns those.

#### What already exists

- **Bootloader rollback is already compiled into the pinned toolchain.**
  `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y` in
  `~/.platformio/packages/framework-arduinoespressif32-libs/esp32s3/sdkconfig:423`, mirrored into
  `qio_opi/include/sdkconfig.h:403` (this build's `board_build.arduino.memory_type` is `qio_opi`).
  `CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK` is **not** set. **No sdkconfig change, no custom bootloader,
  no unpinning.** Do not attempt any of those.
- The Arduino core already wires the app-side half in `initArduino()` (`cores/esp32/esp32-hal-misc.c`),
  and `verifyOta()` / `verifyRollbackLater()` are **weak symbols** a sketch overrides.
- `UpdateClass` (`libraries/Update/src/Updater.cpp`) with `begin/write/end/abort/canRollBack/rollBack`.
  `end()` runs its MD5 comparison *before* `_verifyEnd()`, and `_verifyEnd()` is the only thing that
  calls `esp_ota_set_boot_partition()`.
- `fetch_scratch()` — 8,192 B of internal `.bss` shared by every fetcher
  (`firmware/src/core/fetch_task.h:15`). **Reuse it as the OTA socket read buffer**; it costs zero
  additional internal bytes and the exclusion it implies (no other fetch during an OTA) is already
  structurally true, because the OTA runs on the same single-threaded fetch task behind the same mutex.
- `net_close_idle()` — call it at OTA start to drop the kept-alive `WiFiClientSecure` and free
  ~40-50 KB of internal heap before the writer needs it.
- `carousel_set_tick_paused(true)` (`docs/perf.md` §2, issue #60).
- `firmware/src/ui/pair_overlay.cpp` — a centered `lv_layer_top()` card with an eyebrow, a hero-font
  figure and a wrapped hint, serviced from the LVGL loop. **`ota_overlay.cpp` is that file with
  different content. Do not invent a new overlay mechanism.**

#### What to build

**The `verifyRollbackLater()` override — make this the first commit, and prove it.**

The default weak implementations are `verifyRollbackLater() == false` and `verifyOta() == true`, which
means the stock behaviour **marks a freshly-OTA'd app valid inside `initArduino()`, before `setup()`
has run a single line.** Rollback is nominally on and protects nothing. So:

```c
// firmware/src/core/ota_rollback.cpp
extern "C" bool verifyRollbackLater(void) { return true; }   // we mark valid ourselves, after Tier A
```

**`extern "C"` is load-bearing.** The weak defaults live in a C translation unit; a C++ definition
without `extern "C"` is a differently-mangled symbol, the weak default wins, and **everything appears
to work while rollback silently protects nothing.** This is a silent-failure class, so it does not get
a code review — it gets a measurement:

*How to prove the image really is in `PENDING_VERIFY` rather than assuming it.* At the top of
`setup()` (after the hatch), log the running partition's state:

```c
esp_ota_img_states_t st;
if (esp_ota_get_state_partition(esp_ota_get_running_partition(), &st) == ESP_OK)
  LOGI("ota: boot slot=%s state=%d", running->label, (int)st);
```

- After a **USB** flash the state reads `ESP_OTA_IMG_UNDEFINED`. That is normal; the gate is a no-op.
- After an **OTA** the first boot **must** read `ESP_OTA_IMG_PENDING_VERIFY`. If it reads
  `ESP_OTA_IMG_VALID` at t=0, the override did not take and rollback is off. **That single line is the
  acceptance evidence for this step.** Nothing else proves it.
- Log again immediately after `esp_ota_mark_app_valid_cancel_rollback()` and assert it now reads
  `ESP_OTA_IMG_VALID`.

**Tier A — the automatic health gate.** Pure, in `ota_gate.{h,cpp}`:

```c
#define OTA_GATE_MIN_UPTIME_S   120u
#define OTA_GATE_MIN_TICKS       20u
#define OTA_GATE_MIN_INT_FREE 40960u   // 40 KB, deliberately just below the observed 46,428 B floor
bool ota_gate_ok(bool first_render_done, uint32_t ticks, uint32_t min_int_free, uint32_t uptime_s);
```

All four conditions must hold: the first screen has rendered (`lv_scr_load` happened — this covers
every `halt:` path in `setup()` for free, because they all `return` before LVGL starts); the carousel's
500 ms tick has run **>= 20 times** (LVGL is alive, not merely initialised); the **since-boot minimum**
free internal heap is **>= 40 KB**; uptime is **>= 120 s**.

Use the **since-boot minimum**, not the instantaneous free heap. `hub_task` already tracks and logs
exactly this (`hub: conn=... int_free=... min=...`, `docs/perf.md` §5, `s_min_int_free` at
`hub_task.cpp:30`), so it is free. The instantaneous value would pass a build that dipped to 12 KB
during the boot TLS burst and is going to die on the next one.

**Every condition is device-local. The gate must never require WiFi or the hub** — a device carried to
a new network, or whose Mac is asleep, would otherwise roll back a perfectly good firmware forever.
Also rejected as gate conditions and not to be re-added: WiFi associated, hub link established, touch
controller ACKed on I2C.

*How to test a gate whose whole job is to not fire* — three layers, all required:

1. **Host tests** (`test_ota_gate`): each of the four conditions individually false => `false`; all
   true => `true`; each boundary exactly at the constant => `true` (assert inclusive `>=`); one unit
   below each boundary => `false`. That is 4 + 1 + 4 + 4 = **>= 13 cases**.
2. **Positive on-device proof it fired:** `LOGI("ota: marked valid up=%u min_int=%u ticks=%u")`
   immediately before the mark, plus the state re-read above. Absence of that line within ~130 s of an
   OTA boot is the failure signal, and it is visible in any serial session.
3. **Negative on-device proof it can fail:** the deliberate-bad-image rehearsal in §8 (BAD-A). A gate
   that has never been observed to *not* fire has never been tested.

**Offer validation** — pure, in `ota_offer.{h,cpp}`, returning the exact `err` vocabulary from design
§6.1: `too_big`, `same_ver`, `no_wifi`, `busy`, `malformed`, `no_slot`. Host-tested, **>= 8 cases**.

**The transfer.** On the existing Core-0 fetch task (it already owns the network, already serializes
behind the TLS mutex, and has an 8 KB stack; a dedicated OTA task would cost 3-4 KB of internal SRAM
for a stack we do not need).

- `net_close_idle()` first — drop the mbedtls context before anything else allocates.
- Plain `WiFiClient`, no TLS. `CONFIG_ESP_HTTPS_OTA_ALLOW_HTTP` is not set, so `esp_https_ota()` would
  refuse a `http://` URL outright — that is one of several reasons the design rejects it. **Use the
  Arduino `Update` library.**
- **Read and validate the HTTP status line and headers before calling `Update.begin()`** (§9 item 11).
  Require `200` and a `Content-Length` equal to the offered `size`. **Nothing is erased until the hub
  has demonstrably answered**, which is what makes a failed connection cost zero flash. This ordering
  is also the reason no separate reachability probe exists (§10, Q4 ruled) — the first connection *is*
  the probe, one round trip earlier than a dedicated one and with no extra token, no extra accepted
  connection against `LanAssetServer`'s cap of 3, and no second URL in H2.
- **Emit `ota_stat phase:"dl" pct:0` only after headers land.** A card stuck at 0% then unambiguously
  means "never got a response", which is a diagnosis rather than a symptom.
- **Split `err:"net"` into causes the user can act on** (§9 item 11): **`conn_refused`** (12 B, inside
  the 15 B cap; additive within `"v":1`) for a rejected SYN — the macOS firewall shape — and
  `timeout` for connected-but-never-answered, which is the Local Network TCC shape. Keep `net` for a
  mid-stream stall. The hub turns these into actionable text and they are also the evidence P-1's
  Local Network row needs (§9 item 6), so do not collapse them back into one.
- **Chunk size 4,096 B**, matching `SPI_FLASH_SEC_SIZE`. Feed `Update.write()` 4 KB at a time from
  offset 0 so each call exactly fills its sector buffer and triggers one flush — no straddling, no
  partial-sector rewrite. At 1,764,208 B that is **431 chunks** and, since `Update` erases in 64 KB
  blocks where aligned, **27 block erases**.
- Read into the first 4 KB of `fetch_scratch()`.
- Streaming `mbedtls_sha256` over the wire (hardware-accelerated —
  `CONFIG_MBEDTLS_HARDWARE_SHA=1`), compared against the digest delivered over the encrypted BLE link.
  On mismatch: `Update.abort()`, and **`Update.end()` is never called**, so
  `esp_ota_set_boot_partition()` never runs and the half-written slot is inert.
- **One `vTaskDelay(pdMS_TO_TICKS(1))` per 4 KB chunk.**
  `CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0=y` with a 5 s panic timeout — the same constraint that
  produced `read_body_bytes()`'s cooperative drain in `net.cpp` (#92). 431 ms added over the whole
  update, and IDLE0 is fed between every erase.
- **Do not suspend BLE** — it is the progress channel and the cancel channel, and tearing the link
  down risks the bond (CoreBluetooth cannot remove an OS-level bond). **Do not suspend LVGL** —
  instead `carousel_set_tick_paused(true)` for the duration.
- Deadlines: a **10 s per-read idle deadline** and an overall **180 s hard abort** on the whole
  transfer (settled, §9 item 7 — the design gave 180 s but named no per-read value). Both are named
  constants with a comment, never inline literals.
- Emit D4 `ota_stat` on phase change and on every whole percent, **rate-limited to 1 Hz**. The link
  carries a frame per ~30 s at rest; there is no reason to make an update the noisiest thing it ever
  does.

**The overlay** (design §8.2). Full-screen card inside the 40 px safe area: eyebrow `BEACON / UPDATE`,
a hero-font percent, a 320 x 6 px bar, `Installing v0.13.0`, `Keep the device powered`.

- Percent covers download (0-15%) and write (15-100%) on **one continuous scale** — a bar that resets
  to zero reads as a failure.
- **The bar and the percent update once per whole percent, and nothing animates.**
  `esp_partition_erase_range()` disables the flash cache while it runs, so Core 1 — whose *code* is in
  flash even though its draw buffer is in PSRAM — stalls for the duration of each erase, on the order
  of **100-300 ms per 64 KB block**. This is safe (`CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1` is not
  set, so Core 1 stalls do not trip the watchdog) but it is not something to pretend away: **no
  spinner, no animation.** A discrete step that freezes briefly reads as work; a tween reads as a hang.
- Swipe and shake-to-dismiss are disabled for the duration. A small `Cancel` affordance is live during
  the **download** phase only — once the first flash erase has happened, cancel is gone, because
  half-erasing the inactive slot and then stopping is strictly worse than finishing.
- Failure state: the same card, no bar, `UPDATE FAILED`, the honest short cause, and
  `Your device is unchanged.` — which is true, and is the single most useful sentence on the screen.
- **After the update: nothing.** No confirmation card, no "keep this version?", no post-update takeover
  of any kind (decision 2). The About panel's `VERSION` row is the only place the new version is
  asserted.

**`[env:otaselftest]`** — a measurement/verification env in the `env:capture` / `env:perf` /
`env:audiospike` tradition, so WS-2 can be accepted without waiting for WS-3 and WS-4:

```ini
[env:otaselftest]
extends = env:beacon
build_flags = ${env:beacon.build_flags}
  -DBEACON_OTA_SELFTEST=1
```

Behind that flag, a serial line `ota <url> <sha256hex>` runs the **exact same session code path** the
BLE go frame would. Serve the image with `python3 -m http.server` from
`firmware/.pio/build/beacon/`. This is how the throughput, `int_min` and UI-hitch numbers get measured
early. It is never shipped, exactly like `env:capture`.

#### Acceptance gate

```bash
cd firmware && ~/.beacon-pio/bin/pio test -e native -f "*test_ota_gate*"    # >= 13 cases
cd firmware && ~/.beacon-pio/bin/pio test -e native -f "*test_ota_offer*"   # >= 8 cases
cd firmware && ~/.beacon-pio/bin/pio test -e native                          # >= 300 cases, 0 failures
cd firmware && ~/.beacon-pio/bin/pio run   -e beacon                         # SUCCESS
cd hub      && swift build && swift test                                     # >= 378, unchanged
```

Plus, on hardware via `env:otaselftest`, all of which become the numbers WS-6 writes into `docs/perf.md`:
1. A full successful self-test install, with `ota: boot slot=… state=…` reading
   `ESP_OTA_IMG_PENDING_VERIFY` on the first boot afterward and `ota: marked valid …` at ~120 s.
2. `int_min` logged across the whole update. The design's memory argument (§5.1) is **an argument, not
   a measurement** and is ranked risk 2. Report the number.
3. Wall-clock duration (design estimates 30-60 s, dominated by erase+program, not the network).
4. Observed UI hitch length. If it is materially worse than 100-300 ms, say so — the progress UI may
   need to drop the percent entirely (design risk 5).
5. A deliberate hash mismatch (serve a truncated file): `ota_stat fail err:"hash_mismatch"`, the device
   still boots the old image, and `otadata` is untouched.
6. `firmware.bin` size reported and confirmed **< 3,145,728 B** (currently 1,764,208 B = 56.08%).
7. **The two connection failures, distinguished.** Point the self-test at a closed port =>
   `ota_stat fail err:"conn_refused"` within seconds, **zero flash erased** (the log must show no
   `Update.begin`). Point it at a socket that accepts and never answers (`nc -l` with no response) =>
   `err:"timeout"` at `pct:0`, again with nothing erased. These two are what make P-1's Local Network
   row diagnosable, so they are acceptance items, not nice-to-haves.

#### Traps

- **`extern "C"` on `verifyRollbackLater()`** — see above. This is the single highest-consequence
  silent failure in the workstream.
- **`Update`'s 4 KB sector buffer is pinned to internal DRAM.** `new uint8_t[SPI_FLASH_SEC_SIZE]`
  (`Updater.cpp:289`) plus `CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=4096` forces allocations of exactly
  4096 B internal. It cannot be moved to PSRAM without patching a pinned library. **Accept it** and
  count it in every future internal-heap budget that includes an OTA (design risk 7).
- **The heap floor is 46 KB, not 53 KB.** `CLAUDE.md`'s "~53 KB floor" is optimistic; `docs/perf.md`
  says 49,832 B; the design's brief observed **46,428 B**. Treat 46 KB as the worst case.
- **`Update.setMD5()` cannot be used as design §4.6 suggests** — settled, §9 item 4. Do not invent an
  `md5` wire field to make it work.
- **A PSRAM read buffer buys nothing here.** Bytes arrive in lwIP's internal pbufs regardless, so
  PSRAM gives no DMA advantage and adds a `heap_caps_malloc` failure path. Use `fetch_scratch()`.
- **Do not stage the image into the `spiffs` partition first.** It doubles write time and flash wear
  and buys nothing, because the full hash is verified before the inactive slot is ever made bootable.
- Time comes from `now_s()` (wall, for staleness) or `uptime_s()` (monotonic, for timeouts). Never a
  local `millis()` clock — that split-brains ages.
- `carousel_goto_buddy()` hardcodes index 3 (`carousel.cpp:160-164`) — if you touch the carousel for
  the `NEW` chip, do not disturb it.
- No object creation in a view's `update()`; build creates, update mutates.

#### Rollback story

Four separable commits: (a) `ota_rollback.cpp` + the state logging, (b) the pure gate + offer with
their suites, (c) the transfer + `net_lan` + `env:otaselftest`, (d) the overlay + settings row. If (d)
fails QA, revert it and the device still updates with no UI — bad, but not unsafe. If (c) fails,
revert (c) and (d); (a) and (b) are inert and worth keeping because (a) is what makes rollback real.
**Never revert (a) alone while (c) is live** — that combination re-enables the "marks itself valid
before `setup()`" behaviour, which is worse than having no OTA at all.

---

### WS-3 — hub `LanAssetServer`, release fetch, and transfer orchestration

#### Goal

The hub gets an image (from GitHub Releases or from the local `.pio` build), verifies it, serves it
over the LAN exactly once behind a single-use token, and drives the BLE offer/go/withdraw handshake —
refusing outright to offer anything to a device that did not report `hatch:true`.

#### Files to touch

- `hub/Sources/beacon-hub/LanAssetServer.swift` — **new**.
- `hub/Sources/BeaconHubKit/ReleaseSource.swift` — **new**, pure.
- `hub/Sources/beacon-hub/FirmwareUpdateService.swift` — **new**, the orchestrator.
- `hub/Sources/beacon-hub/LocalBuildSource.swift` — **new**.
- `hub/Sources/beacon-hub/AppDelegate.swift` — construct the service, assign the four `HubViewModel`
  closures Phase 0 declared, route `DeviceCommand.otaGo` / `.otaStat` / `.deviceReport`.
- `hub/Tests/BeaconHubKitTests/ReleaseSourceTests.swift` — **new**.
- `hub/Tests/beacon-hubTests/LanAssetServerTests.swift` — **new**.

#### Files NOT to touch

`hub/Sources/beacon-hub/LocalIngestServer.swift` (its 127.0.0.1 binding and POST-only routing are
security properties — see below), `SettingsPanel.swift`, `FirmwareSettingsView.swift`,
`HubViewModel.swift`, `MenubarController.swift` (all WS-4's), `hub/Sources/BeaconHubKit/Protocol.swift`
and `FirmwareUpdateState.swift` (Phase 0 froze them), anything under `firmware/` **except reading**
`firmware/.pio/build/beacon/firmware.bin`.

#### `LanAssetServer` is one component, shared with Sonos phase-2 album art

`docs/specs/2026-07-26-hub-as-controller-and-sonos-design.md` §3 already proposes exactly this shape
for album art: the hub fetches and downscales the art, serves it over the LAN, and the device fetches
it by URL. **OTA is the same mechanism with a bigger file, so there must be one LAN byte-serving
component, used by both.** Build it that way now; retrofitting later means two listeners on the user's
network.

Concretely, and this is an acceptance item, not a style note:

- **No OTA vocabulary anywhere in the type.** Not in the name, not in a parameter, not in a log line.
  It serves bytes.
- The API is payload-agnostic:
  ```swift
  func arm(_ data: Data, contentType: String, peer: IPv4Address,
           ttl: TimeInterval, maxServes: Int) -> URL     // http://<hubIP>:<port>/a/<32 hex>
  func disarm()
  ```
- **A test must arm it with a small non-firmware payload** (e.g. 2 KB of `image/jpeg`) and fetch it
  successfully. That test is the proof the component is general.
- A file-header comment naming both callers and pointing at the Sonos design §3.

The server's own rules (design §2.1, §7):

1. **A separate listener, not `LocalIngestServer`.** `LocalIngestServer` binds
   `requiredLocalEndpoint = 127.0.0.1:8765` and routes POST only (`LocalIngestServer.swift:45,154`);
   its whole job is receiving hook JSON from processes on the same Mac and its loopback binding is a
   security property worth keeping. Widening it would put an arbitrary-JSON POST parser on the user's
   network. **Never merge OTA serving into the hooks server.**
2. **GET only. One route shape: `/a/<32-hex token>`.** Anything else: 404, connection closed. No query
   parsing, no `Range`, no directory logic, no compression. Fixed `Content-Length`, `Connection:
   close` — reuse the same response-writer shape `LocalIngestServer` already has
   (`LocalIngestServer.swift:172-181`).
3. **Ephemeral port** (`NWEndpoint.Port.any`), **armed only for the duration of a transfer**, never at
   rest. Torn down on `done`, `fail`, first successful serve, or a **10 minute** window expiry —
   whichever is first.
4. **128-bit single-use path token** — 32 hex chars from `SecRandomCopyBytes`, compared in **constant
   time**, invalidated after the first complete response.
5. **Source-address restriction.** Accept only connections whose remote endpoint matches the device's
   IP as reported in D1; drop everything else before reading a byte. Additionally reject any remote
   address outside RFC1918 / link-local, so a misconfigured router cannot expose it to a WAN peer.
6. **Attempt cap: at most 3 accepted connections per armed window**, then disarm.
7. `NSProcessInfo.beginActivity(.userInitiated, .idleSystemSleepDisabled)` for the transfer window,
   released on completion or on the 10 min expiry — otherwise a sleeping Mac is indistinguishable from
   a WiFi drop.

**The device does not authenticate to the server, and that is deliberate.** It does not need to prove
its identity to fetch a public artifact — the same bytes are on GitHub Releases and served by the web
flasher over the open internet. The direction that matters is the reverse: the device must know the
bytes are the ones the hub meant, and that comes from the **SHA-256 delivered over the bonded,
LE-Secure-Connections-encrypted BLE link**, not from the HTTP hop. The path token is a capability, not
an authenticator. Do not add device auth.

#### Release fetch

`ReleaseSource.swift` is **pure** and holds every part that can be tested without a network:
`owner/repo` shape validation (never build a URL from unvalidated input), the `releases/latest` JSON
decode, `-app.bin` asset selection, `SHA256SUMS` parsing, and **semver comparison**. Tests must
include: `firmware-v0.13.0` vs `v0.13.0` (the P-2 class of bug — assert both normalize), `v0.13.0` vs
`v0.9.0` (numeric, not lexicographic), `dev` on either side (**`dev` is not a version** — a locally
built device is never offered a release), a release with no `-app.bin` asset, a 404, a rate-limit
body, and a `SHA256SUMS` whose digest does not match the downloaded bytes.

Networking side: unauthenticated `GET https://api.github.com/repos/<owner>/<repo>/releases/latest`
with an `ETag` conditional, downloaded via `URLSession` (system trust store; no CA management on our
side). Poll on hub launch and every 6 h — the unauthenticated GitHub API allows 60 requests/hour/IP and
this uses ~4/day.

`LocalBuildSource.swift` reads `firmware/.pio/build/beacon/firmware.bin` and reports its **mtime and
size**, so it is obvious what is about to be installed. **Not a watcher** — a hub that noticed every
`pio run` would nag, and a stale `.pio` directory silently installing over a real release is a bug
report waiting to happen.

#### The interlock, on the hub side

`FirmwareUpdateState.canOfferUpdate` (Phase 0) is the only place the rule lives.
`FirmwareUpdateService` must consult it before emitting **any** `ota` frame — offer, go, or withdraw.
Tests: a device report with `hatch` absent => no frame is emitted and `blockedReason` is non-nil; with
`hatch:true` => the offer path proceeds. This is what turns design §0.2's "Tier C ships first" into a
code-enforced invariant rather than a promise.

#### Acceptance gate

```bash
cd hub      && swift build && swift test    # >= 402 cases (378 + >= 24 new), 0 failures
cd firmware && ~/.beacon-pio/bin/pio test -e native && ~/.beacon-pio/bin/pio run -e beacon   # unchanged
```

Required test coverage, beyond raw count:
- `LanAssetServer`: correct token serves once and only once; wrong token 404s; a second GET with the
  correct token 404s; a connection from a non-matching peer is dropped; the 4th connection in a window
  is refused; the listener is gone after `disarm()`; a **non-firmware** payload round-trips.
- `ReleaseSource`: the semver / prefix / `dev` / missing-asset / bad-digest matrix above.
- `FirmwareUpdateService`: the `hatch` interlock in both directions; a `rev` that the device acks with
  `err:"too_big"` does not arm the server; hash mismatch does **not** auto-retry the same `rev` (it
  re-verifies the hub's own copy first and mints a new `rev` if the artifact was bad) — this avoids a
  retry loop that grinds flash against a corrupt artifact.
- **`err` => user-facing text**, one case per value in the frozen vocabulary. `conn_refused` must name
  the macOS firewall and `timeout` must name Local Network permission — those two strings are the
  whole payoff of §9 item 11, and a generic "network error" for either throws it away.

#### Traps

- **The URL host is the *hub's* LAN IP, not the device's.** Design §6.1's H2 example uses the same
  address for both `ip` in D1 and the URL in H2, which is a copy error in the doc. Settled, §9 item 5.
- **Picking the hub's own IP is genuinely ambiguous** on a Mac with Wi-Fi + Ethernet + a VPN `utun` +
  a Thunderbolt bridge. Choose the interface whose IPv4 subnet contains the device's reported `ip`; if
  none matches, fail the offer with a clear message rather than guessing. Settled, §9 item 5.
- **Use the IPv4 literal, not a `.local` hostname** — the device has no mDNS resolver wired and adding
  one to the update path is exactly the wrong dependency. The 96 B `url` cap was sized for a literal.
- **CA rotation must not land in the update path.** This is why the hub does the TLS: GitHub release
  assets 302-redirect to `objects.githubusercontent.com`, a different chain that can rotate
  independently, and the device's `net_https_get()` does not call `setFollowRedirects()`.
- **No pre-flight reachability probe. Ruled 2026-07-27 (§10) — this is closed, not a preference.** A
  hub->device probe tests the wrong direction: the hub serves and the device fetches, so a probe can
  go green while the real device->hub direction fails, and the most likely real failure is inbound to
  the Mac (firewall, Local Network TCC). A green pre-flight followed by a hung transfer is worse than
  none, because it moves suspicion away from the cause. Offer, arm, and let it fail with a specific
  error — WS-2 supplies `conn_refused` vs `timeout` so the message can name the likely cause.
- Log id + outcome only. Never a token, never a path token, never a command hint.

#### Rollback story

Three separable commits: `LanAssetServer` (+tests), `ReleaseSource` + `LocalBuildSource` (+tests), the
service + `AppDelegate` wiring. Reverting the wiring commit alone leaves two tested, unused components
and a hub that offers nothing — a clean degraded state, and the one to reach for if anything about the
LAN listener misbehaves in the field.

---

### WS-4 — hub Settings UI

#### Goal

Everything in design §10's **Settings > Firmware** section, plus however loud a failed update should
be, built entirely against the `HubViewModel` surface Phase 0 froze.

#### Files to touch

- `hub/Sources/beacon-hub/FirmwareSettingsView.swift` — extend Phase 0's section.
- `hub/Sources/beacon-hub/HubViewModel.swift` — any additional `@Published` the view needs.
- `hub/Sources/beacon-hub/SettingsPanel.swift` — at most the one line that inserts the section (Phase 0
  may already have added it; verify before editing).
- `hub/Sources/beacon-hub/MenubarController.swift` — the failed-update alert (§10 open question 3).
- `hub/Tests/beacon-hubTests/` — view-model-level tests for the row states.

#### Files NOT to touch

**`hub/Sources/beacon-hub/AppDelegate.swift` — WS-3 owns it.** Also `LanAssetServer.swift`,
`FirmwareUpdateService.swift`, `ReleaseSource.swift`, `Protocol.swift`, `FirmwareUpdateState.swift`,
and anything under `firmware/`.

#### What to build

Rows, per design §10:

- **Device firmware** — read-only, from D1: `v0.12.10`; or `v0.12.10 (verifying)` while `pend`; or
  `v0.12.10 - no recovery hatch, flash once over USB to enable updates` when `hatch` is absent. Phase 0
  landed the plain version; this adds the two qualified states. Render `blockedReason` verbatim — do
  not paraphrase it in a second place.
- **Update source** — **Released** (default) / **Local build**.
- **Repository** — text field, `owner/repo`, default `trever/beacon`, with a **Check now** button that
  reports what it found (`latest = v0.13.0, asset beacon-v0.13.0-app.bin, 1.77 MB`) or why it failed
  (404, rate limit, no `-app.bin` asset). Validate the shape client-side.
- **Check for updates automatically** — default **on**. **Checking only.**
- **Install** — a button. When the source is **Local build**, it is the **Install current build**
  button and shows the build's mtime and size.
- **There is no auto-install setting, and none will be added** (decision 3). An unattended flash of a
  desk device with no reset button is not a feature. Do not add one "for testing".
- Surface the hub version and the device firmware version **side by side** — `firmware-v*` and `hub-v*`
  ship independently and "why is my device not updating" has a hub version as a possible answer
  (design risk 6).

The transfer's progress belongs on the **device**, not the Mac. The hub shows state, not a second
progress bar.

#### Acceptance gate

```bash
cd hub      && swift build && swift test    # >= 410 cases (WS-3's floor + >= 8 new), 0 failures
cd firmware && ~/.beacon-pio/bin/pio test -e native && ~/.beacon-pio/bin/pio run -e beacon   # unchanged
```

Plus visual: screenshots of the Firmware section in all five states — no device, hatch-less device,
up to date, update available, transfer in progress, failed.

#### Traps

- `AppDelegate.swift` is not yours. If you need something it must provide, say so in the PR rather
  than reaching in — the whole point of the Phase 0 seam is that this workstream compiles without it.
- The Connection section already gained a Local Network row in Phase 0. Add the Firmware section; do
  not restructure Connection.
- Design §8.5: **after an update, nothing** on the device. If you find yourself building a "your device
  updated" toast on the Mac, check it against decision 2 first.

#### Rollback story

One commit, view layer only. Reverting it leaves the hub functional and headless (WS-3 still fetches
and serves; the device-side offer row still works). This is the cheapest revert in the plan and should
be the first thing cut if the wave runs long.

---

### WS-5 — `SHA256SUMS` in the release workflow

#### Goal

Publish a digest file alongside the release artifacts so the hub can verify GitHub served what CI
built, and a human can audit a release.

#### Files to touch

`.github/workflows/release-firmware.yml` — **only** the `firmware` job's "Assemble flashable images"
step, after the `cp "$BUILD/firmware.bin" "out/beacon-${VERSION}-app.bin"` line. Roughly three lines:
`cd out && shasum -a 256 beacon-*.bin > SHA256SUMS` (or `sha256sum`; pick one and be consistent), then
confirm the file lands in the uploaded artifact.

#### Files NOT to touch

Anything else in the workflow — **especially not the `FIRMWARE_VERSION` line, which Phase 0 already
fixed.** Branch from the post-WS-1 tree so you inherit that fix; if you see
`FIRMWARE_VERSION: ${{ github.ref_name }}` in your worktree, you branched too early — stop and rebase.
No hub or firmware sources.

#### Traps

- The `flasher` job does `rm -f site/firmware/*-app.bin` (line 86) before building the Pages site.
  `SHA256SUMS` would then reference a file the Pages site does not carry. Decide and comment: either
  keep `SHA256SUMS` out of the Pages artifact, or regenerate it there for the full image only. Do not
  leave a digest file next to a directory it no longer describes.
- Digests must be over the **exact published bytes**, generated after both images are final.
- `shasum -a 256` (BSD, on macOS) and `sha256sum` (GNU, on the `ubuntu-latest` runner) produce the same
  format; the runner is Linux, so `sha256sum` is the natural choice. The hub's parser must accept the
  standard `<64 hex><two spaces><filename>` form either way — that parser is WS-3's, and its test
  fixture must be a real file produced by this workflow, not a hand-typed one.

#### Acceptance gate

The workflow is not runnable locally. Acceptance is: `actionlint` (or a YAML parse) clean, the diff is
confined to the one step, and a dry review that the artifact upload glob `firmware/out/*` (line 47)
picks the new file up — it does, but confirm rather than assume. WS-6 verifies the real thing on the
next tag.

#### Rollback story

One commit, one file, three lines. Revert is trivial and costs only the hub's ability to cross-check
GitHub's bytes against CI's — the device's own SHA-256 check over BLE is unaffected.

---

## 6. WS-6 — convergence, docs, and the first real OTA

**Sequential. Runs after all of wave C is merged.**

### Goal

Prove the whole path end to end for the first time under the rehearsal procedure in §8, capture the
measurements the design deliberately left as estimates, and land every doc change design §14 implies —
in one place, so no two wave-C agents fought over `docs/codemap.md`.

### Files to touch

- `docs/tech.md` §3 — the validated bring-up sequence gains a **step 0: the OTA boot hatch runs before
  step 1 (`Wire.begin`)** and must stay there. **This is the single most important line to add**,
  because the bring-up order is exactly what future work will edit. If HC-2 forced the hatch below
  `power_begin()`, record that and the measurement that caused it.
- `docs/tech.md` §11 — the partition table now has a live consumer; record that `otadata` is
  authoritative and that a full USB flash resets it to `ota_0`.
- `docs/perf.md` §3 — the measured OTA internal-heap watermark, wall-clock duration, and UI hitch.
- `docs/codemap.md` — device->hub commands **4 => 7**; hub->device blocks gains `ota`; the new
  firmware/hub file rows; refreshed test counts.
- `docs/recipes.md` — a short §11 "ship a firmware release" covering the tag, the artifacts,
  `SHA256SUMS`, and the pre-tag hatch exercise. (§10's hatch bullet is WS-1's and should already exist.)
- `docs/plans/2026-07-27-ota-updates-plan.md` — this file: mark it done and record the measured
  numbers and the answers to the open questions.

### Acceptance gate

All three suites green at their WS-4 floors, `pio run -e beacon` SUCCESS, **and the full §8 rehearsal
completed with its serial log attached**, including BAD-A and BAD-B.

### Traps

- Do not let the rehearsal's measured numbers stay in a PR comment. `docs/perf.md` §3 is where the next
  person looks.
- Update `docs/codemap.md` §6 (known doc/code drift) if anything in this work contradicts a doc
  statement rather than fixing it.
- **Exercise the hatch before every future firmware tag.** Hold the button, confirm the rollback,
  confirm the device comes up on the other slot. It is a two-minute manual test and the design calls it
  the single highest-value test in the project. Put it in the release recipe.

---

## 7. What is deliberately not covered — say this in the PRs, not just here

- **A build that boots, ticks, keeps a healthy heap, and renders garbage.** Tier A marks it valid.
  Tier C is the only remaining answer, and after decision 2 there is nothing between them.
- **Downgrade attacks.** `CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK` is off and secure boot is off, so
  nothing prevents installing an older image. Out of scope by the same reasoning that defers signing.
- **A power-off inside the 120 s window** causes a spurious rollback on the next boot. Deliberate bias:
  it costs one update; a missed rollback costs a cable.
- **A corrupted `otadata`.** Recovery is the web flasher's full image, which rewrites `boot_app0.bin`
  at 0xe000 and re-selects `ota_0`.
- **Both slots holding bad images.** Tier C rolls back into the other slot; if that is also bad, the
  hatch on *that* image applies and rolls forward again. A ping-pong is visible in the serial log and
  terminates at USB.
- **The floor, and it belongs in `firmware/README.md` and in the release notes of the first OTA-capable
  firmware:** hold **BOOT (GPIO0)** through a power cycle to enter ROM download mode, then flash
  `beacon-v<ver>-full.bin` with the web flasher. It is the answer to every question that starts "what
  if".
- Signing is deferred but is **closer than it looks** — the pinned Arduino core ships
  `Updater_Signing.cpp` and `Update.installSignature()`, so the device-side work is a public key in
  flash and one call. Recorded so the next person does not re-scope it as a large project.

---

## 8. The first-OTA rehearsal

**This is the only sanctioned way to perform the first OTA.** It belongs to WS-6. Do not "just try it"
during WS-2 or WS-3 — the `env:otaselftest` path exists so nobody has to.

### Before starting — have all of this in hand

1. **A USB-C cable and a host that can run the web flasher or `esptool`.** The recovery floor is USB +
   the ROM loader on a board with no reset button; confirm you can reach it *before* you need it.
2. **A known-good full image saved outside the repo**, e.g.
   `~/beacon-recovery/beacon-v0.12.10-full.bin` — outside `firmware/.pio/` specifically, so a stray
   `pio run` cannot overwrite the thing you are relying on.
3. **The ROM-loader gesture rehearsed once**: hold BOOT (GPIO0) through a power cycle, confirm the port
   enumerates in download mode, then power-cycle back to normal. Two minutes now, versus discovering it
   does not work while holding a bricked device.
4. **HC-1 and HC-2 results** from Phase 0, with the outcome row named.
5. **A serial log to a file for the entire rehearsal.** The log *is* the evidence:
   `~/.beacon-pio/bin/pio device monitor | tee ~/beacon-recovery/rehearsal-$(date +%s).log`.
6. **A scratch git worktree** for the two deliberately-bad builds. They are one-line patches on top of
   the good build and **must never be committed to `main`** — record the patch text in the PR body.

### The procedure

**R0 — the interlock's blocked state (free, do it before anything else).**
With **Phase 0** firmware on the device (D1 reports no `hatch`), confirm the hub shows *"Update
unavailable: this firmware predates the recovery hatch. Flash once over USB to enable updates."* and
offers nothing. This is the only convenient chance to observe the interlock's refusal in the wild;
after WS-1 flashes, you would have to fake it.

**R1 — USB-flash the hatch build.**
`~/.beacon-pio/bin/pio run -e beacon -t upload`. Confirm on every boot: `ota: hatch gpio18 low=0/75
other=app1 -> no`, and `ota: boot slot=app0 state=…` reading `ESP_OTA_IMG_UNDEFINED` (normal after USB).
Confirm the hub's warning is gone.

**R2 — the first good OTA.**
Install the *same* good build via the hub (**Install current build**). It lands in `app1` and reboots
there. Confirm, in order:
- `ota_stat` phases on the hub: `dl` -> `verify` -> `boot`.
- First boot afterwards: `ota: boot slot=app1 state=` **`ESP_OTA_IMG_PENDING_VERIFY`**. If this reads
  VALID, `verifyRollbackLater()` did not take — **stop the rehearsal and fix it**; nothing below is
  meaningful without it.
- The hub shows `(verifying)` for ~120 s.
- `ota: marked valid up=… min_int=… ticks=…` at ~120 s, and the state re-read now says VALID.
- Record `int_min` across the whole update, the wall clock, and the observed UI hitch.

**Both slots now hold good, hatch-bearing images. That is the precondition for everything below.**

**R3 — the hatch, on a healthy device. Zero risk.**
Power off (hold PWR ~5-6 s), then power on (press PWR ~1 s) **while holding GPIO18**. Confirm
`ota: hatch gpio18 low=NN/75 other=app0 -> yes`, a restart, and a boot into `app0` with the expected
version. **Do this before either bad image.** It is the only test that proves the hatch works while
both escape routes are still intact, and it is what makes BAD-B's fallback something other than "hope".

Then OTA forward again so you are running the slot you want to overwrite next.

**R4 — BAD-A: "dies before the gate". Tests Tier A.**
One-line patch on the good build, downstream of the hatch and downstream of first render, so the hatch
and rollback machinery in the bad image are byte-identical to the shipping ones:

```c
// in loop(), for BAD-A only -- never committed
if (uptime_s() > 30) abort();
```

Install it over the inactive slot. Expected: it boots, renders, runs ~30 s, panics, and **the next boot
comes up on the previous slot** — one reboot, not a loop. That is the documented semantic with
`CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK` off: exactly one boot in `PENDING_VERIFY` that does not reach
mark-valid causes the next boot to revert.
*If it loops instead:* use the hatch (proven in R3). *If that fails:* USB.

**R5 — BAD-B: "boots, ticks, healthy heap, renders garbage". Tests Tier C.**
This is the class Tier A cannot see (design §4.5, risk 1) and the reason the hatch exists. One-line
patch, again downstream of everything safety-relevant — for example, after 10 s load an empty screen
while leaving the 500 ms carousel tick running:

```c
// BAD-B only -- never committed. Alive, ticking, healthy heap, useless screen.
if (uptime_s() > 10 && !s_blanked) { s_blanked = true; lv_scr_load(lv_obj_create(NULL)); }
```

Install it over the inactive slot. Expected, and this is the point:
- The device boots and renders (badly). The tick runs. The heap is fine.
- **Tier A marks it valid at 120 s** — `ota: marked valid …` appears. *This is the correct behaviour and
  the confirmation that the gate cannot see this class.* Do not treat it as a failure.
- Nothing else recovers it. Now perform the hatch gesture and confirm it boots the good slot.

*Fallback: USB + ROM loader.* Which is why R3 came first.

**R6 — clean up.**
OTA the good build back so **both** slots hold it again (two installs), confirm the version the hub
reports matches the version the About panel shows, and confirm `SHA256SUMS` verification passes against
a real release once WS-5's workflow has run on a tag.

### Why this order

Each bad-image test's fallback is a mechanism that has already been proven by an earlier step, and the
shared floor is USB:

| Step | Tests | Fallback if it goes wrong |
|---|---|---|
| R3 | the hatch | nothing needed — both slots are good |
| R4 | Tier A rollback | the hatch (proven at R3) |
| R5 | Tier C | USB + ROM loader (rehearsed at prep step 3) |

Running R5 before R3 would mean discovering a broken hatch while sitting on a device with a useless
screen. Running R4 before R2 would mean rolling back into an unverified slot.

---

## 9. Design gaps — resolved

These were the places the design was silent or self-contradictory. **All eleven are settled —
owner-confirmed 2026-07-27. Implement them exactly as written and do not reopen them.** They are
recorded here because the design doc still reads as though several are open. None of them changes the
shape of the design, and every one would otherwise have been invented independently by whichever
agent hit it first.

1. ~~**How OTA progress crosses cores.**~~ **Settled 2026-07-27.** §5.1 calls the session struct
   transient and says it is not in the DataStore; §8 requires an LVGL overlay on Core 1 showing phase
   and percent. Every other cross-core value in this codebase moves as a DataStore snapshot.
   **Resolution: `ota_rec_t` in `records.h` carries only the display-facing fields (`phase`, `pct`,
   `rev`, `ver`, `err`, `size`); the URL and the SHA-256 stay Core-0-local.** Landed by Phase 0 so
   WS-2 does not have to invent it.

2. ~~**How `hatch:true` is computed.**~~ **Settled 2026-07-27.** §6.1 says it means "this image
   contains the GPIO18 boot hatch" but never says how the D1 builder knows. A hardcoded `true` becomes
   a lie the moment someone deletes the call site — exactly the refactor §4.4.4 is worried about, and
   this is the one field the entire safety interlock rests on. **Resolution: derive it from
   `ota_hatch_ran()`, set by `ota_hatch_check()` itself, so the flag means "the hatch actually
   executed on this boot".** Strictly stronger than the design asks for, and it costs nothing.

3. ~~**`ota_hatch_decide()`'s third argument.**~~ **Settled 2026-07-27.** §4.4.4 gives
   `ota_hatch_decide(int low_samples, int total, bool other_slot_bootable)`, but **the third argument
   is not computable.** "Other slot bootable" can only be known by attempting
   `esp_ota_set_boot_partition()`, which *is* the destructive action, and
   `esp_ota_get_state_partition()` is not a substitute — a USB-flashed slot reads UNDEFINED and boots
   fine. Do not infer it. **Resolution: the pure function takes `(low_samples, total)` and decides the
   gesture only. The caller then calls `esp_ota_set_boot_partition(other)` and branches on its return
   value — success means restart, any error means log it and continue booting normally.** The call is
   both the bootability check and the action; there is no separate check and none should be added.

4. ~~**`Update.setMD5()` cannot be used as §4.6 describes.**~~ **Settled 2026-07-27.** `Update`
   computes the MD5 of what it wrote and compares it to a value the caller supplies — but no frame
   carries an MD5, and adding an `md5` field would contradict §6.2's frozen field set. **Resolution:
   drop `setMD5()` entirely.** Streaming SHA-256 plus IDF's `esp_image_verify()` inside
   `esp_ota_set_boot_partition()` (segment table, checksum byte, appended SHA-256, `chip_id`) is
   strictly stronger, and §4.6's gates 1 and 3 stand unchanged without it. Do not invent an `md5` wire
   field to make gate 2 work.

5. ~~**The `url` host in H2, and which interface supplies it.**~~ **Settled 2026-07-27.** §6.1's
   example shows `"url":"http://192.168.100.200:54321/a/…"` using the same address it gave for the
   *device's* `ip` in D1, so an agent copying the example builds a URL pointing at the device. The
   design also never says how the hub picks its own address when the Mac has Wi-Fi, Ethernet, a VPN
   `utun`, and a Thunderbolt bridge. **Resolution: the URL host is the hub's LAN IPv4 literal, chosen
   as the interface whose IPv4 subnet contains the device's reported `ip`; if no interface matches,
   fail the offer with a clear message rather than guessing.**

6. ~~**The Local Network TCC row has no API behind it.**~~ **Settled 2026-07-27.** P-1 requires a
   Settings row that shows the *denied* state, but macOS exposes no public way to query Local Network
   authorization. **Resolution: the row is outcome-derived** — `.checking` until a transfer has been
   attempted, `.ok` after a successful peer connection, `.bad` after a connect that never produces
   one — **with a deep link to
   `x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`.** Its evidence now
   arrives for free from item 11's split `err` vocabulary.

7. ~~**The per-read stall deadline for the LAN GET.**~~ **Settled 2026-07-27.** §5.4 gives a 180 s
   hard abort on the whole transfer, and §9 says a WiFi drop is caught by "the per-read deadline" but
   names no value; `net.cpp`'s `NET_BODY_DEADLINE_MS` is 8000 for an 8 KB body and is the wrong shape
   here. **Resolution: a 10 s per-read idle deadline plus the 180 s overall abort, both named
   constants with a comment, never inline literals.**

8. ~~**The `rev` lifecycle and stale offers.**~~ **Settled 2026-07-27.** H1/H2/H3 carry `rev` and
   D2/D3/D4 echo it, but nothing says where `rev` lives, what it starts at, or what the device does
   when it reconnects still holding an offer the hub has forgotten. **Resolution: `rev` is in-memory
   monotonic per hub process, starting at 1; the device clears any offer that is not already in flight
   when the link drops**, so a reconnect always re-derives from a fresh H1. That also makes H3
   (withdraw) purely an optimisation rather than load-bearing.

9. ~~**A local build always reports `fw:"dev"`.**~~ **Settled 2026-07-27.** §10 correctly says `dev`
   is not a version, but the consequence is that the hub cannot tell two local builds apart and
   **Install current build** will happily reinstall byte-identical firmware forever with no signal.
   **Resolution: the hub displays the SHA-256 prefix of the candidate and of the last thing it
   installed, so a no-op install is visible.** Cheap, and it makes the developer inner loop honest.

10. ~~**`SHA256SUMS` vs. the Pages job.**~~ **Settled 2026-07-27.** The `flasher` job deletes
    `*-app.bin` from the site directory (`release-firmware.yml:86`), which would leave a digest file
    describing files the site no longer carries. **Resolution: keep `SHA256SUMS` out of the Pages
    artifact** — and comment the reason in the workflow, so the next person does not "helpfully" copy
    it across.

11. ~~**When the device commits to the write, and what `err:"net"` actually means.**~~ **Settled
    2026-07-27, arising from the Q4 ruling (§10).** The design never says whether `Update.begin()`
    runs before or after the HTTP response headers are read, and it folds four distinct causes —
    connection refused, connection timeout, no response after connecting, and a mid-stream stall —
    into one `err:"net"`. Those have different remedies, and the first three are exactly the macOS
    firewall and Local Network TCC failures P-1 exists for. **Resolution, both halves in WS-2:**
    (a) **`Update.begin()` is not called until the status line and headers have been read and
    validated** (200, and `Content-Length` equal to the offered `size`), so nothing is erased until
    the hub has demonstrably answered, and `ota_stat phase:"dl" pct:0` is emitted only after headers
    land — a card stuck at 0% then unambiguously means "never got a response";
    (b) **`err` gains `conn_refused`** (12 B, well inside the 15 B cap; additive within `"v":1`) for a
    rejected SYN, while `timeout` covers "connected but never answered". The hub maps them to
    actionable text — `conn_refused` => check the macOS firewall; `timeout` at 0% => check Local
    Network permission for Beacon Hub — which is also the signal item 6's row needs.

---

## 10. Open questions carried from the design

Design §12 marks four questions **provisional, not yet confirmed by the user**. One is now ruled; the
other three are still fluid. **The split below is what a dispatched agent reads to learn what it may
still influence — anything in "Settled" is closed and must not be reopened.**

### Settled

**Q4 — should the hub refuse to offer when it cannot reach the device's reported `ip`?
Ruled NO, 2026-07-27. No pre-flight probe. Do not add one, and do not reopen this on
"but a probe would be nice" grounds.**

The design's reason was "let it fail honestly". The real reason is stronger, and it is why this is
closed rather than merely decided: **a hub->device probe tests the wrong direction.** The hub serves
and the device fetches, so the transfer is device->hub. Probing the device's reported IP from the Mac
exercises hub->device, which can succeed while the real direction fails — and the most likely real
failure is precisely inbound-to-the-Mac: the macOS firewall, or the Local Network TCC denial P-1
exists to handle. **A green pre-flight followed by a hung transfer is worse than no pre-flight,
because it moves suspicion away from the actual cause.** WS-3 therefore keeps its simpler flow shape:
offer, arm, fail honestly with a specific error.

**A device-side reachability probe was evaluated as the alternative and also rejected — see the
verdict below.** What replaces both is §9 item 11: headers-before-`Update.begin()`, plus a split
`err` vocabulary that names the firewall and TCC cases. That is in WS-2's brief.

*Why not a device-side probe (a tiny asset fetched from `LanAssetServer` before committing to the
1.8 MB image):* it tests the right direction, but it buys **no coverage the real transfer's own first
connection does not already buy one round trip later.** Every failure it would catch — refused SYN,
accepted-then-silent listener, TCC denial — surfaces at `connect()` or at the first header read,
which both happen before `Update.begin()` and therefore before a single flash sector is erased. And
it is not free: it would burn one of `LanAssetServer`'s **3 accepted connections** per armed window
(§7 rule 6), it would consume the **single-use path token** (§7 rule 4) and so require a second token
or a probe-exempt route — making the listener less dumb, when "deliberately dumb" is the security
property §7 is built on — and it would need a second URL in H2, which §6.2's frozen field set has no
room for (the same class of mistake as §9 item 4's `md5`). The narrow case a probe would catch and
the adopted version does not — headers fine, body stalls partway, for a firewall reason — is
theoretical: TCC and firewall blocks are connection-level, not byte-range-level, and a mid-stream
stall is a WiFi/sleep problem that §9 of the design already covers and that a tiny probe would not
have predicted either.

### Still open — answer before dispatching the named workstream

| # | Question | Provisional answer | What a different answer moves |
|---|---|---|---|
| 1 | Is 120 s the right Tier A window? | **Yes, 120 s** — raised from 60 s because decision 2 removed the cheap escape and made a missed rollback more expensive | **One constant** (`OTA_GATE_MIN_UPTIME_S` in `ota_gate.h`) and the boundary rows in `test_ota_gate`, both in **WS-2**. Zero structural impact. Do not push past ~2 minutes: extra time adds spurious-rollback exposure without catching new classes |
| 2 | Should the offer surface on the device at all, or only in the hub? | **Yes** — a Settings row plus a `NEW` chip on the settings dot | Drops the `settings_editorial.cpp` row, the `carousel.cpp` chip, and the device-initiated D3 `ota_go` from **WS-2** (~1 row + 1 chip). **The wire schema is unchanged either way**, so Phase 0 is safe regardless and D3 stays reserved. The takeover overlay is needed either way |
| 3 | How loud should a failed update be on the Mac? | **A menubar alert**, matching the existing "Beacon offline - CODEX not gated" pattern, cleared on the next successful check | One `HubViewModel` field and one `MenubarController` line in **WS-4**. The counter-argument is alert fatigue for a transient WiFi blip |

---

## 11. Rollback summary

| Workstream | Smallest revert | What the device does afterwards |
|---|---|---|
| Phase 0 | Any of its four commits independently | Wire layer is inert (nothing dispatches `ota`), seams are `nil` closures. **Do not revert the `FIRMWARE_VERSION` fix in isolation** once anything compares versions |
| WS-1 | One commit | No hatch, no `hatch` flag, hub stops offering updates — the correct degraded state. A published tag cannot be un-published; tag a fix instead |
| WS-2 | (d) overlay -> (c) transfer -> keep (a) rollback + (b) pure logic | **Never revert (a) `ota_rollback.cpp` alone while (c) is live** — that restores "marks itself valid before `setup()`", which is worse than no OTA |
| WS-3 | The `AppDelegate` wiring commit | Two tested, unused components; the hub offers nothing. Reach for this first if the LAN listener misbehaves |
| WS-4 | One commit, view layer only | Hub is functional and headless; the device-side offer row still works. Cheapest revert in the plan |
| WS-5 | One commit, three lines | The hub loses the CI cross-check; the device's own SHA-256 over BLE is unaffected |
| WS-6 | Docs only | No behaviour change |
