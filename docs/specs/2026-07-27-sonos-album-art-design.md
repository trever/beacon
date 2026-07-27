# Sonos album art: the hub rasterises, the device blits

**Status:** design, not yet built. Written 2026-07-27.

Phase 1 of `docs/specs/2026-07-26-hub-as-controller-and-sonos-design.md` shipped: a `sonos` page,
text only, fed by a standalone BLE frame. This is that document's **phase 2**, and its §3 already
settled the shape — *the hub fetches and downscales the art, then serves it over the LAN, and the
device fetches it by URL.* That conclusion is taken as given here and is not re-derived.

What this document adds is everything §3 left as one sentence: what travels on the wire, how the URL
gets there, where the bytes live on a device whose internal heap floor is 46,428 B, and what happens
when any of it fails.

## 0. Why this ships before OTA

`docs/specs/2026-07-27-ota-updates-design.md` §2.1 specifies **`LanAssetServer`** — one deliberately
dumb LAN byte-serving component — and names album art as its second caller. The OTA plan
(`docs/plans/2026-07-27-ota-updates-plan.md`, WS-3) goes further and makes generality an *acceptance
item*: *"a test must arm it with a small non-firmware payload (e.g. 2 KB of `image/jpeg`) and fetch it
successfully. That test is the proof the component is general."*

Album art is that proof, in production, against the gentler consumer. A wrong image is a wrong picture
on a desk clock. A wrong firmware image is a dark panel and a USB cable on a board with **no reset
button** (`docs/tech.md` §2). Proving the LAN plane with the cosmetic payload first is the correct
order of operations, and it is why this project takes on two things that were scoped to OTA:

- **Prerequisite P-1 moves here.** `hub/Info.plist` has no `NSLocalNetworkUsageDescription`, so on
  macOS 15+ the LAN serve is **silently TCC-denied** and presents as a hang with no diagnostic on
  either end (OTA design §0.3, risk 4). Art needs the key for exactly the same reason. It lands in
  this project's Phase B, together with the Settings **Connection > Local Network** row and the
  **denied-path test**, and OTA inherits it done.
- **`LanAssetServer` and the device's plain-HTTP LAN GET land here.** OTA's WS-2/WS-3 then extend
  rather than create.

There is also a diagnostic dividend. The Local Network row that P-1 requires is **outcome-derived** —
it has no API to query, so it can only report what a real transfer did (OTA plan §3, settled
2026-07-27). A firmware update produces that evidence roughly monthly. Album art produces it every few
minutes on a listening day, which is the difference between a check that is usually `.checking` and
one that is usually true.

---

## 1. The decision that dominates everything: raw pixels, not an encoded image

**Recommendation: the hub rasterises to a fixed 200x200 big-endian RGB565 tile — 80,000 bytes,
header-less, row-major — and the device blits it. The device gets no image decoder of any kind.**

### 1.1 The numbers

| Option | Wire bytes | Device decoder | Device working RAM | Resident RAM | New dependency |
|---|---|---|---|---|---|
| **Raw BE-RGB565 200x200** | **80,000** | **none** | **0** | 2 x 80,000 (PSRAM) | **none** |
| JPEG q80 200x200 | ~6,000-10,000 | TJpgDec / `LV_USE_SJPG` | ~3,100 B workspace + MCU buffers | same 2 x 80,000 | +1 |
| PNG 200x200 (photographic) | ~40,000-90,000 | lodepng / `LV_USE_PNG` | 160,000 B RGBA8888 + 32 KB inflate window | same | +1 |
| Raw RGB565 over BLE, base64 | 106,668 encoded, ~113 frames | none | 0 | same | none |

The decisive line is the **resident RAM column: it is identical in every row.** A decoder does not
reduce the memory that matters. Whatever arrives on the wire, the thing LVGL renders is 80,000 bytes
of RGB565, because `LV_COLOR_DEPTH 16` and there is no full framebuffer to blit from. JPEG's saving is
**entirely on the link**, and the link is the one resource here that is free.

Quantified: JPEG saves ~72 KB of LAN transfer per track. At the 300 KB/s-1 MB/s the OTA design budgets
for this radio (§5.4), that is **72-240 ms per track**. The price is a decoder inside a toolchain
marked *"Do Not Bump Without a Spike"* (Arduino-ESP32 3.3.5 / pioarduino 55.03.35), plus a
`lv_conf.h` flip, plus flash, plus a permanent new failure surface. **72-240 ms is not worth a
dependency.**

### 1.2 Three further arguments, each independently sufficient

1. **The hub must decode the source image regardless.** Sonos art URLs point at music-service CDNs
   serving JPEG, PNG, WebP and increasingly AVIF. The hub has to decode *something* and rescale it to
   200x200 no matter what. Choosing JPEG on the wire means the hub decodes, rescales, **re-encodes**,
   and the device decodes **again** — two extra codec passes to save 100 ms. Raw skips both.
2. **Format normalisation is permanent.** A device-side decoder pins the product to whichever formats
   that decoder supports, forever, on a device that is hard to reflash. With CoreGraphics on the Mac
   as the only decoder, **the device's art path never needs to change again** when a service switches
   to AVIF. That is an architectural property, not a nicety.
3. **The parsing attack surface stays on the platform that can patch it.** Album art is arbitrary
   bytes from a third-party CDN named by a third-party JSON field. Decoding that on a hardened,
   OS-updated macOS image decoder is categorically different from decoding it in unpatched C on a
   microcontroller with 46,428 B of free internal heap. Moving a format parser toward the constrained,
   unpatchable end of the system is the wrong direction.

### 1.3 What was rejected, and why

