# hub/CONTRACT.md — recorded fixtures (P2-0)

> The shared fixture set so the device codec (`firmware/.../core/hub_proto.cpp` + `test_hub_proto`)
> and the hub (`BeaconHubKit` + its tests) are tested against the **same** payloads (`tech.md` §7.3).
>
> **Status:** the **device-facing frame + commands (§A/§B) are FROZEN** in `tech.md` §7.1 and final.
> The **upstream shapes (§C) are RECORDED** — §C.1/§C.2 are real, token-redacted captures from the
> owner's Mac (2026-06-11) and §C.3/§C.4 are confirmed against the Claude Code v2.1.x docs. The P2-0
> draft guesses matched the live shapes on every field the normalizer reads. Nothing here may contain
> a real token.

## A. Hub -> device status frame (FROZEN, `tech.md` §7.1)

Newline-delimited JSON, `"v":1`. `usage` and `buddy` are independently optional (send what changed;
the device keeps an absent block's last values). A null/omitted window `pct` => unavailable ("--").

```json
{"v":1,"usage":{"providers":[
  {"id":"claude","label":"CLAUDE","h5":{"pct":24,"reset":1717600000},"d7":{"pct":24,"reset":1717800000},"stale":true},
  {"id":"codex","label":"CODEX","h5":{"pct":1,"reset":1717590000},"d7":{"pct":29,"reset":1717800000}}]},
 "buddy":{"running":2,"waiting":1,"tokens":184502,"context_pct":42,
          "entries":["10:42 git push","10:41 yarn test"],
          "prompt":{"id":"p07","agent":"claude","tool":"Bash","hint":"rm -rf /tmp/build","qlen":2}}}
```
- Absent `buddy.prompt` => idle. `pct` is an integer 0..100 or JSON null (device reads null/absent as -1).
- The device codec (`hub_parse_status`) + `test_hub_proto` assert exactly this shape.
- `usage.providers` (**BREAKING**, design 2026-07-19, clean cutover from the old fixed
  `usage.{claude,codex}` slots) -- 0..4 entries, one per usage-toggle-ON provider, in hub display
  order. Each entry: `id` (stable lowercase ascii, <=12 chars), `label` (display string, <=10 chars,
  uppercase preferred), `h5`/`d7` windows, and optional `stale`. The device renders provider labels
  from the record instead of hardcoding "claude"/"codex"; usage themes show the first 2.
- `usage.providers[].stale` (additive `v:1` ext, issue #108) -- `true` => the windows carry
  last-known-good the hub held through a transient failure (e.g. Claude oauth 429); the device dims that
  provider's windows. Emitted ONLY when `true` (absent/`false` => live), like `qlen`. Per-provider,
  independent.
- **Migration:** this is a breaking change to the `usage` block only. Old firmware fails to parse the
  new `providers` array and shows usage unavailable ("--"); flash matching firmware (the web flasher
  makes this trivial). `buddy`/`loc`/`sessions` are unaffected.
- `buddy.prompt.qlen` (additive `v:1` ext, issue #98) -- total pending prompts incl. the shown front.
  Omitted or `<=1` => a single prompt (no `(1 of N)` badge). The device always shows the front;
  position is implicitly 1, so there is no `qpos`.

Optional `loc` block (additive `v:1` extension, issue #54). The hub sources lat/lon + `name` from
macOS CoreLocation/CLGeocoder and `tz` from `TimeZone.current`. Independently optional, like
`usage`/`buddy`; parsed by `hub_parse_loc`. Sent ONLY in the (re)connect full frame and in a
loc-only frame on meaningful (> ~0.01 deg) change — **never** on the 30s heartbeat.

```json
{"v":1,"loc":{"lat":37.76,"lon":-122.42,"tz":"America/Los_Angeles","name":"Mission, San Francisco"}}
```
- Device precedence: hub `loc` > cached NVS > IP geolocation; a hub fix is never overwritten by IP.
- Permission denied / no fix => the hub omits `loc` and the device keeps its IP-based place name.

Optional `sessions` block (additive `v:1` extension, issue #110). A **standalone** frame — NOT embedded
in `buddy`: the combined `usage`+`buddy`+`loc` status frame already nears `HUB_FRAME_MAX` (1024 B), and a
session array would push it over (silently dropped). A separate frame keeps the budget independent and
lets old firmware ignore it while still reading the unchanged `buddy`/`entries` block. The hub emits it
on any session-state change and on (re)connect; parsed by `hub_parse_sessions` into `buddy_rec_t.sessions[]`.

```json
{"v":1,"sessions":[{"id":"s3","agent":"claude","label":"beacon · fix/109","state":"attention","ts":1719400000},
                   {"id":"s1","agent":"codex","label":"api · main","state":"working","ts":1719399860}]}
```
- Newest-first (hub-sorted by last update). **Frozen caps** (worst case asserted < 1024 B): `sessions`
  length ≤ **5**; `id` ≤ **6** chars (`s` + monotonic counter, wraps mod 100000); `label` ≤ **28** chars
  (`folder · branch`; default branches `main`/`master` dropped); `state` ∈ {`working`, `waiting`,
  `waiting_queued`, `attention`, `question`, `idle`}; `ts` epoch seconds. Unknown `state` => `working`
  (device). `question` = the session is waiting on the user's input (from the CC `Notification` hook);
  the device surfaces it as a "tap to answer on Mac" takeover (priority: permission prompt > question >
  list). The device renders up to 4 rows on the `claude` screen.
- `agent` (additive `v:1` ext, design 2026-07-19) = the owning provider id. Optional on the wire
  (omitted when nil), always emitted by the new hub; the device stores it (cap **12** chars) and may
  ignore it for now. Also carried on `buddy.prompt.agent` (same semantics). `buddy.running`/`waiting`
  count across all buddy-enabled providers; `tokens`/`context_pct` come from whichever provider reports
  metrics (0 otherwise). Session `sN` + prompt `pN` ids stay hub-minted, globally unique across
  providers; device `permission`/`open` commands are unchanged and the hub routes them to the owner.
- Migration: `buddy.entries` stays emitted/legal for back-compat; new firmware reads `sessions` and
  ignores `entries`, old firmware ignores the unknown `sessions` frame. No version bump.

Optional `sdetail` block (additive `v:1` extension). A **standalone** frame, joined to `sessions` by
`id`, carrying what a human needs to recognise a session: the repo, its title, and the newest message.

```json
{"v":1,"sdetail":[{"id":"s3","project":"beacon","title":"graph screen","msg":"on it, starting with the chart"}]}
```

- Sent whenever the detail set changes, and on (re)connect after the `sessions` frame. Emitted in the
  same order as `sessions` (the hub derives it *from* that list, so the two can never disagree).
- Caps: `sdetail` length ≤ **4** (one per rendered session row); `project` ≤ **20** chars; `title` ≤ **28**;
  `msg` ≤ **48**. Absent fields are omitted, not null. A row with no content at all is not sent.
- **Why a separate frame rather than new fields on `sessions`:** the `sessions` caps above are frozen,
  and title+msg would take its 5-row worst case to ~987 of the 1024 B ceiling *before* JSON escaping.
  `msg` is free-form human/model prose, where one `"` costs two bytes and an emoji four — a quote-heavy
  message would push the frame over `HUB_FRAME_MAX` and the device would silently drop the whole thing.
- Char caps therefore do **not** bound bytes. The hub encodes, measures, and trims the longest `msg`
  (then `title`) one character at a time until the frame fits, so the ceiling holds for any input;
  trimming is by Character, never by byte, so a multi-byte scalar is never split into invalid UTF-8.
- `project` is the repo name, recovered from the transcript's directory name rather than `cwd`: `cwd`
  follows the agent into subdirectories, so a session rooted at `beacon` reads `hub` after a `cd hub`.
- Old firmware ignores the unknown frame; new firmware treats absent detail as "no content yet" and
  falls back to the `sessions` `label`. No version bump.

## A2. Hub -> device page config (additive, design `docs/specs/2026-07-26-hub-as-controller-and-sonos-design.md`)

Which screens the device shows, and in what order. Persisted in NVS and applied by the device; the page
set is no longer compiled in. Parsed by `hub_parse_pages`, encoded by `BeaconHubKit/PageConfig.swift`.

```json
{"v":1,"pages":{"rev":3,"list":[{"id":"home"},{"id":"chart","opts":{"symbol":"sp500"}},{"id":"agents"}]}}
{"v":1,"cmd":"pages_ack","rev":3,"ok":true,"count":4}
{"v":1,"cmd":"pages_ack","rev":3,"ok":false,"err":"too_many_pages"}
```

- **Single frame, not chunked.** 8 ids cost ~200 B against `HUB_FRAME_MAX` (1024), so the ticker
  config's chunking would be dead weight. If `opts` ever outgrows the frame, chunk it exactly like §B2.
- Caps: `list` length ≤ **8** (`PAGES_MAX`); `id` ≤ **11** chars. `rev` is a monotonic hub counter,
  echoed in the ack; a stale ack (for a rev the user has since edited past) is ignored.
- `opts` is a small per-page bag of **scalar** values (string/int/bool). The device flattens it to a
  compact `k:v;k:v` string and stores it with the page; nested objects/arrays are skipped rather than
  half-encoded. Keys/values must not contain `: ; | = ,` — both ends strip them, so a value can never
  split a stored record. Unknown keys are kept but ignored by whichever screen owns the page.
- Options in use today: `chart.sym` = a **ticker id** from the §B2 list (not a raw symbol), so the device
  resolves the Yahoo symbol and display name from that row. Non-Yahoo or unknown ids fall back to the
  compiled default. The chart interval is deliberately NOT an option: the response must fit the shared
  8 KB `fetch_scratch()`, where 5m measured 7789 B against 15m's 3449 B.
- Ids are the device's `REGISTRY` in `firmware/src/ui/carousel.cpp`, mirrored by `PageCatalog`:
  `home`, `markets`, `chart`, `ice`, `agents`, `settings`.
- **Unknown ids are dropped, not rejected**, so a hub ahead of its firmware degrades quietly instead of
  stranding the device on an old page set. Duplicates collapse to their first occurrence.
- **`settings` is force-appended when missing** (evicting the last entry if the list is full): no
  configuration may leave the device unable to reach its own settings.
- An empty or fully-unknown list falls back to the shipped default rather than a blank carousel.
- `err` ∈ {`malformed`, `too_many_pages`, `empty`}.
- **The device acks and then RESTARTS** to rebuild the carousel, so the link drops immediately after the
  ack — an ack lost to the reset is normal. Rebuilding the pager's children live would mean tearing down
  LVGL objects under a running render loop, and a page-set change is rare enough that ~5 s of reboot is
  the safer trade. The hub therefore never pushes while pristine (`rev` 0), or for a no-op edit.

## A3. Hub -> device complication config (additive, design `docs/specs/2026-07-27-hub-app-and-home-complications-design.md` §4/§6)

Which small renderers ("complications") occupy a face's slot grid, and in what order. Home is the only
face today: six slots on a 62 px pitch, the clock spanning two. Persisted in NVS (`c_home`) and applied
by the device **live, with no restart** — the load-bearing difference from §A2. Parsed by
`hub_parse_comps`, encoded by `BeaconHubKit/Complications.swift`.

```json
{"v":1,"comps":{"rev":1,"slots":{"home":["clock","fin.sp500","ice","agents"]}}}
{"v":1,"cmd":"comps_ack","rev":1,"ok":true,"count":4}
{"v":1,"cmd":"comps_ack","rev":1,"ok":false,"err":"malformed"}
```

- **Single frame, not chunked.** The worst case (2 faces × 6 one-slot entries at max length) is 437 B
  against `HUB_FRAME_MAX` (1024) — 42.7%. If `comps` ever outgrows the ceiling it chunks exactly like §B2;
  nothing here forecloses that.
- Caps: `slots` carries at most **2** faces (`COMP_FACES_MAX`; only `"home"` exists); per face, up to
  **6** entries (`COMP_SLOTS_MAX`) — but capacity is in **slot units**, not entry count, since the clock
  costs 2. Each entry is `id` (≤ **11** chars) or `id.arg` (`arg` ≤ **15** chars); `.` is the only
  separator. Charset for both `id` and `arg`: `[a-z0-9_-]` — no character in it is JSON-escapable, so
  character caps bound bytes exactly (unlike `SessionDetailsFrame`'s free-form text fields, this frame
  needs no encode-measure-shrink loop). `rev` is a monotonic hub counter, echoed in the ack; a stale ack
  (for a rev the user has since edited past) is ignored, exactly as `pagesAck`/`configAck` already are.
- `count` in the ack is **placements applied, not slot units** — 4 placements can occupy 5 slots when one
  of them is the clock.
- The catalog (`COMP_CATALOG` in `core/complications.cpp`, mirrored by `ComplicationCatalog` in
  `BeaconHubKit`) is the **single** home of each id's `size` (1 or 2 slot units) and `takesArg`. Neither
  lives on the device's LVGL-coupled renderer registry (`ui/comps/comp_registry.h`) nor is re-derived by
  the hub UI — a fact duplicated in a second place is a fact that drifts.

  | id | size | takes arg | owning page |
  |---|---|---|---|
  | `clock` | 2 | no | *(core)* |
  | `fin` | 1 | yes (ticker id) | `markets` |
  | `ice` | 1 | no | `ice` |
  | `agents` | 1 | no | `agents` |
  | `usage` | 1 | yes (provider id) | `agents` |
  | `weather` | 1 | no | *(core)* |
  | `sonos` | 1 | no | `sonos` |
  | `chart` | 2 | yes (ticker id) | `chart` — **Phase 2**: no Phase 1 firmware answers a renderer for it |

- **Resolution rules** (device `comp_list_resolve`, pure + host-tested): an unknown id is dropped and the
  remaining entries compact upward; duplicate ids collapse to the **first** occurrence regardless of arg
  (one instance per id — Home can show exactly one ticker, one usage provider, one sparkline); an entry
  that does not fit the remaining slot units is dropped and the walk **continues** (a later 1-slot entry
  may still place where an earlier 2-slot one did not — never degraded to a smaller size); over capacity
  the tail truncates (`err` has no `too_many_slots` — over-cap is not an error). `owner` above is **hub
  metadata only** — the device never consults it, so a complication survives its owning page being
  hidden or disabled. The general rule: **a complication may only read a record the device already
  maintains for reasons independent of the page list; a complication must never be the thing that causes
  a fetch.**
- **Explicitly empty vs. everything-unknown** (rule the pages frame does not need): an explicitly empty
  request (`"home":[]` on the wire) is honoured and resolves to zero placements — a legitimate, if
  austere, blank face (the hub warns before sending it). A **non-empty** request that resolves to zero
  (every entry was unknown/invalid/didn't fit) falls back to the compiled default instead. The device
  distinguishes these by whether the wire array itself was empty, not by the resolved count — a request
  of several unknown ids also resolves to zero and must behave differently.
- **A face this frame does not carry is not an error** — the one place this parser's shape diverges from
  `hub_parse_pages`: an absent `"list"` there is malformed, but an absent face key here means the frame
  simply has nothing to say about that face, and the device does nothing (no ack). An unknown **face**
  key (a second host face a newer hub knows and this firmware does not) is dropped the same way an
  unknown page id is; other faces still apply.
- `err` ∈ {`malformed`}. There is deliberately no `too_many_slots`.
- **Does not restart.** `carousel_apply_comps` persists NVS then hands the resolved list to a
  mutex-guarded pending holder; the next LVGL tick (Core 1, gated on the carousel not mid-scroll) tears
  down and rebuilds only the Home complication stack's children — never the page objects `carousel_apply_pages`
  restarts for. The ack is therefore reliable (the link never drops), unlike `pagesAck`. Idempotent on
  every reconnect exactly like pages: an identical re-push no-ops (no rebuild, no flicker).
- Push order on `central.onReady`: **tickers → comps → pages**. Comps before pages so that if the page
  push restarts the device, the complication blob is already persisted and the device boots correct.
- Migration: NVS `c_home` absent ⇒ the compiled default `clock,fin.sp500,ice,agents`, reproducing today's
  Home exactly. `ComplicationStore` starts pristine (`BeaconCompRev` 0) and never pushes until the first
  edit — an untouched hub changes nothing. Old firmware + new hub: `on_frame()` finds no known key and
  drops the `comps` frame exactly as it drops `sdetail`/`sessions` on older builds; Home renders its
  compiled layout. No version bump either direction.

## B. Device -> hub commands + hub acks (FROZEN, `tech.md` §7.1)

```json
{"v":1,"cmd":"permission","id":"p07","decision":"approve"}   // or "deny"
{"v":1,"ack":"p07","ok":true}                                // decision applied
{"v":1,"ack":"p07","ok":false}                               // decision did NOT apply (late/superseded)
{"v":1,"err":"unknown_prompt_id","id":"p07"}                 // id the hub never minted
{"v":1,"cmd":"open","id":"s3"}                               // device tap -> focus this session (issue #110, Phase 2)
{"v":1,"ack":"s3","ok":true}                                 // focus attempted (best-effort tier succeeded)
{"v":1,"err":"unknown_session","id":"s3"}                    // session id the hub never minted / already reaped
```
- `id` echoes the hub-minted short id (see §D). The hub maps it back to the real hook request id.
- `ok:false` = the device decided but the hub had already resolved the prompt (e.g. the ~590 s fail-closed
  cap fired first, or it was superseded). The device must surface this, not treat it as success.
- `open` (additive `v:1`, Phase 2): the device sends it when a session row is tapped; the hub resolves the
  `s<id>` to its captured host context and focuses that terminal/editor (tiered best-effort). `ok:false` =>
  could not focus (e.g. Automation permission denied / app gone); `unknown_session` => stale/never-minted id.

## B2. Hub -> device ticker config + device -> hub config ack (FROZEN, issue #92, design `docs/specs/2026-06-17-hub-ticker-config-design.md` §2)

The hub is the source of truth for the device's market-ticker list. It pushes a **full-snapshot
replace** as a chunked `config` frame; the device persists it (NVS), live-applies it, and acks once per
completed snapshot. Frozen blocks (status/buddy/loc/permission) are untouched. Mirror of
`firmware/src/core/hub_proto.cpp` (`hub_parse_config_chunk` / `hub_config_accum_step` /
`hub_build_config_ack`) and `BeaconHubKit/TickerConfig.swift`.

### Hub -> device: config frame (chunked)

```json
{"v":1,"config":{"rev":7,"part":0,"parts":2,"tickers":[
  {"id":"ygspc","src":"yahoo","sym":"%5EGSPC","name":"S&P 500","kind":"index","cadence":300,"stale":600,"basis":"prev_close"}]}}
{"v":1,"config":{"rev":7,"part":1,"parts":2,"tickers":[
  {"id":"bbtcusdt","src":"binance","sym":"BTCUSDT","name":"BTC","kind":"crypto","cadence":60,"stale":600,"basis":"24h"}]}}
```

- `rev` — hub's monotonic revision (uint32). Echoed in the ack; correlates ack to push.
- `part` / `parts` — 0-based chunk index and total. Rows concatenated across parts in `part` order ==
  display order (full replace).
- **Chunking rule:** each serialized newline-terminated line is `<= ~900 B` (margin under firmware
  `HUB_FRAME_MAX`=1024). A row is **never split** across chunks. The hub packs as many whole rows per
  chunk as fit; an empty list is never pushed (the device rejects an empty assembled snapshot). Encoder:
  `JSONEncoder(.sortedKeys)` + a trailing `0x0A`, matching the status-frame framing.
- **Row keys (exact):** `id` (<=15 chars, stable, deterministic from `(src,sym)`, invariant under
  reorder/removal), `src` (`binance`|`yahoo`), `sym` (Yahoo percent-encoded **once** for the URL path,
  e.g. `^GSPC` => `%5EGSPC`; Binance raw), `name`, `kind` (`fx`|`crypto`|`index`|`etf`), `cadence` (int
  seconds), `stale` (int seconds), `basis` (`prev_close`|`24h`).

### Device -> hub: config ack (one per completed `rev`)

```json
{"v":1,"cmd":"config_ack","rev":7,"ok":true,"count":8}
{"v":1,"cmd":"config_ack","rev":7,"ok":false,"err":"too_many_tickers"}
```

Uses the device->hub `cmd` channel (parsed by `DeviceCommand.configAck`); it does **not** overload the
prompt-id `ack`. On `ok:true`, `count` = applied ticker count. On reject the device keeps its current
list (fail closed) and reports the first `err`:

| `err` | meaning |
|---|---|
| `too_many_tickers` | assembled count > MAX_TICKERS (16) |
| `empty` | assembled count == 0 |
| `bad_source` | `src` not `binance`/`yahoo` |
| `bad_kind` | `kind` not `fx`/`crypto`/`index`/`etf` |
| `bad_basis` | `basis` not `prev_close`/`24h` |
| `bad_chunking` | out-of-order / duplicate / gap / `rev` mismatch / window timeout |
| `nvs_write_failed` | persisted blob write failed; active table untouched |
| `malformed` | invalid JSON, bad `v`, over-length/empty `id`/`sym`/`name`, bad `part`/`parts` |

**Field caps (UTF-8 bytes, enforced by the device — the hub MUST emit within these or the row is `malformed`):** `id` ≤15, `sym` ≤23, `name` ≤23. The hub clamps `name` to fit (display-only) and drops a candidate whose `sym` exceeds the cap.

## B3. Device -> hub ticker report (additive, issue #105, design `docs/specs/2026-06-19-device-ticker-report-design.md`)

So a fresh (never-configured) hub adopts the list the device already holds, the device emits a one-way
`report` on the device->hub `cmd` channel, **once per connection** after the first inbound hub frame.
Full rows, chunked exactly like §B2 `config` (same row schema/caps), but the envelope is flat `cmd`
fields (not a nested `config` object). The hub adopts only when its store is pristine
(`rev == 0 && rows.isEmpty`); otherwise it ignores the report and stays the source of truth. Mirror of
`firmware/.../hub_proto.cpp` (`hub_report_plan` / `hub_build_report_frame`) and
`BeaconHubKit/Protocol.swift` (`DeviceCommand.report`) + `ReportAssembler`.

```json
{"v":1,"cmd":"report","what":"tickers","rev":0,"part":0,"parts":2,"tickers":[
  {"id":"ygspc","src":"yahoo","sym":"%5EGSPC","name":"S&P 500","kind":"index","cadence":300,"stale":600,"basis":"prev_close"}]}
{"v":1,"cmd":"report","what":"tickers","rev":0,"part":1,"parts":2,"tickers":[
  {"id":"bbtcusdt","src":"binance","sym":"BTCUSDT","name":"BTC","kind":"crypto","cadence":60,"stale":600,"basis":"24h"}]}
```

- `cmd` = `"report"`; `what` = `"tickers"` (namespaces the verb; the hub ignores any other `what`).
- `rev` is **always `0`** -- the device does not persist the hub's rev, and the hub never uses the
  reported value (it adopts its own pristine `rev 0 -> 1`). Carried for structural symmetry + chunk
  continuity only.
- `part` / `parts`, chunking budget, and row keys/caps are **identical to §B2** (rows concatenated in
  `part` order == display order; line <= ~900 B; row never split; <= 16 rows; trailing `0x0A`).
- **No ack.** One-way and informational. An older hub that does not know `cmd:"report"` drops it
  (`DeviceCommand.parse` returns `nil` on an unknown `cmd`).

## C. Upstream shapes (RECORDED — real token-redacted captures, 2026-06-11)

### C.1 Claude usage — statusline `rate_limits` (PRIMARY); `oauth/usage` (FALLBACK)
**Live Claude usage comes from the statusline `rate_limits` (§C.4)** — first-party, no token. The
`oauth/usage` fallback is **intermittent**: it has returned 429 (Anthropic's subscription-limits
change) but answered 200 at this capture, so keep it best-effort. Fallback endpoint headers:
`Authorization: Bearer <tok>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent`. Token: Keychain
`Claude Code-credentials` (access token at `claudeAiOauth.accessToken`; refresh/expiry also present).
Normalizes to `usage.claude` (`utilization`->`pct`, ISO `resets_at`->epoch). `resets_at` carries
microsecond precision + a `+00:00` offset; extra windows (`seven_day_sonnet`, `extra_usage`, ...) are
ignored. Real redacted capture:
```json
{"five_hour":{"utilization":8.0,"resets_at":"2026-06-11T03:30:00.110763+00:00"},
 "seven_day":{"utilization":32.0,"resets_at":"2026-06-15T00:00:01.110782+00:00"},
 "seven_day_sonnet":{"utilization":2.0,"resets_at":"2026-06-15T00:00:01.110788+00:00"},
 "extra_usage":{"is_enabled":false,"utilization":null,"disabled_reason":"org_level_disabled_until"}}
```

### C.2 Codex usage — `GET chatgpt.com/backend-api/wham/usage`
Headers: `Authorization: Bearer <tok>`, `chatgpt-account-id: <id>`. Token: `~/.codex/auth.json`
(`tokens.access_token`, `tokens.account_id`). The draft P2-0 guess matched the live shape: the path is
`rate_limit.{primary_window,secondary_window}.{used_percent,reset_at}` with `reset_at` in epoch
seconds. `used_percent` arrives as an Int here (the normalizer also accepts Double/String); extra
fields (`allowed`, `limit_reached`, `limit_window_seconds`, `reset_after_seconds`, and the top-level
`credits`/`plan_type`/...) are ignored. Normalizes to `usage.codex`. Real redacted capture:
```json
{"plan_type":"plus",
 "rate_limit":{"allowed":false,"limit_reached":true,
   "primary_window":{"used_percent":1,"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":1781151661},
   "secondary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":15234,"reset_at":1781148895}},
 "credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
```
Local fallback (D1, **unimplemented**): the `codex` CLI also records usage token-free in
`~/.codex/sessions/**/rollout-*.jsonl` under `rate_limits.{primary,secondary}` — note the keys differ
from the endpoint's `*_window` (they are null until a window is hit), so a future wiring needs its own
normalizer, not `UsageNormalizer.codex`.

### C.3 Claude Code permission hook (`PermissionRequest`, primary; `PreToolUse`, back-compat) — CONFIRMED (CC v2.1.x docs)
Claude Code supports native **`"type":"http"`** hooks (no curl forwarder needed). `PreToolUse` and
`PermissionRequest` are **distinct** events, and **`PermissionRequest` is the one Beacon hooks**:
`PreToolUse` fires on **every** tool call, so holding it open ~590 s would block routine `Read`/`Grep`
(and a narrow matcher like `Bash` misses `Write`/`Edit`); `PermissionRequest` fires **only when a tool
actually needs permission**, so `matcher:"*"` is safe and covers all tools. The bridge still accepts
`PreToolUse` for back-compat. Request body (same fields both events):
```json
{"session_id":"abc","tool_use_id":"toolu_01","hook_event_name":"PermissionRequest",
 "tool_name":"Write","tool_input":{"file_path":"/x","command":"...","description":"..."}}
```
Hint = `tool_input.command` (Bash) | `file_path` | `description`. Correlation id = `tool_use_id`/
`session_id` (the hub mints its own short BLE id and maps it).

**Response shape DIFFERS by event** (`HookResponse.permission`, `Protocol.swift`) — emitting the wrong
one silently fails to gate the tool:
```json
// PermissionRequest (primary): decision.behavior; message only on deny; updatedInput NOT required for allow
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied on Beacon device"}}}
// PreToolUse (back-compat): permissionDecision in {allow,deny,ask}; precedence deny>ask>allow
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved on Beacon device"}}
// AskUserQuestion (a question, not yes/no): hub never holds it -- it defers to the Mac's prompt so the
// human picks an option there. The device cannot answer a multi-choice question; it only INDICATES that
// a session is waiting on input -- via the `question` session state (set by the separate `Notification`
// hook) and the "tap to answer on Mac" takeover (§A, FR-BUDDY-8), which on tap focuses that terminal so
// the user answers there. Since PermissionRequest's decision.behavior has no "ask" (allow/deny only),
// defer by emitting NO decision -- an empty body CC reads as "no gate", falling through to its own
// interactive prompt.
{}
```
HTTP 2xx + body, no outer envelope. Hook `timeout` is in **seconds** (config: 600 to cover the
~590 s hold). Non-2xx/timeout = **non-blocking (CC proceeds, fail-OPEN)** -- so the hub MUST return
`deny` within the hold window; never let it hang.

### C.4 Session / statusline — CONFIRMED (CC v2.1.x docs)
`SessionStart`(matcher startup/resume/clear/compact)/`Stop`/`Notification`/`SessionEnd` http hooks =>
buddy idle. Stop body has `stop_reason`; Notification has `message`; SessionEnd carries `session_id`
(clean per-session removal). **Statusline** (`statusLine` = `type:command`)
receives JSON with `session_id` (per-session TOK/CTX aggregation key), `cwd` (attribution basename),
`context_window.{used_percentage,total_input_tokens,total_output_tokens}` (=> buddy
`context_pct`/`tokens`) and `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` (=> **Claude
`usage.h5`/`d7`** — now the PRIMARY Claude source, §C.1). The shim **wraps the user's existing
statusline renderer** (forwards the JSON to `127.0.0.1:8765/statusline`, then delegates to the real
command passed as args), so the user's status bar is unchanged. Bind port is the fixed **8765**.

### C.5 Codex hooks (buddy) — VERIFIED (openai/codex codex-rs/hooks @ 0fb559f0; codex-cli 0.140.0)
Codex ships a Claude-compatible command-hook system (feature `hooks`, stable + default-on). The Codex
buddy adapter bridges it with a shim, `~/.beacon/beacon-codex-hook` (installed alongside the Claude
statusline shim). Codex spawns the shim per event with the event JSON on stdin and reads the decision
from stdout.

**Install (managed block in `~/.codex/config.toml`, honors `CODEX_HOME`).** Idempotent, marker-delimited
(`# >>> beacon-codex-hooks (managed by Beacon Hub; do not edit) >>>` ... `<<<`); everything outside the
markers is preserved and a timestamped `.bak.<ts>` is written before any change. The block wires five
events, one matcher group + one command each:

```toml
[[hooks.SessionStart]]
hooks = [{ type = "command", command = "/Users/<you>/.beacon/beacon-codex-hook" }]
[[hooks.UserPromptSubmit]]
hooks = [{ type = "command", command = "/Users/<you>/.beacon/beacon-codex-hook" }]
[[hooks.Stop]]
hooks = [{ type = "command", command = "/Users/<you>/.beacon/beacon-codex-hook" }]
[[hooks.SessionEnd]]
hooks = [{ type = "command", command = "/Users/<you>/.beacon/beacon-codex-hook" }]
[[hooks.PermissionRequest]]
hooks = [{ type = "command", command = "/Users/<you>/.beacon/beacon-codex-hook", timeout = 590 }]

[hooks.state]
"<canonical config.toml path>:permission_request:0:0" = { enabled = true, trusted_hash = "sha256:..." }
# ... one trusted_hash entry per event ...
```

**stdin (Codex -> shim, snake_case).** `{session_id, turn_id, cwd, hook_event_name, model,
permission_mode, tool_name, tool_input, ...}`. `SessionStart` adds `source` (startup|resume|clear|
compact); `SessionEnd` adds `reason`.

**stdout (shim -> Codex).** Byte-identical to the Claude `PermissionRequest` shape (§C.3):
`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny",
"message":"..."}}}`. Empty stdout or `{}` = **no verdict** (Codex falls through to its own interactive
TUI prompt). Any deny wins the fold; exit 2 + stderr also denies.

**Lifecycle -> session state.** `SessionStart` => register (label = cwd basename + git branch),
`UserPromptSubmit` => working, `Stop` => attention, `SessionEnd` => remove. These POST fire-and-forget
(shim `curl -m 1`); the hub replies `{"ok":true}`.

**PermissionRequest hold / timeout.** The shim POSTs synchronously (`curl --max-time 585`) and the hub
HOLDS the connection until the device decides, then returns the allow/deny decision. The hub arms a
fail-closed 575 s cap; the timers are strictly ordered `hub 575 < curl 585 < Codex hook 590` so the hub
always fires first while the socket is still open (its deny reaches Codex). A cap equal to the curl
budget would fire only after curl had already closed the socket, degrading to fail-OPEN passthrough --
curl's clock starts before the hub even receives the request. If the held connection drops first, the
user answered in the Codex TUI => the hub withdraws that prompt silently.

**Pass-through (never auto-deny what the user never saw).** Coding-Buddy OFF, a still-held prompt at
toggle-off, **or an unreachable device** (offline on arrival, or the link dropping while the prompt is
held) returns `{}` (no verdict) so Codex prompts locally; the hub raises a menubar alert naming the
agent ("Beacon offline - CODEX not gated"). Hub unreachable is handled in the shim: connection refused /
timeout => print nothing, exit 0 (fail-open to the Codex TUI).

**Trust (CRITICAL, source-verified + reproduced against codex-cli 0.140.0).** A user-config command hook
only RUNS when Codex marks it `Trusted`, i.e. its `[hooks.state]` `trusted_hash` equals the hash Codex
derives (`codex-rs/hooks/src/engine/discovery.rs`: `enabled && (bypass || Managed | Trusted)`; else the
hook is discovered but never dispatched). Codex derives the hash (`config/src/fingerprint.rs
version_for_toml`) as `sha256:` + hex(sha256(canonical compact JSON of the normalized identity
`{"event_name":"<label>","hooks":[{"async":false,"command":"<cmd>","timeout":<normalized>,"type":"command"}]}`,
object keys sorted). Normalized timeouts: 600 for SessionStart/UserPromptSubmit/Stop, 1 for SessionEnd,
590 for PermissionRequest. The state key is `<fs::canonicalize(config.toml)>:<event label>:<group>:<handler>`
(group/handler are 0 for our single-group-per-event block). The installer computes and writes these
hashes, so a fresh install is immediately trusted with **no interactive trust step** (verified end to end:
`hooks/list` reports every Beacon hook `trusted`). One-time recovery, only if Codex ever reports the
hooks as untrusted (e.g. a Codex build whose hashing changed, or a pre-existing `[[hooks.<Event>]]`
group shifting our group index): re-run install, or trust the Beacon hooks once from the Codex TUI
`/hooks` menu.

### C.6 omp extension (buddy) — VERIFIED (oh-my-pi/pi-coding-agent @ 17.1.1)
omp auto-discovers every module in `~/.omp/agent/extensions/`, so the buddy adapter is a single managed
file, `~/.omp/agent/extensions/beacon.ts` (generated by `OmpHooks.extensionSource`, installed by
`HooksInstaller.installOmp`). No shim, no config merge, no trust hash. The extension `fetch`es the shared
`LocalIngestServer` at **`POST http://127.0.0.1:8765/omp/hook`** (a distinct route; served by the same
generic `HookBuddyProvider` as Codex). Request body is byte-shaped like §C.3:
`{hook_event_name, session_id, cwd, tool_name, tool_input}`. Lifecycle events, mapped from omp extension
events: `session_start`/`session_switch`/`session_branch` => `SessionStart` (rebinds `session_id` from
`ctx.sessionManager.getSessionId()`), `agent_start` => `UserPromptSubmit`, `agent_end` (unless
`willContinue`) => `Stop`, `session_shutdown` => `SessionEnd`. Gated tools: **`bash`** only (`GATED_TOOLS`).
Only **interactive** sessions gate (`ctx.hasUI` on the `tool_call` event itself, not just the cached
`session_id` -- a task subagent runs inside an already-bound interactive session and must be excluded
independently; print mode and subagents both skip, matching Claude).

**Response (hub -> extension).** The §C.3 `PermissionRequest` decision shape; `{}` = passthrough. The
extension parses `hookSpecificOutput.decision.behavior`: `allow` => run; anything else => block with
`decision.message`.

**Tap-to-open host context (v2).** The `SessionStart` POST also carries `host_app` (`TERM_PROGRAM`),
`focus_url` (`WARP_FOCUS_URL`, Warp per-pane handle), and `bundle_id` (`__CFBundleIdentifier`), read from
`process.env` at bind time — the same fields the Claude `beacon-session` shim sends to `/session` (§C.4).
`HookBuddyProvider` merges them into a per-session `HostContextStore` (non-empty-wins) and answers a
device `open` via `SessionFocus` (Tier 1 Warp focus-url > Tier 2 editor reuse > Tier 3 open-by-bundle/app),
clearing them on `SessionEnd`. Codex sends none, so its tap-to-open stays a no-op. Extension source bumped
to marker `beacon-omp v3` (v3 also fixes `tool_call` gating task-subagent `bash` calls under a bound
parent session, issue #136 follow-up); a v1/v2 file reads as not-current and Settings offers reinstall.

**Fail closed (CRITICAL).** omp's default `tools.approvalMode` is `yolo` (built-in approval runs BEFORE
`tool_call` and would execute `bash` unattended), so the extension treats **every** transport/protocol
failure — unreachable hub, non-2xx, unreadable/`decision`-less error body, fetch abort — as `{block:true}`
(`docs/tech.md` §1). The ONLY passthrough is a successful `200` with no `decision` (hub buddy-off/ask, or
device offline). Consequence: extension installed + hub app not running => gated `bash` is blocked
("Beacon hub unreachable") until the hub runs, omp buddy is toggled off, or the file is removed. Second
consequence, accepted by the owner (2026-07-25): with the hub running but the **device** offline, omp
`bash` runs unattended — omp's `tool_call` result is `{block, reason}` only, it has no "ask" escalation,
and its own approval already ran. The hub's menubar alert ("Beacon offline - OMP not gated") is the only
signal. Claude Code and Codex instead fall back to their own interactive prompt on the same `{}`.

**Timing (source-verified against omp 17.1.1).** omp hard-caps every `tool_call` handler at 30 s
(`EXTENSION_HANDLER_TIMEOUT_MS`, blocks the tool on timeout) and waits <=2 s for `session_shutdown`
handlers (`SESSION_SHUTDOWN_HANDLER_TIMEOUT_MS`, so `SessionEnd` is awaited with a 1.5 s budget). Strict
ordering: **device 25 s < hub fail-closed cap 26 s < extension fetch abort 28 s < omp handler ceiling 30 s**.
The hub cap fires first so its deny reaches the still-open `fetch`; if it exceeded the fetch abort the
socket would already be closed and omp would fall through to its own approval.

## D. Hub-side policies

- **Short id mapping (`records.h` `BUDDY_ID_LEN`=24 => <=23 chars):** the hub mints a short id per
  permission prompt and maps it to the full Claude Code hook request id. The device only ever sees +
  echoes the short id.
- **Prompt queue (FIFO, one shown at a time):** `buddy_prompt_t` holds the front prompt; additional
  concurrent permission hooks queue FIFO behind it. `qlen` on the BLE frame carries the total pending
  count (incl. the front) so the device can show a `(1 of N)` badge. (`AskUserQuestion` is exempt:
  it is never held, so a question can't squat the queue and block a real permission behind it.)
- **Silent withdraw (resolved on the Mac):** if CC closes the held hook connection -- because the user
  answered the permission in the Mac terminal instead of on the device -- the hub clears the device
  prompt and advances the queue with NO deny and NO "too late" (`watchForClose`/`withdraw`,
  `ClaudeCodeBridge`). The answer applied on the Mac; the device must not claim otherwise.
- **Timing (per provider):** design target < 5 s round-trip. Hold caps differ by caller deadline — Claude/Codex
  ~590 s hold (below CC's/Codex's ~600 s hook timeout; Codex chain `hub 575 < curl 585 < hook 590`), omp
  26 s hold (chain `device 25 < hub 26 < fetch abort 28 < omp handler ceiling 30`, §C.6). Only a queued
  prompt's own cap expiry denies it (silently); `deny` + label on cap (`tech.md` §8, FR-BUDDY-3).
- **Undeliverable prompt (device offline) => pass-through, never deny.** A prompt that arrives while the
  link is down, or is still held when the link drops, is answered `{}` (no verdict) and the hub raises a
  menubar alert "Beacon offline - <AGENT> not gated" (cleared on reconnect). Denying a prompt the user
  never saw fails the tool call with nothing to act on; fail-closed applies to prompts the device DID
  show (cap expiry) and to the quit drain, which still deny.
- **Logging:** id + decision + timestamp only. NEVER the command `hint` or any token (`tech.md` §9).

### D.1 Onboarding, lifecycle & error recovery (epic #20 — `docs/research/2026-06-08-hub-ux-audit.md`)

- **Settings window + first-run setup (#15):** a single **Settings** window (reachable via the menu
  **Settings…**) presents providers as a table — one row per provider with **Usage / Coding buddy**
  toggle columns plus an inline **Set up** chip beside the provider name — over a global **Connection**
  section (**Bluetooth / device-connected** checks) and the forget/re-pair guidance. On first launch
  (gated by `BeaconFirstRunComplete`) it auto-opens until every check passes or the user ticks **Don't
  open on startup**. **Setup is per provider:** the chip is a **Set up** button until that provider's
  hooks are detected (a green **Ready** once installed); it runs only
  that provider's install (`HooksInstaller.install(providerID:)` — Claude shells out to
  `build-app.sh install-hooks` and installs the statusline shim to the no-space path
  `~/.beacon/beacon-statusline`; Codex writes its managed `~/.codex/config.toml` block; omp writes its
  managed extension `~/.omp/agent/extensions/beacon.ts`, backing up any unrecognized file already there).
  Claude detection requires BOTH the `PermissionRequest` hook (`url=http://127.0.0.1:8765/hook`) AND a
  `statusLine.command` containing the shim — not any beacon URL anywhere. Replaces hand-editing
  `~/.claude/settings.json` and the separate first-run/forget windows.
- **Login item (#16):** `SMAppService.mainApp`, toggled by the menu **Start at login**. The menu reflects the
  REAL registration state (re-read on every menu open), and `.requiresApproval` is surfaced honestly
  (guidance dialog), never a silent false "on".
- **Graceful quit drain (#16):** on quit, every still-held permission prompt is resolved as
  **deny-with-reason** ("Beacon hub is quitting") and the response is flushed to Claude Code BEFORE exit
  (completion-aware: a `DispatchGroup` over the socket-send completions, replied via an idempotent latch from
  the drain or a 1 s safety cap). A `terminating` flag denies any prompt arriving during the drain window, so
  no in-flight CC call is ever left without a responder (fail-OPEN per §C.3 is avoided).
- **Forget device / re-pair (#16):** app-side reset only — cancel the link, drop the cached peripheral,
  rescan. CoreBluetooth has **no API to remove an OS-level bond**, so a truly stuck bond (e.g. keys changed
  after a firmware re-flash) still needs the user's System Settings **Forget This Device**; the Settings
  window's forget section guides there with a one-click **Open Bluetooth & forget** button (app-side reset,
  then jump to Bluetooth settings where the user taps **Forget This Device**).
- **401 token self-heal (#17):** on a usage 401 the hub re-reads the **CLI-rotated** credential (Claude
  Keychain blob / `~/.codex/auth.json`) and retries the request **exactly once** if the token changed; a
  one-shot guard makes a second 401 unable to loop. Self-heals the common case (active user whose CLI already
  refreshed); an idle, truly-expired token still ends at "…token expired - re-login". A real OAuth
  refresh-token grant is **deferred** (it needs unofficial, reverse-engineered endpoints/client_ids).
- **BLE pairing-failed escalation (#17):** a **first-time** bond (`hadConnection == false`) that fails
  **4 attempts or 25 s** (monotonic clock) escalates to a loud `LinkPhase.pairingFailed` ("Pairing failed" +
  **Try pairing again**) instead of rescanning forever silently; a reconnect blip of a previously-bonded
  device is never escalated. "Try again" (`retryPairing`) resets the budget + rescans, distinct from the
  heavier forget/re-pair path.
