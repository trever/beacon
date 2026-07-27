# Hub as device controller + Sonos now-playing

**Status:** design, not yet built. Written 2026-07-26.

Two requests that share one mechanism:

1. The user picks **which pages** the device shows, **in what order**, and **customizes each** — from the
   hub, without reflashing.
2. A **Sonos now-playing** page (room, track, artist, album art) as the first page that proves the model.

## 1. What already exists (do not rebuild it)

The hub already configures the device at runtime. Ticker config (`docs/specs/2026-06-17-hub-ticker-config-design.md`,
`CONTRACT.md` §B2) is a **chunked, revisioned, NVS-persisted, acked** channel:

```json
{"v":1,"config":{"rev":7,"part":0,"parts":2,"tickers":[...]}}
{"v":1,"cmd":"config_ack","rev":7,"ok":true,"count":8}
```

It solves every hard part already: the 1024 B `HUB_FRAME_MAX` (chunking), idempotent re-sync on reconnect
(`rev`), device-side persistence (NVS), failure reporting (`ok:false,err`), and even **adoption** — a
pristine hub takes on the list the device already holds instead of clobbering it.

**Page config should be a second instance of this exact pattern, not a new mechanism.**

## 2. Page configuration

### Device: `MODULES` becomes a registry

Today `carousel.cpp` has a fixed array and a `#define BUDDY_INDEX`. That index has been wrong or moved
**four times** in this repo's history (3→4 for ICE, 4→5 for the graph, 5→4 dropping usage, 4→3 hiding
markets). A registry keyed by a stable string id kills that entire bug class:

```c
typedef struct { const char* id; const screen_module_t* mod; } page_entry_t;   // id is the wire contract
static const page_entry_t REGISTRY[] = {
  {"home", &home_module}, {"markets", &finance_module}, {"chart", &chart_module},
  {"ice", &ice_module},   {"agents", &buddy_module},    {"sonos", &sonos_module},
  {"settings", &settings_module},
};
```

Screens stay **compiled in**; the hub only selects and orders them. Flash is 55.8% of 3 MB, so carrying
every screen costs nothing we have, and pushing actual layouts over BLE would be a different (much worse)
project. `carousel_goto_buddy()` becomes a lookup by id, and `settings` is pinned last and non-removable
so the device can never be configured into a state with no way back.

Cap: 8 pages (`s_pages[8]`/`s_dots[8]` already fixed at 8) — enforce it device-side and report
`err:"too_many_pages"` rather than truncating silently.

### Wire shape (additive, mirrors §B2)

```json
{"v":1,"pages":{"rev":3,"part":0,"parts":1,"list":[
  {"id":"home"},
  {"id":"chart","opts":{"symbol":"sp500","interval":"15m"}},
  {"id":"sonos","opts":{"room":"Kitchen"}},
  {"id":"agents"}]}}
{"v":1,"cmd":"pages_ack","rev":3,"ok":true,"count":4}
```

`opts` is a small per-page bag the owning screen validates and persists; unknown ids and unknown `opts`
keys are **ignored, not rejected**, so an older device stays usable against a newer hub. Each screen
declares its own option schema — that keeps the config generic while letting the chart page own
`symbol`/`interval` and Sonos own `room`.

### Hub UI

A SwiftUI list: drag-to-reorder enabled pages, a disabled pool below, and a detail form per page driven by
its declared schema. Bumps `rev` on every apply; the existing reconnect resend path carries it.

## 3. Sonos now-playing

### The conflict to settle first

The request says *"the device just has the requisite authentication to call out to the sonos apis."* That
contradicts this repo's stated invariant (`AGENTS.md`, `docs/tech.md`): **credentials never reach the
device** — it is the reason the two-plane architecture exists, and why usage was normalized to
percentages instead of shipping a token. A Sonos refresh token in NVS on a desk device would be the first
crack in that boundary, and NVS is not encrypted here.

Two ways to get now-playing without breaking it:

- **(a) Hub proxies (recommended).** The hub does the OAuth (it already holds credentials in Keychain),
  polls/subscribes to the Sonos Control API, and pushes a **normalized** block over BLE:
  `{room, track, artist, album, playing, art}`. No credential on the device, works off-LAN, and it is the
  same shape as every other hub-fed record.
- **(b) Device uses the local LAN API.** Sonos players answer UPnP `AVTransport` on port 1400
  (`GetPositionInfo` → DIDL-Lite with `albumArtURI`), needing **no OAuth at all**. Tempting, but it puts
  SOAP/XML parsing on the device against the shared 8 KB `fetch_scratch()`, and Sonos keeps pushing
  integrations cloud-ward.

Recommendation: **(a)** for metadata.

### Album art is the real engineering problem

Text fits a single BLE frame trivially. Art does not. Numbers for a 160×160 tile on the 466×466 panel:

| transport | bytes | realistic time |
|---|---|---|
| RGB565 raw over BLE, base64 in JSON frames | 51 KB → ~68 KB encoded, ~70 frames | **15–30 s per track** |
| 96×96 RGB565 over BLE | ~18 KB → ~24 KB encoded | ~6–9 s |
| Device fetches a URL over WiFi (JPEG) | 5–20 KB compressed | **< 1 s** |

BLE here is newline-delimited JSON at `HUB_FRAME_MAX` 1024 B over a 247-byte MTU, sharing the radio with
everything else — it is the wrong pipe for images. So:

**Phase 2 answer: the hub fetches and downscales the art, then serves it over the LAN, and the device
fetches it by URL.** The hub already runs an HTTP server (`127.0.0.1:8765`); bind an art route on the LAN
interface with an unguessable path, and send the device only that URL. No Sonos credential leaves the
Mac, no BLE bottleneck, and the device's existing TLS/HTTP fetch path does the work. On-device decode
targets **PSRAM** (8.2 MB free) — never internal heap, whose watermark already runs ~46 KB.

Note this means art requires the Mac awake and on the same network. That is already true of every
hub-fed page.

### Phasing

- **Phase 1 — text only.** `sonos` page + registry + page config. One BLE block, no art, no new device
  fetch path. Proves the whole controller model end to end.
- **Phase 2 — album art** via the hub-served LAN URL + PSRAM JPEG decode.
- **Phase 3 — transport controls** (play/pause/next) reusing the existing device→hub `cmd` channel, which
  already carries `permission` and `open`.

## 4. Risks

- **Memory.** Internal-heap watermark is ~46 KB against a documented ~53 KB floor. Any art work is
  PSRAM-only, and the decoder must be measured, not assumed.
- **Lockout.** A bad page list could leave no settings page. Pin `settings`, and keep a device-side reset.
- **Frozen protocol.** `pages` is additive and ignorable, so an upstream (`angaziz/beacon`) merge stays
  clean — same discipline as `sdetail`.