- **JPEG on the wire** — rejected above. Note for the record that `LV_USE_SJPG` exists in the pinned
  LVGL 8.4 and is compiled out (`lv_conf.h:664`), so this is a config flip rather than a vendored
  library. It is still a dependency: SJPG's plain-JPEG path has its own workspace and failure modes,
  TJpgDec does not support progressive JPEG, and neither is exercised by anything else in this repo.
- **PNG** — worse than raw on the wire for photographic content, 200 KB+ of decode churn per track,
  and lodepng against internet-sourced input is a known CVE surface. Disqualified on its own merits.
- **RGB565 over BLE, base64 in JSON frames** — the phase-1 design already measured this at 15-30 s for
  a 160x160 tile. At 200x200 it is **24-47 s per track**: a three-minute song would spend a quarter of
  its length transferring its own cover, over the same radio that carries permission prompts. Dead.
- **Variable tile dimensions on the wire** — rejected in §2.3. Fixed 200x200 is what lets the device's
  buffer be a compile-time constant and its length check be an equality.

### 1.4 The one trap: endianness

`platformio.ini` `[env:beacon]` sets **`-DLV_COLOR_16_SWAP=1`**, so **LVGL rasterises big-endian
RGB565** and `flush_cb` uses the zero-copy `draw16bitBeRGBBitmap` path. `docs/perf.md` §2.1 states the
consequence in as many words: *"Changing one without the other reverses every pixel's colour bytes."*

An `LV_IMG_CF_TRUE_COLOR` buffer must therefore be **big-endian RGB565, high byte first**. CoreGraphics'
natural 16-bit output (`kCVPixelFormatType_16LE565` and friends) is **little**-endian. A hub that emits
the natural thing produces a tile where every pixel's colour is scrambled, and it will look like a
broken decoder rather than a byte-order bug.

Frozen in both directions, with a host test on each side over a known four-pixel tile and its exact
expected bytes:

```
tile[0..1] = 0xF8 0x00   (pure red   = RGB565 0xF800, high byte first)
tile[2..3] = 0x07 0xE0   (pure green = RGB565 0x07E0)
tile[4..5] = 0x00 0x1F   (pure blue  = RGB565 0x001F)
tile[6..7] = 0x00 0x00   (black — and black is the panel's off-pixel, see 2.3)
```

### 1.5 What this means for `LanAssetServer`

`Content-Type: application/octet-stream`. Not `image/jpeg` (a lie), not `image/x-rgb565` (an invented
media type). The payload is a private pixel layout, and the device ignores the header anyway.

**The server stays exactly as dumb as the OTA design specifies.** It holds a `Data` and writes it; the
`contentType` parameter it already takes (`arm(_:contentType:peer:ttl:maxServes:)`) needs no change.
All the rasterising lives in a separate `SonosArtRenderer` — fetch, decode, aspect-fit, colour-convert,
hash — which the server never sees. **The server must never learn what a pixel is.**

The caller's *arm parameters* do change, and that divergence is the substance of §7.

---

## 2. The wire

### 2.1 A separate `sart` frame, not a field on `sonos`

`hub/CONTRACT.md` records the `sonos` frame's measured worst case: every field filled to its cap with
a ZWJ family-emoji grapheme cluster encodes to **3,177 B pre-shrink**, and the encode-measure-shrink
loop trims it to **1,002 B** against the 1,024 B `HUB_FRAME_MAX`. That is **22 bytes of headroom.**

Adding a 96-byte URL to that frame means the shrink loop must sacrifice ~96 more characters of
`album`, then `artist`, then `track` to make room for it — i.e. **a long track title and the art URL
would compete, and the loop's trim order would decide which the user loses.** That is backwards: if
anything must be dropped, it should be the art, not the artist's name.

A separate frame also buys a property the `sonos` frame cannot have. `sart` contains **no free-form
text at all**: `gen` is an integer the hub mints, and `url` is `http://` + an IPv4 dotted quad + a port
+ `/a/` + 32 lowercase hex. Every byte is drawn from `[0-9a-f.:/htp]`, **none of which JSON escapes**,
so for this frame **character caps bound bytes exactly** and no shrink loop is needed. This is the
`comps` frame's property (CONTRACT.md §A3), and it means `sart`'s ceiling is *provable* rather than
*measured*.

Same call `sdetail` made against `sessions`, and `sonos` made against the status frame, for the same
reason each time. Third instance; the precedent is settled.

### 2.2 The frames

**S1 — hub to device: art available. 139 B worst case.**

```json
{"sart":{"gen":7,"url":"http://192.168.1.42:54321/a/0123456789abcdef0123456789abcdef"},"v":1}
```

**S2 — hub to device: no art for this track. 34 B worst case.** A bare `gen` with no `url`.

```json
{"sart":{"gen":8},"v":1}
```

**S3 — device to hub: outcome, one per `gen`, one-way, no ack expected. 75 B worst case.**

```json
{"v":1,"cmd":"sart_stat","gen":7,"ok":true}
{"v":1,"cmd":"sart_stat","gen":7,"ok":false,"err":"timeout"}
```

Key order in S1/S2 is `JSONEncoder(.sortedKeys)`, matching every other hub->device frame; S3 is built
by `hub_proto.cpp` in the fixed order the existing `cmd` frames use. All three are newline-terminated.

### 2.3 Worst case against 1,024 B

| Frame | Composition | Bytes | Headroom |
|---|---|---|---|
| **S1** | `{"sart":{"gen":` 15 + `4294967295` 10 + `,"url":"` 8 + url 96 + `"},"v":1}` 9 + `\n` 1 | **139** | 885 B (86.4% free) |
| S2 | `{"sart":{"gen":` 15 + `4294967295` 10 + `}` 1 + `,"v":1}` 7 + `\n` 1 | **34** | 990 B |
| S3 | `{"v":1,` 7 + `"cmd":"sart_stat",` 18 + `"gen":` 6 + `4294967295` 10 + `,"ok":false` 11 + `,"err":"conn_refused"` 21 + `}` 1 + `\n` 1 | **75** | 949 B |

