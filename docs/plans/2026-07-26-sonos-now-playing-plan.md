# Plan: Sonos now-playing page (phase 1, text only)

**Status:** open. Written 2026-07-26. Self-contained — assumes no prior session context.
**Design:** `docs/specs/2026-07-26-hub-as-controller-and-sonos-design.md` §3 — read it first.

## Goal

A `sonos` page on the device showing the room, track, artist, album and play state. Album art is
explicitly **out of scope for phase 1** (see below).

## Credentials — read this before anything else

- The user's Sonos **client secret was pasted into a chat transcript on 2026-07-26 and must be treated as
  compromised.** Confirm it has been rotated in the Sonos developer console before wiring anything up.
- **Never** put the secret in the repo, a source file, a test fixture, a commit message, or a log line.
  This repository is public.
- Store it in the **macOS Keychain**, set via a `set-sonos-secret` subcommand on `beacon-hub` that reads
  from **stdin, never argv** — argv leaks to `ps` and shell history. Copy the existing pattern:
  `hub/Sources/beacon-hub/main.swift` already does exactly this for `set-claude-token`, including
  validating length and echoing only a character count.
- The client **ID** is not secret and may live in source or config.

## The architectural rule this must not break

`AGENTS.md` and `docs/tech.md` state it plainly: **credentials never reach the device.** That is why AI
usage was normalized to percentages rather than shipping a token, and NVS on the device is not encrypted.

So: **the hub holds the OAuth and pushes normalized now-playing over BLE.** The device gets
`{room, track, artist, album, playing}` and never sees a token. The user agreed to this approach on
2026-07-26 after it was raised.

## Why not album art in phase 1

BLE here is newline-delimited JSON capped at `HUB_FRAME_MAX` (1024 B, defined in
`firmware/src/core/hub_proto.h`) over a 247-byte MTU, shared with everything else. A 160×160 RGB565 tile
is ~51 KB raw, ~68 KB base64 — roughly 70 frames, **15–30 s per track change**. Unusable.

The phase-2 answer in the design doc: the hub fetches and downscales the art, serves it on the LAN from
the HTTP server it already runs (`LocalIngestServer`, currently `127.0.0.1:8765`) behind an unguessable
path, and sends the device only a URL to fetch with its existing TLS/HTTP path. Decode into **PSRAM**
(8.2 MB free) — never internal heap, whose watermark runs ~50 KB against a ~53 KB floor.

## Steps

### Hub

1. `set-sonos-secret` subcommand (stdin, Keychain) mirroring `set-claude-token`.
2. OAuth against the Sonos Control API: authorize + token exchange + refresh. Follow
   `ClaudeTokenRefresher.swift` for the refresh idiom and `ProviderCredentials.swift` for Keychain shape.
3. A `SonosProvider` that resolves the household/groups, lets the user pick a **room**, and polls or
   subscribes for playback metadata. Normalize to a small struct; do not leak provider JSON upward.
4. Classify failures with the existing `ProviderOutcome` vocabulary. **A 403/401 that cannot succeed for
   this credential must be `.terminal`, not `.transient`** — a retry loop against an endpoint that
   structurally cannot answer is what earned an hour-long 429 from Anthropic in #7. Terminal outcomes
   must also gate the next poll (see `ClaudeCodeProvider.noteUsageOutcome`).
5. New BLE frame `{"v":1,"sonos":{…}}`, additive and ignorable by old firmware. Document it in
   `hub/CONTRACT.md` beside `sdetail`. Cap every string and assert a worst-case frame under
   `HUB_FRAME_MAX` **with pathological escaping** — track and artist names are free-form text where one
   `"` costs two bytes and an emoji four. `SessionDetailsFrame` already implements measure-and-shrink;
   reuse that approach rather than trusting character caps to bound bytes.
6. Send on change and on (re)connect, exactly like `sessions`/`sdetail` in `AppDelegate`.

### Device

7. `sonos_rec_t` in `firmware/src/core/records.h`, parser in `hub_proto.cpp` + native tests in a new
   `firmware/test/test_sonos/`.
8. `screen_sonos.{h,cpp}` plus a `sonos_editorial.cpp` view under `ui/screens/views/`. Read
   `firmware/src/ui/screens/views/CONVENTIONS.md` first — views must export
   `extern const screen_view_t` (namespace-scope `const` is internal linkage in C++ and will fail to
   link), and content is inset ≥40 px on the 466×466 panel.
9. Register it in `REGISTRY` in `firmware/src/ui/carousel.cpp` with id `"sonos"`.

### Hub UI

10. Add `sonos` to `PageCatalog.all` in `hub/Sources/BeaconHubKit/PageConfig.swift` so it appears in the
    page designer, and give it a `DevicePreview` sketch in `DevicePreview.swift`.
11. Room selection is a per-page option (`opts["room"]`). The `opts` plumbing is already end to end;
    `chart.sym` is the worked example.

## Pitfalls already paid for

- **Applying a page list restarts the device**, and the hub re-pushes on every reconnect. The device is
  idempotent about this now (#14) — do not regress it.
- Unknown page ids are **dropped, not rejected**, so a hub that knows `sonos` before the firmware does
  degrades quietly.
- The hub is a Mac that sleeps; a hub-fed page goes stale when it does. That is already true of Agents.

## Verification

- `cd hub && swift build && swift test` (271 tests as of 2026-07-26).
- `cd firmware && ~/.beacon-pio/bin/pio run -e beacon && ~/.beacon-pio/bin/pio test -e native` (242).
- Flash with `--upload-port /dev/cu.usbmodem101`; auto-detect picks the Bluetooth port and fails.

## Definition of done

- Room, track, artist, album and play state on the device, updating as playback changes.
- No Sonos credential anywhere outside the Mac's Keychain; nothing secret in the repo or in logs.
- The page is selectable and orderable in the designer like any other, with room as its option.
