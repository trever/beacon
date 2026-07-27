# OTA firmware updates: the hub serves, the device installs

**Status:** design, not yet built. Written 2026-07-27. Revised 2026-07-27 after owner decisions
(§0.1).

The decision is already made and this document designs to it, not around it:

- **The hub serves the image over the LAN and triggers the install over the BLE link it already
  owns.** Not espota, not the device pulling from GitHub.
- **Rollback plus checksum verification in the first cut.** Not full signed images, not "minimal,
  just make it work".

Nothing found during the investigation makes that unworkable. Two facts make it *better* than
expected, and both are load-bearing below: the partition table already carries two 3 MB OTA slots, and
**bootloader rollback is already compiled into the pinned toolchain** (§4) — it needs no sdkconfig
change and no unpinning.

---

## 0. Decisions, and the one consequence that dominates this document

### 0.1 Settled by the owner (2026-07-27)

| # | Decision |
|---|---|
| 1 | **Release source is a Settings field**, defaulting to the user's fork `trever/beacon`. Not hardcoded to either fork. A self-updating firmware must not bake in an unchangeable repo choice. |
| 2 | **No "Keep / Roll back" confirmation card after an update.** Updates apply and rely on the automatic health gate. |
| 3 | **Never auto-install.** Every install requires a human tap. No overnight-idle install, no setting that enables one. |
| 4 | `SHA256SUMS` is added to `release-firmware.yml`. |
| 5 | The local-build source is an explicit **Install current build** button, not a watcher on the build directory. |

### 0.2 The consequence: the GPIO18 boot hatch is now the only software recovery path

Decision 2 removes the only mechanism that catches **"boots fine, passes every automatic check,
renders garbage"**. The automatic gate (Tier A, §4.3) can only see a device that fails to *reach* a
live UI. It cannot see a device that reaches one and shows nothing useful. Nothing else in the system
can either.

So the boot hatch (Tier C, §4.4) is no longer a nice-to-have backstop. **It is the sole recovery path
short of USB + the ROM loader, on a board that has no RST button** (`docs/tech.md` §2: buttons are
PWR, BOOT, user-IO18 — there is no reset). Everything below follows from that, and three
consequences are non-negotiable:

1. **The hatch must ship in a USB-flashed image before any OTA-delivered image can ever exist.** A
   hatch only helps if the *broken* image contains it. The first bad OTA onto a hatch-less device is
   unrecoverable without the ROM loader. This is enforced in code, not by discipline: the device
   advertises `hatch:true` in its report and **the hub refuses to offer an update to a device that
   does not** (§6.1, §11).
2. **The hatch must run as early in `setup()` as physically possible** — before AXP2101 rails, before
   the display, before LVGL, before WiFi and BLE — so that an image which dies in or after any of
   those stages is still escapable (§4.4.2).
3. **The hatch's own correctness is now a first-class risk.** If it is present but wrong, there is no
   second chance. It gets a pure host-tested decision function and a serial log line on every boot so
   its absence is visible (§4.4.4).

### 0.3 Prerequisites — blockers, not footnotes

Neither of these is OTA work per se, and neither is optional. Both must land before Phase 1.

**P-1. `hub/Info.plist` has no `NSLocalNetworkUsageDescription`.** macOS 15+ gates local-network
access behind TCC. Without the key the behaviour is a **silent denial**, and the device's LAN GET
presents as a hang with no diagnostic on either end. Add the key *and* a Local Network row to the
Settings **Connection** checks, beside the existing Bluetooth / device-connected checks, and test the
**denied** path, not only the granted one.

**P-2. `release-firmware.yml` bakes the full tag into `FIRMWARE_VERSION`.** The workflow sets
`FIRMWARE_VERSION: ${{ github.ref_name }}`, which on a tag push is `firmware-v0.1.0`, while the
artifacts it publishes in the same job are `beacon-v0.1.0-app.bin` (the shell strips the prefix
separately). The device therefore reports `firmware-v0.1.0` and the release is `v0.1.0`. Comparing
those two strings is how a permanent "you are already up to date" — or a permanent update loop — gets
born. Fix in the workflow: `FIRMWARE_VERSION: ${GITHUB_REF_NAME#firmware-}`. One line, and it must
land before any version comparison exists anywhere.

---

## 1. Verified ground truth

Everything in this section was checked against this tree and the installed toolchain on 2026-07-27.
Do not re-derive it; do re-measure the items marked *(estimate)*.

| Fact | Value | Where verified |
|---|---|---|
| OTA slots | `app0` @0x10000 and `app1` @0x310000, **0x300000 (3,145,728 B) each**, plus `otadata` @0xe000 | `firmware/partitions.csv` |
| Current app image | **1,764,208 B = 56.08%** of a slot | `firmware/.pio/build/beacon/firmware.bin` (2026-07-26 build) |
| Image header | magic `0xE9`, 6 segments, **`chip_id` = 9 (ESP32-S3)**, **`hash_appended` = 1** | header dump of the same file |
| Static internal RAM | 77,188 B / 327,680 | `docs/perf.md` header |
| Free internal heap | steady ~115 KB; **observed minimum 46,428 B**, during boot's TLS handshake burst | brief; `docs/perf.md` says 49,832 B since-boot min. `CLAUDE.md`'s "~53 KB floor" is optimistic — **treat 46 KB as the worst case** |
| PSRAM free | ~8.29 MB | `docs/perf.md` |
| `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE` | **`=y`** in the pinned prebuilt sdkconfig | `~/.platformio/packages/framework-arduinoespressif32-libs/esp32s3/sdkconfig:423` and `qio_opi/include/sdkconfig.h:403` |
| `CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK` | not set | same file, line 424 |
| `CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL` | **4096** — any allocation of 4096 B or less is forced into internal DRAM | `qio_opi/include/sdkconfig.h:1054` |
| `CONFIG_MBEDTLS_HARDWARE_SHA` | `=1` — SHA-256 is hardware-accelerated | `qio_opi/include/sdkconfig.h:1349` |
| Task WDT | `TIMEOUT_S=5`, `PANIC=y`, **`CHECK_IDLE_TASK_CPU0=y`, CPU1 not checked** | `sdkconfig:2318-2323` |
| `CONFIG_ESP_HTTPS_OTA_ALLOW_HTTP` | **not set** — `esp_https_ota()` refuses a `http://` URL | `sdkconfig:1992` |
| Release artifacts | `beacon-v<ver>-app.bin` (app-only, for OTA) is **already built and published** on every `firmware-v*` tag | `.github/workflows/release-firmware.yml` |
| Hub HTTP server | `LocalIngestServer` hard-binds `requiredLocalEndpoint = 127.0.0.1:8765` and routes **POST only** (a GET 404s) | `hub/Sources/beacon-hub/LocalIngestServer.swift:45,154` |
| Device firmware version on the wire | **does not exist today.** `FIRMWARE_VERSION` is used only by the About panel; `cmd:"report"` carries `what:"tickers"` and nothing else | `firmware/src/ui/about_panel.cpp:93`, `firmware/src/core/hub_report.cpp`, `Protocol.swift DeviceCommand` |
| BLE frame ceiling | `HUB_FRAME_MAX` **1024 B**; longer frames are silently dropped | `firmware/src/core/hub_proto.h:21` |
| Physical buttons | PWR (AXP-owned), **BOOT/GPIO0**, **user/GPIO18**. **No RST.** | `firmware/src/config/pins.h:20-21`, `docs/tech.md` §2, `docs/spikes/SETUP.md:68` |
| Every `halt:` path in `setup()` | `return`s without starting LVGL or the carousel tick | `firmware/src/main.cpp:95-118` — this is why they all automatically fail the Tier A gate (§4.3) |
| Existing boot escape hatch | holding a finger on the glass through boot (30 samples x 20 ms) forces the provisioning portal | `firmware/src/main.cpp:103-109` — **already taken; do not overload it** |
| Flash write throughput | *(estimate)* 30–60 s wall clock for 1.77 MB, dominated by erase+program, not the network | measure in Phase 1 |

**No repartition is needed.** That is not a convenience, it is the premise: repartitioning wipes NVS
(WiFi credentials, tickers, page config, theme, brightness) and forces a USB reflash of exactly the
devices OTA exists to serve.

---

## 2. Which side does TLS

**Recommendation: the hub fetches the release over TLS; the device does a plain-HTTP LAN GET plus a
SHA-256 check.** This is the two-plane pattern applied unchanged — the Mac does the
credential-bearing, internet-facing, CA-validating work and hands the device something dumb.