**No chunking, and none should be added.** Frozen caps for `records.h`: `url` <= **96 B**, `gen` is
**uint32**, `err` <= **15 B**.

The 96 B `url` cap is OTA's cap, reused verbatim with its reasoning: `http://` + a bracketed IPv6
literal (39 + 2) + `:` + a 5-digit port + `/a/` + 32 hex = 89 B. **Use the IPv4 literal, never a
`.local` hostname** — the device has no mDNS resolver wired and adding one to this path is exactly the
wrong dependency (OTA design §6.2).

Field notes:

- **`gen`, not `rev`.** In this protocol `rev` always means "a config revision the device persists and
  acks" (`config`, `pages`, `comps`). `gen` identifies a *tile's content*, is never persisted, and is
  never acked through the config machinery. A different meaning gets a different name, or someone will
  route it through `configAck`.
- **No digest.** OTA delivers SHA-256 over BLE because its payload becomes *executable*. Art never
  does; the worst outcome of wrong bytes is a wrong picture. Truncation — the failure that actually
  looks broken — is caught deterministically by `Content-Length == 80000` plus "exactly 80,000 bytes
  received", with no hashing. A digest would only defend against a LAN attacker who wins a race on an
  unguessable single-use URL to serve exactly 80,000 bytes of *chosen* pixels. Deliberate divergence
  from OTA; stated so it reads as a decision rather than an omission.
- **No `w`/`h`.** The tile is always 200x200 by contract (§3.1), so dimensions on the wire would be
  three bytes of redundancy and a second source of truth.
- **Absence of a `sart` frame must never mean "clear the art".** Art is cleared **only** by an
  explicit S2. This is the opposite rule from the `sonos` frame, which is a full snapshot where an
  absent field means default (`records.h:120-123`) — and the difference is load-bearing: under the
  snapshot rule a single dropped frame would blank the tile.
- **`err`** in {`conn_refused`, `timeout`, `http`, `size`, `net`, `no_wifi`}. This is OTA's split
  vocabulary reused deliberately, not a parallel one: `timeout` at zero bytes is the **TCC-denial**
  shape and `conn_refused` is the **firewall** shape, and those two values are precisely the evidence
  P-1's outcome-derived Local Network row consumes (OTA plan §3). Do not collapse them.

### 2.4 Back-compat

Additive within `"v":1`, no version bump, both directions:

- **Old firmware, new hub:** `on_frame`'s dispatch chain keys off known block names and falls through
  to `hub_parse_status`, which logs `hub: bad/ignored frame` and returns. Identical to how `sessions`,
  `sdetail`, `sonos`, `comps` and `pages` each landed. Text-only Sonos keeps working.
- **New firmware, old hub:** no `sart` frame ever arrives, so the device never allocates a buffer and
  never downloads. `DeviceCommand.parse` returns `nil` for an unknown `cmd`, so `sart_stat` is dropped.

---

## 3. Layout: 466x466, inset 40

Content box is x, y in **[40, 426]** — 386 x 386. `THEME_COUNT` is **1** (editorial), so there is
exactly one visual treatment to build, reading tokens like everything else.

### 3.1 Tile size: 200 x 200, fixed

Vertical budget, working down from the hairline the shipped screen already draws at y=104:

```
124 (tile top) + N (tile) + 20 (gap) + 38 (track, f_display 30) + 8 + 23 (artist, f_body 18) <= 426
=> N <= 213
```

**N = 200** — the largest round value inside that with 13 px of bottom slack. 200x200x2 =
**80,000 B**, a number that is easy to cap, easy to check for equality, and 1.0% of the 8.2 MB of free
PSRAM.

**Fixed, always, in both dimensions.** The hub aspect-fits the source into 200x200 and pads with pure
black. Padding is free on this panel: `bg` is `#000000` and those are AMOLED **off-pixels**, so
letterbox bars are physically invisible. Sources smaller than 200 px are upscaled by CoreGraphics; a
slightly soft tile is a better outcome than a protocol with variable dimensions and a device that must
centre an arbitrary WxH. Fixed dimensions are what make the device's buffer a compile-time constant
and its length check an equality rather than a range.

### 3.2 The art form

```
  40 ────────────────────────────────────────────────────── 426
  40   SONOS                                     [status]     <- f_mono 15; build_header(), unchanged
  74   KITCHEN                                    PLAYING     <- masthead row: room left (accent),
 104   ───────────────────────────────────────────────────       play state right (accent/ink_dim)
                                                                <- S.hairline, 386 x 1, unchanged
 124              ┌──────────────────────────┐
                  │                          │
                  │      200 x 200 tile      │               <- x 133..333 (centred: (466-200)/2 = 133)
                  │                          │                  y 124..324
 324              └──────────────────────────┘
 344   Black Hole Sun                                        <- f_display 30, width 386, LONG_DOT
 390   Soundgarden                                           <- f_body 18, width 386, LONG_DOT
 426 ──────────────────────────────────────────────────────
```

Checks:

- Tile centre x = 233 = 466/2. Every tile edge is >= 124 px from a panel edge — nowhere near a corner
  arc (`CORNER_R` 90).
- Track box y 344..382; bottom-left point (40, 382). Bottom-left arc centre (90, 376), r=90; distance
  sqrt(50^2 + 6^2) = 50.4 < 90, so the point is on the panel.
- Artist box y 390..413; point (40, 413) is 62.2 from (90, 376). On the panel. Bottom slack 13 px.
- Masthead's right-aligned play state ends at x=426 = 466-40, satisfying `DESIGN.md`'s rule that
  edge-spanning rows keep end content >= 40 px from the side edges.
- Vertical rhythm below the rule is 20 / 20 / 46 — multiples of 4 per the `space` token. The 34 and 30
  above it are phase 1's shipped spacing, kept because it is already on glass.

**Two changes from the shipped screen, both justified:**

1. **The play state moves from bottom-left to the masthead row**, right-aligned opposite the room.
   The tile needs the vertical space, and `KITCHEN ......... PLAYING` is a better editorial masthead
   than a stranded corner chip. It applies to **both** forms below, so the top 104 px of the screen is
   byte-identical whether or not there is art — which is what makes the switch read as quiet rather
   than as a jump.
2. **The album line is dropped when art is present.** It is the field the wire protocol itself already
   ranks last: `SonosFrame.shrink` trims `album` first, then `artist`, then `track`, then `room`
   (CONTRACT.md). And it is the one field the art itself usually shows. Demoting it is consistent with
   a decision this codebase already made, not an arbitrary sacrifice for space.

### 3.3 The no-art form

Used when the hub sent S2, when no `sart` has ever arrived, or when every fetch attempt has failed and
there is no previous tile. **It is phase 1's shipped layout, verbatim, plus the masthead change.**

```
  40   SONOS                                     [status]
  74   KITCHEN                                    PLAYING
 104   ───────────────────────────────────────────────────
 122   Black Hole Sun                                        <- f_display 30
 180   Soundgarden                                           <- f_body 18
 216   Superunknown                                          <- f_mono 15 (the album line returns)
       ...deliberate negative space...
 426
```

The two forms share the top 104 px exactly and differ only below the rule. A 200 px void above
stranded text would read as a missing element rather than as composition, which is why this is a
second form and not "the art form with the tile hidden".

**Both forms are built in `build()` as two containers; `update()` only toggles
`LV_OBJ_FLAG_HIDDEN`.** `views/CONVENTIONS.md` allows `update()` to change "text/values/show-hide" and
requires it to be "read-only w.r.t. layout", so re-aligning widgets per tick is not available. The cost
of two containers is ~6 extra LVGL objects out of the PSRAM pool — a few hundred bytes, once.

The `no_track` case (loading, or nothing playing in the room) is unchanged from
`sonos_editorial.cpp`: placeholders, no play-state claim, no tile.

### 3.4 Render cost

A tile change dirties 200x200 = 40,000 px. Against `docs/perf.md`'s measured full-screen figures
(217,156 px at ~49 ms render + 29.5 ms blit), that is **~9 ms render + ~5.4 ms blit ~= 15 ms on
Core 1, once per track** — roughly half of one full-screen blit. The tile spans ~5 of the 47-line
flush strips. Negligible; no reason to pause the carousel tick or suppress anything.

### 3.5 Out of scope: the Home complication

The `sonos` complication is one 62 px slot rendering shape B (icon + two lines,
`ui/comps/comp_sonos.cpp`). **It does not show art.** Stated explicitly so nobody wires a second
consumer of the tile buffer with a different lifetime.

---

## 4. Memory and lifecycle on the device

### 4.1 Byte budget

| Item | Bytes | Where | Note |
|---|---|---|---|
| Tile buffer A | 80,000 | **PSRAM** | `heap_caps_malloc(MALLOC_CAP_SPIRAM)` |
| Tile buffer B | 80,000 | **PSRAM** | the other half of the double buffer |
| `lv_img_dsc_t` + `lv_img` widget | ~320 | PSRAM | `LV_MEM_CUSTOM 1` routes the LVGL heap to PSRAM |
| Second (hidden) layout container | ~400 | PSRAM | §3.3 |
| Record fields (`gen`, `url[97]`, flags) | ~120 | `.bss` | internal, static, permanent |
| HTTP staging buffer | **0** | — | read **straight** from the socket into the PSRAM tile |
| mbedtls context | **0** | — | plain `WiFiClient` on the LAN; **no TLS on this hop** |
| lwIP socket + pbufs | ~4,000-8,000 | internal | transient, for the duration of one GET |
| **New PSRAM, permanent** | **~160,720 B** | | **1.9% of the 8.2 MB free** |
| **New internal heap, peak** | **~4-8 KB** | | transient; **0 B permanent** beyond ~120 B of `.bss` |

The internal-heap line is the whole point. `net.cpp:21` records the alternative in its own words: a
`WiFiClientSecure` costs *"a ~40-50KB mbedtls handshake"*. Against an observed since-boot minimum of
**46,428 B**, a TLS art fetch would be the single largest thing the device ever does, several times an
hour. A plain LAN `WiFiClient` costs a few KB of lwIP state. **This is the two-plane architecture
applied unchanged: the Mac does the credential-bearing, internet-facing, CA-validating work and hands
the device something dumb.**

Note also what is *not* here: unlike OTA, art needs no `fetch_scratch()` chunking. `Update.write()`
wants sector-aligned 4 KB feeds; a pixel buffer wants nothing. `WiFiClient::read(tile + off, n)`
memcpy's from lwIP's pbufs directly into PSRAM. **Zero staging bytes.**

### 4.2 Allocated once, freed never

Both buffers are allocated on the `sonos` screen's first `build()` and **never freed**. This is the
answer to "no leak across hundreds of tracks": **there is no allocation in the steady state, so there
is nothing to leak, and nothing to fragment the PSRAM heap.**

The rejected alternative — malloc/free per track — churns 80 KB per track, fragments PSRAM over a day
of listening, and introduces an allocation-failure path at the worst possible moment. 160 KB of an
8.2 MB pool is not worth that.

If the `sonos` page is not in the device's page list, `build()` never runs and **not one byte is
allocated**. A user who does not use Sonos pays nothing.