The alternative (device fetches the release from GitHub over TLS itself) was evaluated seriously and
rejected on four independent grounds, any one of which is sufficient:

1. **Memory.** `net.cpp`'s own comment records the cost: *"a ~40-50KB mbedtls handshake"* per fresh
   `WiFiClientSecure`. Against an observed 46 KB internal-heap floor, standing up a TLS context
   *while* the flash writer holds its own buffer is not affordable. A plain `WiFiClient` on the LAN
   costs a few KB of lwIP socket state. This is the difference between ~5 KB and ~50 KB of internal
   SRAM at the single worst moment in the device's life.
2. **CA rotation lands in the update path.** `config/root_ca.h` bundles five roots chosen for
   Open-Meteo / ipwho.is / Binance / Yahoo / BigDataCloud. GitHub release assets 302-redirect to
   `objects.githubusercontent.com`, which is a different chain that can rotate independently, and
   `net_https_get()` does not call `setFollowRedirects()` today. That would make the *update
   mechanism itself* the thing that breaks when a CA rotates — with no way to ship a fix except USB.
3. **`net_https_get()` cannot do this.** It buffers the whole body into a caller buffer (today the
   8 KB `fetch_scratch()`), and its `NET_BODY_DEADLINE_MS` is 8000. A 1.77 MB streaming download needs
   a different function whichever transport it uses; the plain-HTTP version of that function is
   materially smaller and has no handshake timeout interacting with the 5 s task WDT.
4. **Release logic stays where releases are understood.** Semver comparison, "is there a newer tag",
   which repo to poll, and asset selection are hub concerns with a UI attached. Putting them on the
   device means a firmware change to fix a release-discipline bug — which, for a self-updating
   firmware, is exactly backwards. Decision 1 (the repo is a Settings field) makes this concrete.

**Rejected alternatives, named:**

- **`esp_https_ota()`** — `CONFIG_ESP_HTTPS_OTA_ALLOW_HTTP` is not set in the pinned sdkconfig, so it
  will reject `http://` outright. It is also the wrong shape (it owns the whole loop, including the
  reboot). We use the Arduino `Update` library, which has no such restriction.
- **HTTPS on the LAN with a self-signed cert pinned by SPKI hash over BLE** — pays the 40–50 KB
  mbedtls bill to protect a binary that is public on GitHub Releases and served by the web flasher
  over the open internet. The SHA-256 delivered over the bonded, LE-Secure-Connections-encrypted BLE
  link already gives integrity, which is the property that actually matters. Confidentiality here is
  worth nothing.
- **espota / `ArduinoOTA`** — requires a permanently listening service on the device (memory +
  attack surface), has no trigger channel or UX, and its integrity check is MD5.
- **Staging the image into the ~10 MB `spiffs` partition first, then flashing** — doubles write time
  and flash wear and buys nothing, because we already verify the full hash before the inactive slot
  is ever made bootable (§4.6).

### 2.1 Reuse the Sonos LAN-serving mechanism; do not invent a second one

`docs/specs/2026-07-26-hub-as-controller-and-sonos-design.md` §3 already proposes exactly this shape
for album art: *the hub fetches and downscales the art, then serves it over the LAN, and the device
fetches it by URL.* OTA is the same mechanism with a bigger file, so there must be **one** LAN
byte-serving component, used by both.

That component is **not** `LocalIngestServer`. `LocalIngestServer` binds
`requiredLocalEndpoint = 127.0.0.1:8765` and routes POST only; its whole job is receiving hook JSON
from processes on the same Mac and its loopback binding is a security property worth keeping. Widening
it to the LAN would put an arbitrary-JSON POST parser on the user's network.

Introduce **`LanAssetServer`** instead — a second, deliberately dumb `NWListener`:

- GET only. One route shape: `/a/<32-hex token>`. Anything else: 404, connection closed.
- No query parsing, no `Range`, no directory logic, no compression. Fixed `Content-Length`,
  `Connection: close` — the same response writer `LocalIngestServer` already has.
- Ephemeral port (`NWEndpoint.Port.any`), **armed only for the duration of a transfer**, never at rest.
- Serves from an in-memory `Data` the hub has already fetched and hashed.

Album art (Sonos phase 2) becomes a second caller of `LanAssetServer` with a smaller payload. Nothing
about the OTA design is art-specific.

---

## 3. Where the hub gets the image

Two sources ship, selected by an explicit Settings picker. One is rejected.

**(a) GitHub Releases — the default.** `release-firmware.yml` already publishes
`beacon-v<ver>-app.bin` on every `firmware-v*` tag, which is precisely an OTA image (app-only,
`0x10000`-relative). The hub does an unauthenticated `GET
https://api.github.com/repos/<owner>/<repo>/releases/latest` with an `ETag` conditional, reads the tag
name and the `-app.bin` asset URL, and downloads via `URLSession` (system trust store; no CA
management on our side).

**The repo is a Settings field, not a constant** (decision 1). Default `trever/beacon`; the user can
point it at `angaziz/beacon` or any fork. An `owner/repo` text field with a **Check now** button that
reports what it found (`latest = v0.13.0, asset beacon-v0.13.0-app.bin, 1.77 MB`) or why it failed
(404, rate limit, no `-app.bin` asset). Validate the shape client-side; never build a URL from
unvalidated input.

**Digest.** Per decision 4, add a `SHA256SUMS` file to the `firmware` job's `out/` — three lines of
workflow. Without it, the hash the device checks only proves the Mac-to-device hop; with it, the hub
can verify GitHub served what CI built, and a human can audit a release.

**(b) A local build — the developer path, and the reason Phase 1 is worth shipping alone.** An
explicit **Install current build** button (decision 5) pointed at
`firmware/.pio/build/beacon/firmware.bin`, showing its mtime and size so it is obvious what is about
to be installed. Not a watcher: a hub that noticed every `pio run` would nag, and a stale `.pio`
directory silently installing over a real release is a bug report waiting to happen. The user is
actively reflashing over USB while building other features; this removes the cable from the inner
loop on day one, before any release plumbing exists.

**(c) Bundled inside the app bundle — rejected.** `hub-v*` and `firmware-v*` are independent tags with
independent workflows (`release-hub.yml` / `release-firmware.yml`); bundling couples them, adds 1.8 MB
to a notarized bundle, and guarantees that every hub update ships a firmware that is stale the moment a
firmware tag lands.

---

## 4. Rollback and recovery

> **On the missing tier.** The tiers are **A** and **C**. There is no Tier B: it was the post-update
> "Keep / Roll back" confirmation card, removed by decision 2 (§0.1). The lettering gap is kept
> deliberately so that anyone reading this later sees that a middle layer once existed and was
> consciously dropped — the consequence of dropping it is §0.2 and risk 1 (§13), not an editing slip.

### 4.1 Bootloader rollback is achievable under the pinned toolchain — evidence

This was the biggest open risk in the brief, and the answer is better than feared.

**The pinned Arduino-ESP32 3.3.5 libraries are already built with rollback enabled.** From
`~/.platformio/packages/framework-arduinoespressif32-libs/esp32s3/sdkconfig`:

```
423: CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y
424: # CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK is not set
```