A single buffer was also rejected: downloading into the displayed buffer means a visible blank or torn
tile for the duration of every fetch, on a device whose entire value proposition is being glanceable.

### 4.3 The buffer swap — the only genuinely concurrent object here

The download runs on the **Core-0 fetch task**; rendering runs on **Core 1**. The buffers cannot go
through the DataStore by value, so they get an explicit protocol rather than a timing assumption:

1. The record carries `{gen, idx, seen_gen}` under the existing DataStore mutex. `idx` selects which
   buffer the `lv_img_dsc_t` points at.
2. **Core 0 only ever writes the buffer the record does *not* point at**, and publishes `(idx, gen)`
   only on a complete, length-verified download.
3. Core 1's 500 ms tick re-points `lv_img` when `gen` changes and writes back `seen_gen = gen`.
4. **Core 0 must not begin writing the back buffer until `seen_gen == published_gen`, or 3,000 ms
   have elapsed since the publish.** The timeout covers the case where the `sonos` page is not
   currently built — nobody will ever ack, and nobody is reading the buffer either, so proceeding is
   safe. When the page *is* built the tick is 500 ms and the ack always arrives first.

Rule 4 exists because "two tracks cannot change within one tick" is a timing assumption, and rapid
track changes are explicitly in scope. The default on any doubt is **do not start writing**. A torn
tile is otherwise a rare, unreproducible bug.

**Coupling to note:** if the crossfade in §9 Q2 ever ships, both tiles are read during the transition,
so `seen_gen` must be written at **crossfade end**, not at swap start.

### 4.4 Rapid track changes

Art is a **latest-wins** value, unlike an OTA which must complete. The fetch task holds **at most one**
art job; a newer `gen` replaces the pending job, and if a download is already running it sets an abort
flag checked on every socket read. The abandoned `gen` emits **no** `sart_stat` — matching the "silent
withdraw" precedent in CONTRACT.md §D, where a prompt resolved elsewhere is cleared with no claim made
about it.

On the hub side, **debounce: do not arm or publish for a tile that has been current for less than
2 s.** With the current 5 s poll this is a no-op, which is exactly why it should be written down now —
so a future faster poller does not turn a scrub through a playlist into twenty listener arms.

### 4.5 Where the work runs

`hub_task` (Core 0, 20 ms loop) parses `sart` and records the pending job. `fetch_task` (Core 0,
1,000 ms loop, 8 KB stack) performs the GET. **The download must never run on `hub_task`** — an 8 s
worst case there would stall permission-prompt round trips, which the 20 ms loop exists to keep snappy.
It must never run on Core 1 for the obvious reason. Latency: <= 1 s of queueing plus ~0.3 s of transfer,
so art lands within ~1.5 s of the frame.

Deadlines, an order of magnitude tighter than OTA's because the payload is 22x smaller and the user is
looking at the screen: **connect 3 s, per-read idle 3 s, overall hard abort 8 s.**

### 4.6 Not persisted

The tile is never written to NVS. It is 80 KB of per-track content on a link that reconnects in
seconds; persisting it would be a flash write per track for no benefit. On (re)connect the hub
re-publishes (§5), which is cheaper and always correct.

---

## 5. Caching and change detection

The provider polls every 5 s (`SonosProvider.interval`). Art must not move on every tick.

**What identifies "same art" is the tile's bytes, not its URL.** Cloud services mint art URLs with
expiring signatures, so the same album can produce a different URL string on consecutive polls — and
conversely a station can serve one generic URL for every track. Keying on the URL alone gets both cases
wrong.

Two levels:

1. **URL level (cheap, first).** If the Sonos `imageUrl` is byte-identical to the last one processed,
   stop. No HTTPS GET, no CoreGraphics, no BLE frame, no device work. This kills the common case at
   zero cost, and the common case is ~99% of ticks.
2. **Tile level (correct, second).** If the URL changed, fetch and rasterise, then SHA-256 the
   resulting 80,000 bytes and compare against the last published tile's digest. **Equal digest =>
   no new `gen`, no arm, no frame.** This is what makes an expiring-signature URL cost one HTTPS GET
   instead of a BLE frame plus a device download plus a screen repaint.

`gen` increments **only** on a tile-digest change, so the device only ever downloads when the pixels
actually differ.

**What invalidates the cache:**

| Trigger | Effect |
|---|---|
| Tile digest differs from the last published | new `gen`, arm, S1 |
| `imageUrl` absent / fetch fails / decode fails | `gen`+1, **S2** (no url) — art cleared, explicitly |
| Followed room changes | `groupCache` is already dropped by `setSelectedRoom`; next tick re-resolves and almost certainly re-publishes |
| **BLE (re)connect** | **re-arm with a fresh token and re-push S1 with a fresh `gen`** |
| Hub relaunch | in-memory cache is gone; first poll republishes |

The reconnect rule is not optional. The device's tile lives in RAM, so a rebooted device has none, and
the hub cannot tell a reconnect from a reboot. The previous token is single-use and expired anyway.
This mirrors how `sessions` / `sdetail` / `sonos` are all re-sent on (re)connect.

---

## 6. Where the art comes from

### 6.1 Sonos already returns it; this repo does not read it yet

`SonosAPI.parsePlaybackMetadata` (`hub/Sources/beacon-hub/SonosAPI.swift:67-76`) decodes
`currentItem.track.name`, `.artist.name`, `.album.name`, with a fallback to `container.name`. **It
decodes no image field, and `imageUrl` appears nowhere in this tree.** So new decoding is required —
but it is *one field in an existing fixture-tested pure parser*, on an endpoint already being called
every 5 s. **No new request, no new scope, no new endpoint.**

The Sonos Control API carries art on `playbackMetadata` at `currentItem.track.imageUrl`, with
`container.imageUrl` as the station/playlist fallback — the same currentItem-then-container precedence
`parsePlaybackMetadata` already implements for the *name*:

```
imageUrl = currentItem.track.imageUrl ?? container.imageUrl
```

plus one field on `TrackMetadata`. That is the entire Sonos-side change, and it is the cheapest part of
this project. It is also the part that must be verified against a live capture **first** (§8 Phase A,
§10 risk 1).

### 6.2 Fetching it does not need the OAuth credential — and must not use it

Two cases, and the distinction is a security rule, not a detail:

- **Cloud-service art.** `imageUrl` is an absolute `https://` URL on the *music service's* CDN. It is
  fetched with **no** authentication. The hub **must not** send its Sonos `Authorization: Bearer`
  header to a host named by a third-party JSON field — that is a credential leak by redirect.
  **`SonosProvider.api()` must not be reused for this**: it unconditionally attaches the bearer token
  (`SonosAPI.swift` caller, `SonosProvider.swift:251`). The art fetch is a bare `URLSession` GET on its
  own path.
- **Local library / some services.** `imageUrl` can be `http://<player-ip>:1400/getaa?...` on the LAN.
  Also unauthenticated, also plain HTTP, and only reachable when the Mac is on the player's network.
  Fine — it is the user's own speaker and the result is pixels.

In both cases **no credential leaves the Mac and none reaches the device.** The device only ever sees
80,000 bytes of RGB565 from `LanAssetServer`. The `AGENTS.md` invariant holds unchanged, and so does
`SonosProvider`'s stronger local rule that *provider JSON* never crosses its boundary either — the art
URL stops at `SonosArtRenderer`.

### 6.3 Hardening the art fetch

Art URLs are untrusted input from a third party's JSON:

- Scheme must be `http` or `https`. Reject `file:`, `data:`, everything else.
- Cap the download at **4 MB**; abort past it.
- **5 s timeout.**
- Do not follow a redirect to a non-`http(s)` scheme.
- Decode via `CGImageSource` / `NSImage`, never a hand-rolled parser.
- On any failure: publish **S2**, not silence. The device must be told the art is gone.

---

## 7. Security

**By reference: the model is `docs/specs/2026-07-27-ota-updates-design.md` §7, unchanged.** Separate
listener from `LocalIngestServer` (whose 127.0.0.1 binding and POST-only routing stay untouched);
GET-only on `/a/<32-hex>`; ephemeral port; 128-bit single-use token from `SecRandomCopyBytes` compared
in constant time; source-address restriction to the device's reported IP plus an RFC1918/link-local
check; `NSLocalNetworkUsageDescription` (P-1). No device authentication — the device does not need to
prove its identity to fetch a picture, and the direction that matters (integrity) is handled in §2.3.
None of that is re-argued here.

### 7.1 What frequency changes, and it is the only thing

OTA arms the server roughly **once a month, for up to 600 s**. Album art arms it roughly **once per
track**. That is a real change in duty cycle and it deserves a number rather than a shrug:

| | Arms | Window each | Armed time |
|---|---|---|---|
| OTA | ~1 / month | 600 s | **~600 s / month** |
| Album art, as specified below | ~20 / listening-hour | 30 s | **~600 s / listening-hour** |

Roughly a 700x higher duty cycle. The *shape* of the exposure is identical — a handler that does a
constant-time 32-hex compare and writes a fixed-length buffer — but the duty cycle is not, so art
takes three tightenings, each strictly tighter than OTA's setting:

1. **TTL 30 s, not 600 s.** OTA's window is sized for a human deciding whether to tap Update. Art's
   window is sized for the transfer: 80 KB on a LAN is well under a second, and the device is told to
   fetch immediately.
2. **`maxServes: 1`, not 3.** OTA needs a retry budget because re-minting after a 40 s partial download
   is expensive. A failed art fetch is re-offered by the next poll with a fresh token at zero cost.
3. **Armed only while the `sonos` page is in the device's page list *and* the BLE link is up.** No
   Sonos page => the listener is never created, not once. This is a real gate, not a comment.

### 7.2 The divergence that would otherwise ship as a bug

**Album art must NOT take `NSProcessInfo.beginActivity(.idleSystemSleepDisabled)`.**

OTA's `arm()` path takes a sleep assertion for the transfer window so a sleeping Mac is
distinguishable from a WiFi drop (OTA design §9). Taking that assertion every three minutes, all day,
would **stop the user's Mac from ever sleeping** — a silent, user-hostile regression in an unrelated
part of the system, caused entirely by sharing a component.

The fix is structural: **the sleep assertion moves out of `LanAssetServer` and into the OTA caller.**
The server arms and serves; it does not manage power. This must be an acceptance item with a test
asserting the art path takes no assertion, because it is exactly the kind of thing a careful reviewer
reads past.

### 7.3 Residual risk, stated

- The Mac has an extra listening TCP socket for ~600 s per listening-hour. The handler's surface is a
  fixed string compare and a fixed-length write. **Never merge this into the hooks server**, which
  parses arbitrary JSON.
- Anyone who observes the token can download 80,000 bytes of album art. The loss is nil.
- Source-address restriction is spoofable on a hostile LAN. It raises cost; it is not a control.
- A LAN attacker who wins a race on the URL can put a different picture on a desk clock for one track.
  Accepted, and it is the reason §2.3 does not carry a digest.
- Because art arms far more often than OTA, the LAN listener should be described in the Settings copy
  the user can actually read, not only in this document.

---

## 8. Failure modes