and mirrored into the header the sketch actually compiles against,
`esp32s3/qio_opi/include/sdkconfig.h` (`qio_opi` is this build's `board_build.arduino.memory_type`):

```
403:  #define CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE 1
1848: #define CONFIG_APP_ROLLBACK_ENABLE CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE
```

This matters on both sides of the fence:

- **App side.** `libapp_update.a` is compiled with the flag, so `esp_ota_set_boot_partition()` writes
  the new slot in state `ESP_OTA_IMG_NEW`/`PENDING_VERIFY` rather than plain `VALID`.
- **Bootloader side.** The bootloader is prebuilt in the same package (`esp32s3/bin/bootloader_qio_80m.elf`,
  converted to the 20,224 B `bootloader.bin` in this tree's build output) from that same sdkconfig, so
  it contains the pending-verify check. We are not asking the bootloader to do anything it was not
  built to do.

**And the Arduino core already wires the app-side half.** `cores/esp32/esp32-hal-misc.c`, compiled
from source by PlatformIO, contains in `initArduino()`:

```c
#ifdef CONFIG_APP_ROLLBACK_ENABLE
  if (!verifyRollbackLater()) {
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t ota_state;
    if (esp_ota_get_state_partition(running, &ota_state) == ESP_OK) {
      if (ota_state == ESP_OTA_IMG_PENDING_VERIFY) {
        if (verifyOta()) {
          esp_ota_mark_app_valid_cancel_rollback();
        } else {
          esp_ota_mark_app_invalid_rollback_and_reboot();
        }
      }
    }
  }
#endif
```

`verifyOta()` and `verifyRollbackLater()` are **weak symbols** (same file, ~line 237) that a sketch
overrides. `UpdateClass` also exposes `canRollBack()` / `rollBack()`
(`libraries/Update/src/Updater.cpp:141-150`).

**Conclusion: bootloader rollback requires no sdkconfig change, no custom bootloader, and no
unpinning. It requires roughly thirty lines of firmware.**

### 4.2 The trap

The default weak implementations are `verifyRollbackLater() == false` and `verifyOta() == true`, which
means **the stock behaviour marks a freshly-OTA'd app valid inside `initArduino()`, before `setup()`
has run a single line.** Rollback is nominally on and protects nothing.

So the firmware **must** override:

```c
bool verifyRollbackLater() { return true; }   // we mark valid ourselves, after a health gate
```

and then own `esp_ota_mark_app_valid_cancel_rollback()` explicitly.

### 4.3 Tier A — the automatic health gate

Mark the running app valid when **all** of:

| Condition | Rationale |
|---|---|
| The first screen has rendered (`lv_scr_load` happened) | covers every `halt:` path in `setup()` for free — they all `return` before LVGL starts |
| The carousel's 500 ms tick has run **>= 20 times** | LVGL is *alive*, not merely initialised |
| **Since-boot minimum** free internal heap **>= 40 KB** | see below |
| Uptime **>= 120 s** | see §4.3.1 |

Every condition is device-local. **The gate must never require WiFi or the hub** — a device carried to
a new network, or whose Mac is asleep, would otherwise roll back a perfectly good firmware forever.

**Use the since-boot minimum, not the instantaneous free heap.** `hub_task` already tracks and logs
exactly this (`hub: conn=… int_free=… min=…`, `docs/perf.md` §5), so it is free. The instantaneous
value would pass a build that dipped to 12 KB during the boot TLS burst and is going to die on the
next one; the running minimum converts "leaks or over-allocates and will die soon" from an
unrecoverable class into an automatically-reverted one. 40 KB sits deliberately just below the
observed 46,428 B worst case — the gate should fire on a build that is *worse than today*, not on
today.

**Considered and rejected as gate conditions:**

- *WiFi associated* — a device moved to a new network would roll back forever. Never.
- *Hub link established* — same, but worse: it makes firmware health depend on a Mac being awake.
- *Touch controller ACKed on I2C* — a genuinely useful signal (a dead-touch build is unescapable by
  touch), but `touch_begin()` does not report success in a form the gate can read, and adding a
  hardware dependency to the gate risks the same lockout class as requiring WiFi. Revisit only with a
  measured failure to justify it. Note the boot hatch is a **button**, not touch, so a dead-touch
  build is still escapable.

With `CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK` off, the bootloader semantics are that **exactly one** boot
in `PENDING_VERIFY` that does not reach mark-valid causes the *next* boot to revert to the other slot.
A crash loop reverts on the second boot; it does not loop forever.

#### 4.3.1 Why the window went from 60 s to 120 s

The original design said 60 s, and biased long on the grounds that a spurious rollback costs one
update while a missed rollback costs a USB cable. **Removing the confirmation card (decision 2) makes
that argument strictly stronger, so the bias should get stronger too. Final answer: 120 s.**

The reasoning, explicitly:

- The **cost of a missed rollback went up**. It used to be "tap Roll back on the card". It is now
  "find the boot hatch, or plug in USB and hold BOOT through a power cycle on a board with no reset
  button".
- The **cost of a spurious rollback did not change**. It is still one update: the previous firmware
  runs, the hub sees the old version in the next report, and re-offers.
- **A longer window catches later crashes, which is where the known hazard is.** The observed
  46,428 B internal-heap minimum happens during *boot's TLS handshake burst* — not at t=2 s. A window
  must comfortably span: boot to first render (<4 s), the first `WiFiMulti.run(6000)` join *including*
  one 5 s backoff retry, NTP on `GOT_IP`, the first TLS handshake burst, and a first BLE connect plus
  the full status frame and ticker report. 60 s is tight for that chain; 120 s is not.
- **The spurious-rollback scenario is unlikely in practice.** The user just tapped Update, watched a
  30–60 s progress card, and saw the device reboot. A power-off inside the next two minutes means they
  are standing there watching it — which is precisely the case where they *want* the previous
  firmware back.

The window does not buy new *classes* of coverage, only more *time* for the classes Tier A already
covers. That is the honest framing, and it is why the answer is 120 s and not 600 s: past a couple of
minutes, additional time adds spurious-rollback exposure without catching anything new.

### 4.4 Tier C — the GPIO18 boot hatch, now the sole software recovery path

**Gesture:** hold the **user button (GPIO18)** through a power cycle. On this board that means: hold
PWR ~5–6 s to power off, then press PWR ~1 s to power on **while holding GPIO18** — there is no RST
button, so a power cycle is the only reset. This is comparable in awkwardness to the ROM-loader
gesture (hold BOOT through a power cycle), which is the fallback below it.

**Behaviour:** if GPIO18 is held for a sustained window at the very top of `setup()`, and
`esp_ota_get_next_update_partition()` is bootable, set it as the boot partition and `ESP.restart()`.
Log loudly either way.

#### 4.4.1 GPIO18 is genuinely free — evidence, and the one check still owed

| Check | Result |
|---|---|
| Board documentation | `docs/research/2026-06-05-device-and-integrations-research.md:49` — *"Buttons: PWR (active-HIGH via inverter, through AXP2101), BOOT, user button GPIO18"*. Corroborated by `docs/spikes/SETUP.md:68` and `docs/spikes/display-power/README.md:22`. |
| In-repo pin conflicts | **None.** Enumerating every numeric `#define` in `firmware/src/config/pins.h`: `0, 2, 4, 5, 6, 7, 8, 9, 11, 12, 14, 15, 18, 38, 42, 45, 46`. **18 appears exactly once.** Display QSPI is 4/5/6/7/38 + RST 2 + CS 12; I2C (AXP2101 + touch + IMU + RTC all share it) is 15/14; touch INT is 11; audio is 42/9/45/8/46. None of them is 18. |
| ESP32-S3 strapping pins | GPIO0, GPIO3, GPIO45, GPIO46. **18 is not a strapping pin** — unlike GPIO0, which is exactly why BOOT cannot be used for this. |
| ESP32-S3 USB-Serial/JTAG | GPIO19 (D-) / GPIO20 (D+). This build sets `ARDUINO_USB_CDC_ON_BOOT=1`, so 19/20 are committed. **18 is not.** |
| ESP32-S3 SPI flash / PSRAM | SPI0/1 flash occupies GPIO26–32; **octal** PSRAM (`memory_type = qio_opi`) adds GPIO33–37. **18 is outside both ranges** — which matters, because an OPI-PSRAM board has far fewer free pins than a quad one. |
| Existing firmware use | `hal/buttons.cpp` already drives it `INPUT_PULLUP` and polls it as `BTN_EVT_NEXT`. The firmware already treats it as a free, pulled-up input to ground. |

**Owed check, and it must happen in Phase 0 on real hardware.** I verified GPIO18 against this repo's
pin map and against the ESP32-S3's reserved and strapping pins. I did **not** have the Waveshare
schematic. Two things must be confirmed on the unit before the hatch ships:

1. **Resting polarity.** `buttons_begin()` already logs it: `buttons: prev(gpio0)=1 next(gpio18)=1
   (expect 1 = released)`. Confirm `next(gpio18)=1` at rest and `0` while held. If a board revision
   idles GPIO18 LOW, the hatch would fire on *every* boot and the device would ping-pong between
   slots — recoverable only over USB. That log line exists precisely because a wrong polarity
   assumption was foreseen; read it.
2. **Readability before `power_begin()`.** The hatch reads GPIO18 before the AXP2101 rails are
   configured (§4.4.2). The button is a plain switch to ground read through the ESP32's *internal*
   pull-up, so it should not depend on any AXP rail — but "should not" is not "measured". Add a
   temporary `LOGI` of `digitalRead(18)` both before and after `power_begin()` in one build and
   confirm they agree. If they do not, the hatch moves to immediately after `power_begin()`, which
   costs only the AXP stage's coverage — still before display, LVGL, WiFi and BLE.

#### 4.4.2 Exactly where the check goes in `setup()`

Current `setup()` (`firmware/src/main.cpp:87-142`), with the insertion point marked:

```c
void setup() {
  Serial.begin(115200);
  delay(300);
  LOGI("boot - core=%s", ESP_ARDUINO_VERSION_STR);
  enableLoopWDT();

  ota_hatch_check();     // <== HERE. Before nvs_begin(), before power_begin(), before everything.

  nvs_begin();
  location_begin();
  if (!power_begin())   { LOGE("halt: power");   return; }   // I2C + AXP2101 rails
  delay(120);
  if (!display_begin()) { LOGE("halt: display"); return; }   // CO5300 QSPI
  display_brightness(...);
  touch_begin();
  buttons_begin();
  imu_begin();
  /* existing touch-hold -> provisioning hatch (600 ms sample) */
  timekeep_init();                                            // PCF85063 RTC
  /* PSRAM presence check */
  if (!lvgl_port_begin()) { LOGE("halt: lvgl"); return; }
  ticker_table_init(); datastore_init(); styles_init(); carousel_init(); idle_init();
  provision_begin() | net_begin();                            // WiFi
  fetch_task_start(); hub_task_start();                       // BLE
}
```

This placement is **before every stage of the bring-up order in `CLAUDE.md`** (I2C -> AXP2101 rails ->
display -> panel DCS -> LVGL -> WiFi -> BLE). That is the entire point: an image that dies *anywhere*
in that chain — a bad AXP rail sequence leaving the panel dark, a CO5300 init hang, an LVGL heap
failure, a WiFi driver crash, a BLE stack panic — has already run the hatch.

**What the hatch may depend on at that point, and nothing else:**

| Needs | Available? |
|---|---|
| `pinMode()` / `digitalRead()` on GPIO18 | Yes. The GPIO peripheral is up before `app_main`; the internal pull-up is a pad-level setting requiring no driver, no clock config, no I2C, and no PMU rail. |
| `esp_ota_get_running_partition()`, `esp_ota_get_next_update_partition()`, `esp_ota_set_boot_partition()` | Yes. The partition table is parsed by the bootloader and the `esp_partition` API is live from the first line of `app_main`. **These do not need `nvs_flash_init()`** — NVS is a different partition, and `initArduino()` has already run `nvs_flash_init()` before `setup()` regardless. |
| `Serial` for the log line | Yes — `Serial.begin()` + `delay(300)` are the two lines above it. This is the only reason the hatch is not literally the first statement. |
| `millis()` / `delay()` | Yes. |
| **Not** needed: `Wire`, AXP2101, display, LVGL, our NVS layer, WiFi, BLE, RTC, touch, IMU | correct — and this is the property anyone editing `setup()` must preserve |

**Sampling:** 75 samples at 20 ms = **1.5 s**, requiring **>= 68 LOW** (~90%). Longer than the
existing 600 ms touch hatch because this one is destructive and must not fire on a stray press, and
because a user performing a deliberate two-button recovery gesture will hold it. `enableLoopWDT()`
guards `loop()`, not `setup()`, so a 1.5 s blocking sample here is safe — the existing touch hatch
already blocks 600 ms further down.

**Ordering against the existing touch hatch:** the touch hatch cannot move up (it needs
`touch_begin()`, which needs I2C, which needs `power_begin()`). They are independent gestures on
independent hardware and do not conflict. **Do not merge them or overload one to mean both** — the
touch hold already means "force the provisioning portal", and a user reaching for network recovery
must not get a firmware rollback.

#### 4.4.3 What happens if the hatch code is itself broken by an update

**Short answer: nothing in software. USB + the ROM loader is the floor, and no design can remove that
floor.** But the exposure is much smaller than it first appears, for two reasons worth stating
precisely:

1. **The blast radius above the hatch is three lines.** Only `Serial.begin()`, `delay(300)`, `LOGI`
   and `enableLoopWDT()` execute before it. Everything with real failure modes — power, display,
   LVGL, WiFi, BLE, and all of our own code — runs after. An update can break essentially the entire
   firmware and still be escapable.
2. **Any image that can mark itself valid has necessarily executed the hatch.** The hatch is at the
   top of `setup()`; Tier A's mark-valid is at t >= 120 s. So an image that survives long enough to
   become permanent has provably reached the hatch check on that boot. There is no "validated but
   never ran the hatch" state.

That leaves exactly one unrecoverable class: **the hatch is present, runs, and is *wrong*** — the
wrong pin, inverted polarity, an unreachable threshold, or silently removed by a refactor. That is a
code-correctness risk, not a runtime one, and it gets code-correctness mitigations (§4.4.4).

**The floor, documented for the user:** hold **BOOT (GPIO0)** through a power cycle to enter ROM
download mode, then flash `beacon-v<ver>-full.bin` with the web flasher. Put this in
`firmware/README.md` and in the release notes of the first OTA-capable firmware. It is the answer to
every question that starts "what if".

#### 4.4.4 Keeping the hatch correct

- **The decision is a pure function, host-tested.** `core/ota_hatch.cpp` exposes
  `bool ota_hatch_decide(int low_samples, int total, bool other_slot_bootable)`, tested in
  `test_ota_hatch/`, matching the repo's existing pattern for boot-critical logic (`core/button.h`
  `btn_poll`, `core/idle.cpp`, `ui/carousel_nav.h` are all pure host-tested decision helpers). The
  Arduino half is then only "sample the pin, call the function, act".
- **It logs on every boot, pass or fail:** `ota: hatch gpio18 low=0/75 other=app1 -> no`. If a
  refactor drops the call, the missing line is the tell, and it is visible in every serial session
  anyone ever runs. Make its absence a checklist item in `docs/recipes.md` §10.
- **It is exercised deliberately before every firmware tag.** Hold the button, confirm the rollback,
  confirm the device comes up on the other slot. This is a two-minute manual test and it is the
  single highest-value test in the project.

### 4.5 What is not covered — say this in the PR, not just here

- **A build that boots, ticks, keeps a healthy heap, and renders garbage.** Tier A marks it valid.
  Tier C is the *only* remaining answer, and after decision 2 there is nothing between them.
- **Downgrade attacks.** `CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK` is off and secure boot is off, so
  nothing prevents installing an older image. Out of scope by the same reasoning that defers signing.
- **A power-off inside the 120 s window** causes a *spurious* rollback on the next boot (§4.3.1).
- **A corrupted `otadata`.** Recovery is the web flasher's full image, which rewrites `boot_app0.bin`
  at 0xe000 and re-selects `ota_0`.
- **Both slots holding bad images.** Tier C rolls back into the other slot; if that is also bad, the
  hatch on *that* image applies and rolls forward again. A ping-pong is visible in the serial log and
  terminates at USB.

### 4.6 Checksum verification, and why the ordering is already right

Independently of rollback, **a truncated or corrupt image must never become bootable.** Three gates,
in order:

1. **Our SHA-256, computed streaming over the wire** with `mbedtls_sha256` (hardware-accelerated —
   `CONFIG_MBEDTLS_HARDWARE_SHA=1`), compared against the digest delivered over the encrypted BLE link.
   On mismatch: `Update.abort()`, and **`Update.end()` is never called**, so
   `esp_ota_set_boot_partition()` never runs. The half-written slot is inert.
2. **The `Update` library's own gate.** `UpdateClass::end()` runs the MD5 comparison *before*
   `_verifyEnd()`, and `_verifyEnd()` is the only thing that calls `esp_ota_set_boot_partition()`
   (`Updater.cpp:585-598, 641-684`). `Update.setMD5()` is available and costs nothing; set it as a
   belt-and-braces second digest. Note `Update` speaks **MD5 only** — SHA-256 is ours to compute,
   which is why gate 1 exists.
3. **ESP-IDF's own image verification, inside `esp_ota_set_boot_partition()`.** It calls
   `esp_image_verify()`, which validates the segment table, the checksum byte, the **appended SHA-256**
   (this tree's images have `hash_appended = 1`), and the **`chip_id`** (this tree's images carry
   `chip_id = 9`, ESP32-S3). This is a free, already-present authenticity-of-shape check that no
   amount of our own code could improve on.

**Signed images were rejected for key management, correctly — but note the option is closer than it
looks.** The pinned Arduino core ships `Updater_Signing.cpp` and `Update.installSignature()`, so if
that decision is ever revisited, the device-side work is a public key in flash and one call. Record it
here so the next person does not re-scope it as a large project.

---

## 5. Memory and timing during the write

The whole update runs on the **existing Core-0 fetch task**. It already owns the network, already
serializes behind the TLS mutex, and has an 8 KB stack. A dedicated OTA task would cost 3–4 KB of
internal SRAM for a stack we do not need.

### 5.1 The budget, in bytes

| Item | Bytes | Where | Note |
|---|---|---|---|
| `Update`'s sector buffer | **4,096** | **internal DRAM** | `new uint8_t[SPI_FLASH_SEC_SIZE]` (`Updater.cpp:289`). `CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=4096` forces allocations of exactly this size internal — this cannot be moved to PSRAM without patching the library. Accept it. |
| Socket read buffer | **0 new** | internal (`fetch_scratch()`) | see §5.2 |
| `mbedtls_sha256_context` | ~110 | stack | hardware-backed |
| OTA session struct (url, sha hex, counters) | ~200 | stack/heap | transient; not in the DataStore record |
| lwIP TCP socket + pbufs | ~4–8 KB | internal | plain `WiFiClient`, **no mbedtls context** |
| **Freed** at OTA start | **~40–50 KB** | internal | `net_close_idle()` forced: drop the kept-alive `WiFiClientSecure` and its mbedtls context before starting |

**Net effect: the update should run at roughly the same internal-heap watermark as a normal TLS fetch
sweep, or better,** because we deliberately tear down the TLS socket first and never bring up a second
one. Against a 46 KB observed floor that is the only responsible shape.

**Verify this claim on hardware in Phase 1** — log `int_min` across a full update and put the number
in `docs/perf.md`. `docs/tech.md` principle 1 is evidence over assertion, and the paragraph above is
currently an argument, not a measurement.

### 5.2 What `fetch_scratch()` means here

`fetch_scratch()` is 8,192 B of internal `.bss`, shared by every fetcher (#65 M6 consolidated three
per-module buffers into it precisely to protect internal SRAM). **Reuse it as the OTA socket read
buffer.** Reasons:

- It costs **zero additional internal bytes**, which is the only scarce resource.
- The exclusion it implies — no other fetch may run during an OTA — is *already structurally true*:
  the OTA runs on the same single-threaded fetch task and holds the same mutex.
- A PSRAM buffer would also be nearly free, but adds a `heap_caps_malloc` failure path for no gain;
  bytes arrive in lwIP's internal pbufs regardless, so PSRAM buys no DMA advantage here.

**Chunk size: 4,096 B**, matching `SPI_FLASH_SEC_SIZE`. Feed `Update.write()` 4 KB at a time from
offset 0 so each call exactly fills its sector buffer and triggers one flush — no straddling, no
partial-sector rewrite. Read from the socket in 4 KB units into the first 4 KB of `fetch_scratch()`.

At 1,764,208 B that is **431 chunks**; `Update` erases in 64 KB blocks where aligned, so **27 block
erases**.

### 5.3 Do not suspend LVGL; do not suspend BLE

- **BLE stays up.** It is the progress channel and the cancel channel, and its traffic during an update
  is a status frame every second or two — nothing. Tearing the link down risks the bond, and
  CoreBluetooth cannot remove an OS-level bond (`CLAUDE.md`).
- **LVGL keeps rendering, but the 500 ms carousel tick is paused.** `carousel_set_tick_paused(true)`
  already exists (`docs/perf.md` §2, issue #60). No screen `update()` runs, so nothing invalidates a
  full screen and costs a 29.5 ms blit. The OTA overlay owns its own small repaint region.
- **Expect the UI to hitch, and design for it.** `esp_partition_erase_range()` disables the flash cache
  while it runs, so Core 1 — whose *code* is in flash even though its draw buffer is in PSRAM —
  stalls for the duration of each erase, on the order of 100–300 ms per 64 KB block. This is safe:
  `CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1` is **not** set, so Core 1 stalls do not trip the watchdog.
  It is *not* safe to pretend it will not happen: **no spinner, no animation.** A coarse bar updated
  once per whole percent, and text that will still read correctly if it freezes for a third of a second.
- **Core 0 must yield.** `CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0=y` with a 5 s panic timeout — the
  same constraint that produced `read_body_bytes()`'s cooperative drain in `net.cpp` (#92). One
  `vTaskDelay(pdMS_TO_TICKS(1))` per 4 KB chunk: 431 ms added over the whole update, and IDLE0 is fed
  between every erase.

### 5.4 Timing

- Network: 1.77 MB at a realistic 300 KB/s–1 MB/s on this radio = **2–6 s**.
- Flash erase + program dominates. *(estimate)* **30–60 s** total. Measure it.
- Budget the progress UI and the BLE `ota_stat` cadence for a **60 s** worst case, and put a hard
  **180 s** abort on the whole transfer.

---

## 6. The BLE control path

Additive to `hub/CONTRACT.md`, riding `"v":1`. Every proposed frame is far under `HUB_FRAME_MAX`
(1024 B); byte counts below are compact JSON plus the terminating `\n`, computed against worst-case
field values.

### 6.0 Reuse `report`; do not add a second reporting verb

The device does **not** report its firmware version today — `FIRMWARE_VERSION` reaches only the About
panel, and `cmd:"report"` exists solely for tickers (`what:"tickers"`, §B3). The clean extension is a
second `what`, using the same once-per-connection emission point already implemented in
`hub_task.cpp` (`s_reported`, line 29/150) and the same latch-only-on-success retry discipline.

Back-compat is free and already proven: `DeviceCommand.parse` guards
`(obj["what"] as? String) == "tickers"` and returns `nil` otherwise, so **today's hub silently drops a
`what:"device"` report** — exactly the required degradation.

### 6.1 The frames

**D1 — device to hub: device report (extends §B3, `what:"device"`). 167 B worst case.**

```json
{"v":1,"cmd":"report","what":"device","fw":"v0.12.10","chip":"esp32s3","slot":"app1","slotsz":3145728,"appsz":1764208,"ip":"192.168.100.200","hatch":true,"pend":true}
```

- Emitted once per connection alongside the ticker report, on the first inbound frame.
- `fw` = `FIRMWARE_VERSION` (<= 15 B), post-P-2 normalization so it reads `v0.12.10`, not
  `firmware-v0.12.10`. `slot` = running partition label. `slotsz` = the *other* slot's size, so the
  hub can refuse an oversized image before offering. `appsz` = running image size.
- `ip` is the device's STA address — the hub uses it to restrict `LanAssetServer` to that source (§7).
- **`hatch` is the safety interlock and the most important field here.** `true` means this image
  contains the GPIO18 boot hatch (§4.4). Emitted only when true, matching the repo's
  emit-only-when-set convention (`qlen`, `stale`). **The hub MUST NOT send an `ota` offer or go frame
  to a device that did not report `hatch:true`** — it shows *"Update unavailable: this firmware
  predates the recovery hatch. Flash once over USB to enable updates."* This is what makes §0.2's
  "Tier C ships first" a code-enforced invariant rather than a promise.
- `pend` = `true` while the running app is in `ESP_OTA_IMG_PENDING_VERIFY`, so the hub can say
  "verifying" rather than "up to date" during the 120 s window.
- One-way, no ack, like the ticker report.

**H1 — hub to device: offer. 143 B** (no URL; the URL does not exist yet).

```json
{"v":1,"ota":{"rev":4,"ver":"v0.12.10","size":3145728,"sha256":"3f9a...64 hex","go":false}}
```

**H2 — hub to device: go. 224 B** at the shown URL; **247 B** at the 96-byte `url` cap.

```json
{"v":1,"ota":{"rev":4,"ver":"v0.12.10","size":3145728,"sha256":"3f9a...64 hex","url":"http://192.168.100.200:54321/a/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","go":true}}
```

**H3 — hub to device: withdraw. 24 B.** A bare `rev` with no `ver`/`url` cancels the current offer
(hub quit, source changed, transfer window expired).

```json
{"v":1,"ota":{"rev":5}}
```

**D2 — device to hub: offer ack, one per `rev`. 42 B ok / 59 B error.**

```json
{"v":1,"cmd":"ota_ack","rev":4,"ok":true}
{"v":1,"cmd":"ota_ack","rev":4,"ok":false,"err":"too_big"}
```

`err` in {`too_big`, `same_ver`, `no_wifi`, `busy`, `malformed`, `no_slot`}.

**D3 — device to hub: opt-in trigger. 31 B.** Sent when the user taps *Update* on the device.

```json
{"v":1,"cmd":"ota_go","rev":4}
```

**D4 — device to hub: progress and outcome. 48–70 B.**

```json
{"v":1,"cmd":"ota_stat","rev":4,"phase":"dl","pct":62}
{"v":1,"cmd":"ota_stat","rev":4,"phase":"done"}
{"v":1,"cmd":"ota_stat","rev":4,"phase":"fail","err":"hash_mismatch"}
```

`phase` in {`dl`, `verify`, `boot`, `done`, `fail`}. `err` in {`net`, `hash_mismatch`, `write`,
`too_big`, `bad_image`, `timeout`, `aborted`}. Emit on phase change and on every whole percent,
rate-limited to **1 Hz** — the link carries a frame per ~30 s at rest and there is no reason to make
an update the noisiest thing it ever does.

### 6.2 Worst case against the 1024 B ceiling

| Frame | Worst case | Headroom |
|---|---|---|
| H2 (`ota` + 96 B url cap) | **247 B** | 777 B |
| D1 (device report, all fields) | **167 B** | 857 B |
| H1 (offer) | 143 B | 881 B |
| D4 / D2 / D3 | <= 70 B | >= 954 B |

No chunking is needed and none should be added. Field caps to freeze in `records.h`: `ver` <= 15 B,
`sha256` exactly 64 hex, `url` <= 96 B, `err` <= 15 B.

**Sizing note:** the `url` cap of 96 B covers `http://` + an IPv6 literal in brackets (39 + 2) + `:`
+ a 5-digit port + `/a/` + 32 hex = 89 B. Use the **IPv4 literal**, not a `.local` hostname — the
device has no mDNS resolver wired and adding one to the update path is exactly the wrong dependency.

### 6.3 Flow

```
device                                   hub
  |-- D1 report what:"device" ---------->|  learns fw, slot size, ip, AND hatch
  |                                      |  no hatch => refuses to offer, and says why
  |                                      |  polls the configured repo / user clicks Install current build
  |<------------- H1 offer (go:false) ---|  "v0.13.0 available"
  |-- D2 ota_ack ok:true --------------->|
  |         [user taps Update on device] |         [or clicks Install in the hub]
  |-- D3 ota_go ----------------------->|  arms LanAssetServer, mints token
  |<------------- H2 go (url) -----------|
  |-- plain HTTP GET over LAN ---------->|  serves once, then disarms
  |-- D4 ota_stat dl/verify ------------>|
  |-- D4 ota_stat boot ---------------->|  hub expects the link to drop
  |   [reboot; hatch check; Tier A gate] |
  |-- D1 report fw:"v0.13.0" pend:true ->|  hub shows "verifying" for 120 s
  |-- D1 report fw:"v0.13.0" ---------->|  (next connection) confirmed
```

There is **no unattended path through this diagram** (decision 3). Either end can initiate the
install, but an install always follows a human action.

### 6.4 Back-compat

- Old firmware, new hub: the `ota` frame is an unknown top-level key. `hub_parse_status` and friends
  key off their own block names, so it parses as "no usage/buddy/loc/sessions" and is ignored — the
  same path `sessions`, `sdetail`, `sonos` and `pages` all took. And such a device never reports
  `hatch:true`, so the hub will not send it an `ota` frame at all. **No version bump.**
- New firmware, old hub: no `ota` frame ever arrives, so the device never offers an update. `ota_ack`
  / `ota_go` / `ota_stat` and the `what:"device"` report all return `nil` from `DeviceCommand.parse`
  and are dropped. Nothing breaks.
- Neither direction requires the other to be upgraded first, which matters because the hub is the
  thing that would ship the firmware that understands the hub.

---

## 7. LAN exposure

Binding anything to the LAN is a real change to the user's network posture and should be described that
way in Settings, not buried.

**The design:**

1. **A separate listener, not `LocalIngestServer`.** `LocalIngestServer` keeps its 127.0.0.1 binding
   and its POST-only JSON routing, untouched. `LanAssetServer` (§2.1) is a distinct `NWListener` with a
   deliberately trivial handler.
2. **Armed only during a transfer.** Created on `ota_go`, torn down on `done`, `fail`, first successful
   serve, or a **10 minute** window expiry — whichever is first. At rest, nothing is listening.
3. **Ephemeral port**, chosen by the OS per transfer. Not 8765, not fixed, not discoverable by
   scanning a known port.
4. **128-bit single-use path token** (32 hex chars from `SecRandomCopyBytes`), compared in constant
   time, invalidated after the first complete response.
5. **Source-address restriction.** Accept only connections whose remote endpoint matches the device's
   IP as reported in D1; drop everything else before reading a byte. Additionally reject any remote
   address outside RFC1918 / link-local, so a misconfigured router cannot expose it to a WAN peer.
6. **Attempt cap.** At most 3 accepted connections per armed window, then disarm — a retry budget, not
   an open door.
7. **`NSLocalNetworkUsageDescription` in `hub/Info.plist`** — prerequisite P-1 (§0.3). Without it,
   macOS 15+ silently TCC-denies and OTA presents as a hang. Add the Local Network row to the Settings
   **Connection** checks and test the denied path.

**Should the device authenticate to the server?** No, and it is worth being clear why. The device does
not need to prove its identity to fetch a public artifact — the same bytes are on GitHub Releases and
served by the web flasher over the open internet. The direction that matters is the reverse: the device
must know the bytes are the ones the hub meant, and that comes from the **SHA-256 delivered over the
bonded, encrypted BLE link**, not from the HTTP hop. The path token is a capability, not an
authenticator.

**Residual risk, stated honestly:**

- For up to 10 minutes per update, the Mac has an extra listening TCP socket. Its handler does a fixed
  string compare and writes a fixed-length buffer, so the attack surface is small — but it is not zero,
  and it must stay small. **Never merge OTA serving into the hooks server**, which parses arbitrary
  JSON.
- Anyone who can observe the token (they would need to break BLE LE Secure Connections, or read the
  hub's logs) can download the firmware. The firmware is public. The loss is nil.
- Source-address restriction is spoofable on a hostile LAN. It raises cost; it is not a control. The
  real control is that the payload is public and the integrity check is out of band.
- The device does not validate the server. A LAN attacker who can win a race on the URL serves bytes
  that fail the SHA-256 check and are never made bootable. The failure mode is a wasted update, not a
  compromised device.

---

## 8. Device-side UX

466x466, `SAFE_INSET` 40 px, `THEME_COUNT` is **1** (editorial) — so there is exactly one visual
treatment to build, and it reads tokens (`t->ink`, `t->ink_dim`, `t->accent`, `t->f_hero`,
`t->f_body`) like everything else. `DESIGN.md`'s screen-state rules apply: never render a guessed state
as live.

**The idiom already exists.** `ui/pair_overlay.cpp` is a centered `lv_layer_top()` card with an
eyebrow, a hero-font figure and a wrapped hint, serviced from the LVGL loop. **`ui/ota_overlay.cpp` is
that file with different content.** Do not invent a new overlay mechanism.

**1. Offer (passive).** A row in Settings: `FIRMWARE   v0.12.10 > v0.13.0` with an accent chevron, and
a `NEW` chip on the settings dot in the carousel. No takeover — an available update is not an
interruption. Tapping the row opens a small card: version, size, and **Update now** / **Not now**.
Tapping Update sends `ota_go` (D3). This tap is one of the two places decision 3's required human
action can happen.

**2. Download and write (takeover, non-dismissable).** Full-screen card inside the safe area:

```
        BEACON / UPDATE            <- eyebrow, t->ink_dim, letter-spaced (matches chrome)

              62%                  <- t->f_hero digit-subset font, t->accent

        [===============-------]   <- 320 px bar, 6 px tall, t->line track / t->accent fill

        Installing v0.13.0         <- t->ink
        Keep the device powered    <- t->ink_dim
```

- Phases relabel one line, they do not re-lay-out: `Downloading` -> `Verifying` -> `Installing` ->
  `Restarting`. Percent covers download (0–15%) and write (15–100%) on one continuous scale, because a
  bar that resets to zero reads as a failure.
- **The bar and the percent update once per whole percent, and nothing animates.** Per §5.3 the UI
  stalls 100–300 ms on every 64 KB flash erase; a tween would visibly stutter and read as a hang. A
  discrete step that freezes briefly reads as work.
- Swipe and the shake-to-dismiss gesture are disabled for the duration. The card is the only thing
  that can be on screen.
- **`Keep the device powered` is doing real work** — it is the only warning the user gets before a
  power cut during the write, and per §9 that costs them the update.
- Touch is not blocked entirely: a small `Cancel` affordance is live during the **download** phase
  only. Once the first flash erase has happened, cancel is gone — half-erasing the inactive slot and
  then stopping is strictly worse than finishing.

**3. Failure.** The same card, no bar: `UPDATE FAILED`, the honest short cause (`no connection`,
`checksum mismatch`, `image too large`, `write error`), and `Your device is unchanged.` — which is
true, and is the single most useful sentence on the screen. Dismissable by tap; the hub re-offers.

**4. Restarting.** The card's last state before `ESP.restart()` reads `Restarting` with no percent. The
existing boot sequence takes it from there (<4 s to first render, `docs/tech.md` §8).

**5. After the update: nothing.** Per decision 2 there is no confirmation card, no "keep this
version?", no post-update takeover of any kind. The device comes up on the new firmware and behaves
normally; Tier A marks it valid silently at 120 s. The About panel's `VERSION` row is the only place
the new version is asserted, and the hub shows "verifying" while `pend` is true.

**6. The recovery gesture is documentation, not UI.** Tier C has no on-screen affordance *by
construction* — it exists for the case where there is no usable screen to put one on. It belongs in
`firmware/README.md`, in the release notes of the first OTA-capable firmware, and ideally on a card in
the box: *"If an update leaves the screen wrong: power off (hold PWR 5 s), then power on while holding
the side button."*

---

## 9. Failure modes

| Failure | Behaviour | Why it is safe |
|---|---|---|
| **WiFi drops mid-download** | Socket read stalls; the per-read deadline fires; `Update.abort()`; `ota_stat fail err:"net"`; overlay shows *no connection / Your device is unchanged*. | `esp_ota_set_boot_partition()` was never called. `otadata` still points at the running app. The partial slot is inert and is overwritten on the next attempt. |
| **Mac sleeps mid-download** | Identical to a WiFi drop from the device's side (TCP stalls). Additionally the hub takes an `NSProcessInfo.beginActivity(.userInitiated, .idleSystemSleepDisabled)` assertion for the transfer window, released on completion or on the 10 min expiry. | Same as above. Sleep already breaks every hub-fed page; OTA fails the same way and says so. |
| **Power loss mid-write** | Next boot runs the old firmware, unchanged, with no trace of the attempt except a partially written inactive slot. | **This is the failure mode the verify-before-`set_boot_partition` ordering exists for**, and it is fully covered. Not a "mostly fine" — the boot selector is literally untouched. |
| **Hash mismatch** | `Update.end()` is never called; `Update.abort()`; `ota_stat fail err:"hash_mismatch"`. The hub does **not** auto-retry the same `rev` — it re-verifies its own copy first (re-downloads, re-checks `SHA256SUMS`) and mints a new `rev` if the artifact was bad. | Avoids a retry loop that grinds flash against a corrupt artifact. Three independent gates (§4.6) would each have caught it. |
| **Image larger than the slot** | Three gates, none of which touches flash: the hub refuses to offer if `size > slotsz` from D1; the device rejects the offer with `ota_ack err:"too_big"`; `Update.begin(size)` itself returns `UPDATE_ERROR_SIZE` (`Updater.cpp:279-283`). | Rejected before the first erase. |
| **Wrong chip / wrong board** | `Update._verifyHeader` rejects a first byte that is not `0xE9`; `esp_image_verify()` inside `esp_ota_set_boot_partition()` rejects a `chip_id` that is not 9 (ESP32-S3) and a bad appended SHA-256. `ota_stat fail err:"bad_image"`. | A wrong-chip image **cannot** be made bootable. This is IDF's check, not ours, and it is stronger than anything we would write. |
| **Update panics or hangs before first render** | Bootloader sees `PENDING_VERIFY` on the *next* boot, marks it aborted, and boots the previous slot. One reboot, not a loop. | Tier A. This is the case bootloader rollback exists for and it is now genuinely enabled (§4.1). |
| **Update boots, ticks, keeps a healthy heap, and renders garbage** | Tier A marks it valid at 120 s. **Recovery is Tier C only:** power off, power on holding GPIO18. Below that, USB + ROM loader. | **The weakest link in the whole design, and after decision 2 there is nothing between Tier A and Tier C.** See §13 risk 1. |
| **A hatch-less image is offered an update** | The hub refuses to send `ota` at all and explains why (§6.1 `hatch`). | Code-enforced, not discipline-enforced. This interlock is what makes the whole recovery story hold. |
| **GPIO18 idles LOW on some board revision** | The hatch fires every boot and the device ping-pongs between slots. Visible in the serial log (`ota: hatch gpio18 low=75/75`); recoverable over USB. | Prevented by the Phase 0 hardware check (§4.4.1), which reads the resting-level line `buttons_begin()` already logs. |
| **Hub quits mid-transfer** | `LanAssetServer` dies with the process; the device's read stalls; same path as a WiFi drop. On next connect the device reports `fw` unchanged and the hub re-offers. | No state on either side survives a failed transfer except the inert partial slot. |
| **User power-cycles inside the 120 s health window** | Spurious rollback to the previous firmware on the next boot. The hub sees the old `fw` in D1 and re-offers. | Deliberate bias (§4.3.1). Costs one update; never costs a cable. |
| **Two updates raced (hub re-offers while one is running)** | Device answers `ota_ack err:"busy"` for any `rev` arriving while a transfer is live, and ignores `H3` withdraw for the in-flight `rev` once flash erasing has begun. | Single-threaded on the fetch task; there is no second writer to race. |

---

## 10. Version and release discipline

**Tags.** `firmware-vX.Y.Z` (`CONTRIBUTING.md`), which `release-firmware.yml` already turns into
`beacon-vX.Y.Z-app.bin` + `-full.bin` + a Pages web flasher deploy, and which will additionally publish
`SHA256SUMS` (decision 4).

**Prerequisite P-2 (§0.3) must land first** — the `FIRMWARE_VERSION` prefix mismatch. Nothing that
compares versions can be written before it.

**How the hub decides an update is available.**

1. Read the device's running `fw` **and `hatch`** from the D1 report (per connection — authoritative
   and free). No `hatch`, no offer, full stop.
2. Poll `releases/latest` on the **configured** repo (default `trever/beacon`, decision 1) on hub
   launch and every 6 h, with an `ETag` conditional request. The unauthenticated GitHub API allows
   60 requests/hour/IP; this uses ~4/day.
3. Compare as semver. **`dev` is not a version** — a locally built device is never offered a release;
   the hub shows `FIRMWARE  dev` and only *Install current build* can target it.
4. Download the asset, verify it against `SHA256SUMS`, hash it, and only then emit H1.

**The Settings > Firmware section.**

- `Device firmware` — read-only, from D1: `v0.12.10`, or `v0.12.10 (verifying)` while `pend`, or
  `v0.12.10 - no recovery hatch, flash once over USB to enable updates` when `hatch` is absent.
- `Update source` — **Released** (default) / **Local build**.
- `Repository` — text field, `owner/repo`, default `trever/beacon`, with **Check now**.
- `Check for updates automatically` — default **on**. **Checking only.**
- `Install` — a button. **There is no auto-install setting, and none will be added** (decision 3). An
  unattended flash of a desk device with no reset button is not a feature.

---

## 11. Phasing

**Phase 0 — prerequisites and the recovery floor. Nothing else may ship before all of it.**

- **P-1** `NSLocalNetworkUsageDescription` in `hub/Info.plist` + a Local Network row in the Settings
  Connection checks + a test of the denied path (§0.3).
- **P-2** `FIRMWARE_VERSION: ${GITHUB_REF_NAME#firmware-}` in `release-firmware.yml` (§0.3).
- `SHA256SUMS` in the release artifacts (decision 4).
- **The Tier C GPIO18 boot hatch** — `core/ota_hatch.cpp` (pure decision + host test
  `test_ota_hatch`), the `setup()` call site (§4.4.2), the every-boot log line, and the hardware
  checks in §4.4.1. **Plus a `firmware-v*` tag that ships it**, because a hatch that is not on the
  device is not a hatch.
- `cmd:"report"` `what:"device"` (D1) including `hatch`, and the hub side that displays it and gates
  on it. **On its own this gives Settings a "Device firmware v0.12.10" row**, which is useful today.

Phase 0 has real standalone value (a version row, a fixed release workflow, a digest) *and* it is what
makes Phase 1 safe. Do not compress it into Phase 1.

**Phase 1 — local-build OTA, with rollback and checksum. The one that pays for itself immediately.**

- `LanAssetServer` (§2.1), armed/disarmed per transfer.
- BLE frames H1/H2/H3 + D2/D3/D4.
- Device: `net_lan_get_stream()` (plain HTTP, chunked into `Update`), streaming SHA-256, the
  `Update.begin/write/end` path, `ui/ota_overlay.cpp`.
- Tier A: `verifyRollbackLater() { return true; }`, the four-condition gate, the 120 s window.
- Hub UI: Settings **Firmware** section with **Local build** selected and the **Install current
  build** button.
- Measure and record: `int_min` across an update, wall-clock duration, and observed UI hitch length.
  Put them in `docs/perf.md`.
- **Exercise the hatch before tagging.** Install a deliberately broken build (one that renders a blank
  screen but keeps ticking), confirm Tier A does *not* catch it, confirm Tier C does. That test is the
  point of the whole phase.

At the end of Phase 1 the USB cable is out of the inner loop, which is the thing the user actually
wants this quarter. No release plumbing exists yet and none is needed.

**Phase 2 — released firmware.** GitHub Releases polling with `ETag` against the configured repo,
semver comparison, `SHA256SUMS` verification, the offer UI on both ends, the repo Settings field.
Nothing on the device changes; Phase 1's mechanism is source-agnostic by construction.

**Phase 3 — polish, driven by what Phase 1/2 actually hurt.** Candidates, none committed: HTTP `Range`
resume (only if a failed 40 s download proves annoying in practice); release notes on the device; a
device-initiated "check for updates"; a Settings rollback row.

**Explicitly not in the plan:** signed images, anti-rollback, secure boot, delta updates
(`esp_delta_ota` is present in the toolchain), multi-device fan-out, and any form of unattended
install.

---

## 12. Open questions

Three of the original eight are settled (§0.1). What remains, each with **my recommendation marked
provisional — not yet confirmed by the user**:

1. **Is 120 s the right Tier A window?** *Provisional recommendation: yes, 120 s* — raised from 60 s
   because decision 2 removed the cheap escape and made a missed rollback more expensive (full
   reasoning in §4.3.1). The counter-argument is that it widens the spurious-rollback window for
   someone who powers the device off right after an update. **Still open**, because it is a judgement
   about your habits, not a technical fact.
2. **Should the offer surface on the device at all, or only in the hub?** *Provisional
   recommendation: yes — a Settings row plus a `NEW` chip on the settings dot.* Decision 3 requires a
   human tap, and forcing that tap to happen on the Mac makes the device feel less like the thing
   being updated. The counter-argument is that a `NEW` chip is one more thing on a deliberately
   glanceable screen. **Not yet confirmed.**
3. **How loud should a failed update be on the Mac?** *Provisional recommendation: a menubar alert,
   matching the existing "Beacon offline - CODEX not gated" pattern, cleared on the next successful
   check.* A silent failure in the update path is the same class of problem as the silent TCC denial
   in P-1. The counter-argument is alert fatigue for a transient WiFi blip. **Not yet confirmed.**
4. **New, raised by this revision: should the hub refuse to offer when it cannot reach the device's
   reported `ip`?** *Provisional recommendation: no — offer anyway and let the transfer fail honestly
   with `err:"net"`*, because a pre-flight reachability probe is one more thing that can be wrong
   (VLANs, client isolation, a stale DHCP lease) and would block updates that would in fact work.
   **Not yet confirmed**; the opposite view is that failing at 0% after arming the LAN server is a
   worse experience than never offering.

---

## 13. Risks, ranked

**1. After decision 2, one narrow gesture on one GPIO is the entire software recovery story.**
*(This is the biggest risk in this design, and it got bigger when the confirmation card was removed.)*
Tier A catches only "fails to reach a live UI". A build that boots, ticks, keeps a healthy heap, and
renders nothing usable marks **itself** valid — and there is now nothing between that and holding
GPIO18 through a power cycle on a board with no RST button. Below that is USB + hold BOOT through a
power cycle + the web flasher.

*What this demands, in order:*
(a) **Tier C ships first and is interlocked.** The `hatch:true` flag in D1 and the hub's refusal to
offer without it (§6.1) is what turns "we should do that first" into something the code enforces.
(b) **The hatch runs before every other stage of bring-up** (§4.4.2), so only three lines can break
above it.
(c) **The hatch's own correctness gets host tests and an every-boot log line** (§4.4.4), because a
present-but-wrong hatch is now the one genuinely unrecoverable software state.
(d) **Every condition added to Tier A converts a class of "broken but alive" into a class of
"automatically reverted"** — that is why the since-boot heap minimum is in the gate, and why the gate
should be revisited whenever a new whole-device failure mode is observed.

**2. The memory argument in §5.1 is an argument, not a measurement.** The claim that an OTA runs at or
below a normal TLS sweep's watermark rests on freeing the mbedtls context before starting. If that is
wrong — if lwIP buffers under a sustained 1 MB/s inbound stream cost more than the freed handshake
context — the update panics mid-write against a 46 KB floor. The panic itself is *safe* (§9), so the
consequence is "updates never work" rather than "device bricked", but that is still a feature that
does not ship. Measure `int_min` in Phase 1 before writing the overlay.

**3. GPIO18's resting polarity is documented but not measured by me.** A board revision that idles it
LOW turns the recovery hatch into a boot loop between slots — the safety net becoming the hazard. The
check is one serial line that `buttons_begin()` already prints (§4.4.1), it costs nothing, and it must
be done before the hatch ships. Ranked this high only because of what it would break.

**4. macOS Local Network permission silently kills the feature** (P-1). On macOS 15+, a denied TCC
prompt means the device's GET is refused with no signal on either end; it presents as "the download
just hangs". Mitigated by the Info.plist key and a visible Connection check, but it must be tested
with the permission **denied**, not only granted.

**5. Flash-erase cache stalls make the update look broken.** 100–300 ms UI freezes, 27 times, on a
device whose entire value proposition is being glanceable. Mitigated by the no-animation rule (§5.3,
§8), but if the measured hitch is materially worse than estimated, the progress UI may need a static
"Installing" card with no percent at all.

**6. Two independent release trains drift.** `firmware-v*` and `hub-v*` ship separately, and the hub
is the thing that delivers firmware. A hub too old to understand `ota` frames simply never offers
(§6.4) — a safe degradation, but it also means "why is my device not updating" has a hub version as a
possible answer. Surface both versions in Settings side by side.

**7. `Update`'s 4 KB sector buffer is pinned to internal DRAM** by
`CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=4096` and cannot be moved without patching a pinned library. It
is only 4 KB, and it is the cheapest item in §5.1 — but it is a hard floor that no amount of PSRAM
solves, and it should be counted in every future internal-heap budget that includes an OTA.

---

## 14. Doc changes this implies

- `hub/CONTRACT.md` — new **§A3** (hub -> device `ota` frame) and additions to **§B** (`ota_ack`,
  `ota_go`, `ota_stat`) and **§B3** (`report` `what:"device"`, including the `hatch` interlock and the
  hub-side rule that depends on it). Follow `docs/recipes.md` §4 and §5; both paths have a checklist.
- `docs/tech.md` §3 — the validated bring-up sequence gains a step 0: **the OTA boot hatch runs before
  step 1 (`Wire.begin`)** and must stay there. This is the single most important line to add, because
  the bring-up order is exactly what future work will edit.
- `docs/tech.md` §11 — the partition table now has a live consumer; record that `otadata` is
  authoritative and that a full USB flash resets it to `ota_0`.
- `docs/perf.md` §3 — add the measured OTA internal-heap watermark and duration.
- `docs/codemap.md` §1 — device -> hub commands goes 4 -> 7; hub -> device blocks gains `ota`.
- `docs/recipes.md` §10 (conventions that are easy to violate) — "**do not move or remove
  `ota_hatch_check()` from the top of `setup()`**", with the every-boot log line named as the tell.
- `firmware/README.md` — the two recovery gestures (GPIO18 hold; BOOT hold + web flasher), written for
  a human looking at a device that is not working.