| Failure | Behaviour | Why it is acceptable |
|---|---|---|
| **No art for this track** | Hub sends **S2**. Device clears the tile and switches to the no-art form (§3.3). Record stays `ST_LIVE`. | Not an error — the text is still true and complete. Explicit rather than silent, so a dropped frame can never be mistaken for it. |
| **Hub asleep / BLE link down** | `sonos_rec_t.hdr.state` -> `ST_HUB_OFFLINE` (existing). The tile **keeps showing the last art, dimmed** via `lv_obj_set_style_img_opa(LV_OPA_40)`, alongside the existing text dimming and the status chip. | `DESIGN.md`: *"Offline: ambient screens keep last-known with age."* Blanking would assert "nothing playing", which is a different and false claim. Opacity, not recolor: on a black canvas, reducing opacity toward black *is* dimming, at no extra draw pass. |
| **LAN fetch fails / times out** | Keep the previous tile. Emit `sart_stat ok:false err:{conn_refused,timeout,net}`. **No device-side retry.** The hub re-offers on its next tile change, or re-offers the same `gen` once after 60 s if it never saw an `ok`. | The download is on `fetch_task`, so a stall cannot hitch the UI. Retrying from the device would race the hub's 30 s TTL and the single-use token. |
| **TCC denied (P-1)** | Presents as `timeout` with zero bytes received — the shape the Local Network row keys off. Row goes `.bad` with a link to the Privacy pane. | This is the failure P-1 exists to make visible, and art exercises it many times a day instead of once a month. **Test the denied path, not only the granted one.** |
| **Partial download** | Device requires `200` **and** `Content-Length == 80000` before reading a byte, and exactly 80,000 bytes received before swapping. Short read => discard the back buffer, front buffer untouched, `err:"size"`. | **A torn tile is structurally impossible**: the write target is never the displayed buffer (§4.3). Nothing is shown that was not complete. |
| **Art larger than expected** | `Content-Length != 80000` => reject before allocating or reading, `err:"size"`. The read is additionally capped at 80,000 bytes regardless of the header, so a lying `Content-Length` cannot overrun. | The hub always rasterises to exactly 200x200, so any other size means something is wrong — which is when you want a hard rejection, not a best-effort partial blit. |
| **Device WiFi down when art changes** | Device answers `err:"no_wifi"` **without attempting a connect**, keeps the old tile. | BLE up + WiFi down is a real state here — the two planes are independent. It is the one case where the device knows art is impossible, and reporting it immediately keeps it distinguishable from a TCC denial. |
| **Rapid track changes** | Newest `gen` wins; in-flight download aborts on its next read; superseded `gen`s emit nothing. Hub debounces at 2 s. | §4.4. Art is latest-wins; there is no value in finishing a tile nobody will see. |
| **`sonos` page not in the page list** | Hub never arms and never sends `sart`; device never allocates. | Zero cost, zero listener, zero PSRAM for a user who does not use Sonos. |
| **Hub quits mid-transfer** | Listener dies with the process; the device's read stalls into `err:"timeout"`; old tile stays. | No state survives a failed transfer on either side. |
| **Two devices** | Out of scope — the hub pairs with one device. | Noted so it is not discovered later. |

---

## 9. Phasing

**Phase A — prove the art exists. Hub only. No device, no BLE, no LAN server.**
Extend `parsePlaybackMetadata` with `imageUrl` (+ fixture test), add `SonosArtRenderer` (fetch, decode,
aspect-fit to 200x200, convert to **big-endian** RGB565, SHA-256), and render the resulting tile as a
**live preview in the hub's Sonos settings section**.
*Useful alone, and it is the gate on everything else:* it answers "does the owner's Sonos actually
expose art for the services they use" with a screenshot instead of an argument. If `imageUrl` is empty
in practice, the project stops here having cost a day (§10 risk 1, §11 Q6).

**Phase B — `LanAssetServer` + P-1. The deliverable OTA is waiting on.**
The payload-agnostic listener exactly as OTA §2.1/§7 specifies, with **no OTA vocabulary anywhere in
the type**, plus `NSLocalNetworkUsageDescription`, the Settings **Local Network** row, and the
**denied-path test**. Its first real payload is the art tile. The sleep assertion stays out of it
(§7.2).
*Useful alone:* it unblocks OTA's WS-3 and fixes a latent silent-denial bug in the hub today.

**Phase C — the wire and the device.**
`sart` / `sart_stat` in `hub_proto.{h,cpp}`, `Protocol.swift`, `records.h` and `hub/CONTRACT.md`;
`net_lan_get()` — the plain-HTTP LAN GET on `fetch_task`, **which OTA's WS-2 later extends to stream
into `Update`**; the double PSRAM buffer and its ack rule; the two-form `sonos` screen layout.
*This is the phase that puts a picture on the glass.*

**Phase D — polish, driven by what C actually hurt.**
Dim-on-hub-offline if it did not land in C; the crossfade (Q2); the Settings toggle (Q4). Nothing here
is committed.

**Consequence for the OTA plan:** its Phase 0 shrinks (P-1 done) and WS-3's `LanAssetServer` and WS-2's
`net_lan` become extensions rather than new files. `docs/plans/2026-07-27-ota-updates-plan.md` should
be updated when this lands, not duplicated.

---

## 10. Risks, ranked

**1. The art may simply not be there. (Biggest — it is the only risk that can make the whole project
worthless, and it is the cheapest to retire.)**
Everything below rests on `currentItem.track.imageUrl` being populated for the services the owner
actually uses. **Nothing in this repo has ever read that field** — `parsePlaybackMetadata` does not
decode it, no fixture contains it, and there is no capture. Sonos returns art for most services, but
radio and podcast containers frequently carry only a station logo, and some services return nothing.
*Mitigation:* Phase A exists solely to retire this, with a live capture, **before** any LAN server,
wire format or device buffer is written. Do not reorder the phases.

**2. The sleep-assertion trap.** Reusing OTA's `arm()` path wholesale takes
`.idleSystemSleepDisabled` every few minutes and the user's Mac stops sleeping. A silent, user-hostile
regression in an unrelated subsystem, caused by sharing a component correctly in every other respect.
*Mitigation:* §7.2 — the assertion moves to the OTA caller, with a test asserting art takes none.

**3. Endianness.** `LV_COLOR_16_SWAP=1` means big-endian RGB565 in LVGL's memory; CoreGraphics' natural
16-bit output is little-endian. Get it wrong and every pixel's colour is scrambled — a failure
`docs/perf.md` §2.1 already documents for the blit path, and one that will be misdiagnosed as a broken
transport. *Mitigation:* the four-pixel byte-exact test on both sides (§1.4), written before the
renderer.

**4. The double-buffer swap.** 160 KB of PSRAM is cheap; the cross-core swap is the actual hazard and
the only genuinely concurrent object in this design. Get the ack rule wrong and the symptom is a rare,
unreproducible torn tile that no test will catch. *Mitigation:* §4.3's explicit rule, whose default on
any doubt is "do not start writing".

**5. LAN listener duty cycle.** ~600 s of armed listening per listening-hour against OTA's ~600 s per
month (§7.1). Mitigated to strictly-tighter-than-OTA on every other axis, but it is a genuine change to
the Mac's network posture and belongs in Settings copy the user reads, not only here.

**6. Frame-budget creep.** A future "simplification" that folds `art` into the `sonos` frame starts
trading the artist's name against the art URL inside a shrink loop with 22 B of headroom.
*Mitigation:* the reasoning goes into `hub/CONTRACT.md` beside the two places that already made the
same call for the same reason.

**7. It may just look wrong.** This is the first raster image in a product whose stated visual language
is *"type carries hierarchy; no boxes/cards"* and *"oversized tabular figures, hard hairline rules,
strict left-grid"* (`DESIGN.md`). A 200 px photographic square may sit badly next to Space Grotesk and
a hairline rule. *Mitigation:* Phase A's hub-side preview shows the tile before any firmware exists,
and Q1/Q5 below put the call with the owner rather than in this document.

---

## 11. Open questions

Each is genuinely open. My recommendation is marked **provisional** and is not a decision.

1. **Is 200x200 the right visual weight, and is dropping the album line when art is present
   acceptable?** *Provisional: yes to both* — 200 px is the largest tile the vertical budget allows
   with editorial rhythm intact, and the album name is the field the wire protocol itself already
   ranks last (§3.2). The counter-argument is that the album name is real information and a smaller
   tile (160x160) would keep it. **Not confirmed.**

2. **Crossfade or hard cut on a tile change?** *Provisional: hard cut in Phase C, crossfade as Phase D
   if it is missed.* Both tiles are already resident, so a 220 ms `dur` ease-out crossfade is nearly
   free and matches `DESIGN.md`'s motion tokens. But it extends the window in which both buffers are
   read, which couples it to §4.3's ack rule (`seen_gen` must then be written at crossfade *end*).
   Shipping the cut first keeps the concurrency simple while the swap protocol is new. **Not
   confirmed.**

3. **Should art appear in the Home `sonos` complication?** *Provisional: no.* A 62 px slot gives a
   ~48 px thumbnail, which is a smudge rather than a picture, and it would add a second consumer of
   the tile buffer with a different lifetime. The counter-argument is that Home is the screen people
   actually look at. **Not confirmed.**

4. **Is the LAN duty cycle acceptable, and should there be a Settings toggle to turn album art off
   (leaving text-only phase 1)?** *Provisional: yes to the duty cycle given the §7.1 tightenings, and
   yes to the toggle* — someone on a shared or corporate network may reasonably not want a listener
   opening every few minutes, and the fallback is a screen that already ships and works. The
   counter-argument is one more setting for a thing most users will never think about. **Not
   confirmed.**

5. **Aspect handling: letterbox non-square art into 200x200 black, or crop to fill?** *Provisional:
   letterbox* — the bars are literally invisible on an AMOLED black canvas, and cropping a
   wide station logo cuts its middle out. The counter-argument is that a filled square reads as more
   deliberate for the rare non-square case. **Not confirmed.**

6. **If Phase A finds `imageUrl` empty for the owner's services, is the local UPnP route worth
   revisiting — on the hub only?** The 2026-07-26 design's option (b) (`AVTransport` on port 1400,
   `GetPositionInfo` -> DIDL-Lite `albumArtURI`, no OAuth at all) was rejected because it put SOAP/XML
   parsing **on the device** against the shared 8 KB `fetch_scratch()`. **On the Mac that objection
   does not apply** — the hub has `XMLParser` and no memory constraint, and the device would still see
   only pixels. *Provisional: hold it in reserve, do not build it speculatively.* **Not confirmed, and
   it only becomes live if Phase A fails.**

---

## 12. Doc changes this implies

- `hub/CONTRACT.md` — a `sart` block beside the existing `sonos` block in §A (S1/S2, caps, the
  "absence never clears" rule, the no-escapable-characters property), and `sart_stat` in §B.
- `docs/codemap.md` §1 — hub -> device blocks gains `sart`; device -> hub commands gains `sart_stat`.
- `docs/recipes.md` — the "extend the BLE frame" recipe gains this as a worked example of a frame that
  needs **no** shrink loop, and why.
- `docs/perf.md` §3 — the measured PSRAM cost (160 KB) and the measured tile-change render/blit time,
  replacing §3.4's estimate.
- `DESIGN.md` §Components — the Sonos art tile as a component, with the two-form rule.
- `docs/plans/2026-07-27-ota-updates-plan.md` — Phase 0 loses P-1; WS-2/WS-3 extend `net_lan` and
  `LanAssetServer` instead of creating them.
