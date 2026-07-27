#include "core/hub_proto.h"
#include <ArduinoJson.h>
#include <string.h>

// Copy a C string into a fixed dst[cap], truncating to cap-1 + NUL (records.h string rule).
static void copy_trunc(char* dst, size_t cap, const char* src) {
  if (!src) { dst[0] = '\0'; return; }
  size_t n = strnlen(src, cap - 1);
  memcpy(dst, src, n);
  dst[n] = '\0';
}

void hub_reassembler_reset(hub_reassembler_t* r) {
  r->len = 0; r->overflow = false; r->drops = 0;
}

void hub_reassembler_feed(hub_reassembler_t* r, const char* data, size_t n,
                          hub_line_cb cb, void* user) {
  for (size_t i = 0; i < n; i++) {
    char c = data[i];
    if (c == '\n') {                       // frame boundary
      if (r->overflow) { r->drops++; r->overflow = false; r->len = 0; continue; }
      size_t len = r->len;
      if (len > 0 && r->buf[len - 1] == '\r') len--;   // tolerate CRLF
      if (len > 0) { r->buf[len] = '\0'; cb(r->buf, len, user); }   // skip empty frames
      r->len = 0;
      continue;
    }
    if (r->overflow) continue;             // discard the rest of an oversize frame
    if (r->len >= HUB_FRAME_MAX - 1) { r->overflow = true; continue; }
    r->buf[r->len++] = c;
  }
}

// A window object {"pct":..,"reset":..}; absent/null pct => -1 (unavailable), absent reset => 0.
static void fill_window(usage_window_t* w, JsonVariantConst v) {
  JsonVariantConst p = v["pct"];
  w->pct   = p.isNull() ? -1 : (int16_t)p.as<int>();
  w->reset = v["reset"] | (uint32_t)0;
}

bool hub_parse_status(const char* json, size_t len,
                      usage_rec_t* usage, bool* had_usage,
                      buddy_rec_t* buddy, bool* had_buddy) {
  *had_usage = false; *had_buddy = false;
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return false;   // not valid JSON
  if ((doc["v"] | 0) != 1) return false;               // unknown major version => ignore (tech.md §7.1)

  JsonVariantConst u = doc["usage"];
  if (!u.isNull()) {
    // Frozen wire: usage.providers is an array of {id,label,h5,d7,stale?}. A usage block WITHOUT a
    // providers array is malformed => reject the block (leave *had_usage false => caller keeps last).
    JsonVariantConst provs = u["providers"];
    if (provs.is<JsonArrayConst>()) {
      *had_usage = true;
      usage->count = 0;
      for (JsonVariantConst pv : provs.as<JsonArrayConst>()) {
        if (usage->count >= USAGE_PROVIDERS_MAX) break;   // cap at 4; extras dropped
        usage_provider_t* d = &usage->p[usage->count];
        copy_trunc(d->id,    USAGE_ID_LEN,    pv["id"].as<const char*>());
        copy_trunc(d->label, USAGE_LABEL_LEN, pv["label"].as<const char*>());
        fill_window(&d->h5, pv["h5"]);          // absent/null pct => -1 (unavailable)
        fill_window(&d->d7, pv["d7"]);
        d->stale = pv["stale"] | false;          // #108: absent => live; only "stale":true dims
        usage->count++;
      }
    }
  }

  JsonVariantConst b = doc["buddy"];
  if (!b.isNull()) {
    *had_buddy = true;
    buddy->running     = (uint8_t)(b["running"]     | 0);
    buddy->waiting     = (uint8_t)(b["waiting"]     | 0);
    buddy->tokens      = b["tokens"]                 | (uint32_t)0;
    buddy->context_pct = (uint8_t)(b["context_pct"] | 0);

    buddy->entry_count = 0;
    for (JsonVariantConst e : b["entries"].as<JsonArrayConst>()) {
      if (buddy->entry_count >= BUDDY_ENTRIES) break;
      copy_trunc(buddy->entries[buddy->entry_count], BUDDY_ENTRY_LEN, e.as<const char*>());
      buddy->entry_count++;
    }

    JsonVariantConst p = b["prompt"];
    if (p.isNull()) {                                   // absent prompt => idle
      buddy->prompt.present = false;
      buddy->prompt.id[0] = buddy->prompt.tool[0] = buddy->prompt.hint[0] = buddy->prompt.agent[0] = '\0';
      buddy->prompt.queue_len = 1;
    } else {
      const char* pid = p["id"].as<const char*>();
      // A full-frame resend (e.g. on reconnect) can repeat the SAME prompt we are already showing;
      // preserve its in-flight confirm state (PENDING/TOO_LATE) so a pending ack can still land (#8).
      // Only a genuinely new id (or a prompt shown after idle) is fresh to decide.
      bool same_prompt = buddy->prompt.present && pid && strcmp(buddy->prompt.id, pid) == 0;
      if (!same_prompt) buddy->prompt.decision_state = PROMPT_IDLE_DECISION;
      buddy->prompt.present = true;
      copy_trunc(buddy->prompt.id,   BUDDY_ID_LEN,   pid);
      copy_trunc(buddy->prompt.tool, BUDDY_TOOL_LEN, p["tool"].as<const char*>());
      copy_trunc(buddy->prompt.hint, BUDDY_HINT_LEN, p["hint"].as<const char*>());
      copy_trunc(buddy->prompt.agent, USAGE_ID_LEN, p["agent"].as<const char*>());  // optional; absent => empty
      int q = p["qlen"] | 1;                                 // absent/non-numeric => 1
      buddy->prompt.queue_len = (uint8_t)(q < 1 ? 1 : (q > 255 ? 255 : q));  // clamp: 0/neg => 1, cap at 255
    }
  }
  return true;
}

static uint8_t map_session_state(const char* s) {
  if (!s) return BST_WORKING;
  if (!strcmp(s, "waiting"))        return BST_WAITING;
  if (!strcmp(s, "waiting_queued")) return BST_WAITING_QUEUED;
  if (!strcmp(s, "attention"))      return BST_ATTENTION;
  if (!strcmp(s, "idle"))           return BST_IDLE;
  if (!strcmp(s, "question"))       return BST_QUESTION;
  return BST_WORKING;                                  // unknown => safest non-alerting state
}

bool hub_parse_sessions(const char* json, size_t len, buddy_rec_t* buddy, bool* had_sessions) {
  *had_sessions = false;
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return false;
  if ((doc["v"] | 0) != 1) return false;
  JsonVariantConst arr = doc["sessions"];
  if (!arr.is<JsonArrayConst>()) return false;
  *had_sessions = true;

  // Detail (project/title/msg) arrives in its OWN frame and must survive a sessions update. Rows are
  // newest-first, so their ORDER changes as sessions become active: carrying detail by index would
  // silently attach one session's message to another. Snapshot id->detail, then re-attach by id.
  struct { char id[BUDDY_SID_LEN]; char project[BUDDY_PROJECT_LEN];
           char title[BUDDY_TITLE_LEN]; char msg[BUDDY_MSG_LEN]; } prev[BUDDY_SESSIONS_MAX];
  uint8_t prev_n = buddy->session_count;
  if (prev_n > BUDDY_SESSIONS_MAX) prev_n = BUDDY_SESSIONS_MAX;
  for (uint8_t i = 0; i < prev_n; i++) {
    copy_trunc(prev[i].id,      BUDDY_SID_LEN,     buddy->sessions[i].id);
    copy_trunc(prev[i].project, BUDDY_PROJECT_LEN, buddy->sessions[i].project);
    copy_trunc(prev[i].title,   BUDDY_TITLE_LEN,   buddy->sessions[i].title);
    copy_trunc(prev[i].msg,     BUDDY_MSG_LEN,     buddy->sessions[i].msg);
  }

  buddy->session_count = 0;
  for (JsonVariantConst s : arr.as<JsonArrayConst>()) {
    if (buddy->session_count >= BUDDY_SESSIONS_MAX) break;   // hub caps at 5; defend anyway
    buddy_session_t* d = &buddy->sessions[buddy->session_count];
    copy_trunc(d->id,    BUDDY_SID_LEN,   s["id"].as<const char*>());
    copy_trunc(d->label, BUDDY_LABEL_LEN, s["label"].as<const char*>());
    copy_trunc(d->agent, USAGE_ID_LEN,    s["agent"].as<const char*>());  // optional; absent => empty
    d->state = map_session_state(s["state"].as<const char*>());
    d->ts    = s["ts"] | (uint32_t)0;
    // Re-attach this id's detail; a genuinely new id starts empty rather than inheriting a neighbour's.
    d->project[0] = d->title[0] = d->msg[0] = '\0';
    for (uint8_t i = 0; i < prev_n; i++) {
      if (strcmp(prev[i].id, d->id) != 0) continue;
      copy_trunc(d->project, BUDDY_PROJECT_LEN, prev[i].project);
      copy_trunc(d->title,   BUDDY_TITLE_LEN,   prev[i].title);
      copy_trunc(d->msg,     BUDDY_MSG_LEN,     prev[i].msg);
      break;
    }
    buddy->session_count++;
  }
  return true;
}

// "sdetail" frame (CONTRACT.md A): row content joined to the existing sessions by id. Unknown ids are
// ignored rather than creating rows -- the sessions frame is the sole authority on which sessions exist.
bool hub_parse_sdetail(const char* json, size_t len, buddy_rec_t* buddy, bool* had_sdetail) {
  *had_sdetail = false;
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return false;
  if ((doc["v"] | 0) != 1) return false;
  JsonVariantConst arr = doc["sdetail"];
  if (!arr.is<JsonArrayConst>()) return false;
  *had_sdetail = true;
  for (JsonVariantConst e : arr.as<JsonArrayConst>()) {
    const char* id = e["id"].as<const char*>();
    if (!id || !*id) continue;
    for (uint8_t i = 0; i < buddy->session_count && i < BUDDY_SESSIONS_MAX; i++) {
      if (strcmp(buddy->sessions[i].id, id) != 0) continue;
      // Per-field stickiness: an omitted field leaves what the device already shows, so a partial frame
      // never blanks a title that is still true.
      const char* p = e["project"].as<const char*>();
      const char* t = e["title"].as<const char*>();
      const char* m = e["msg"].as<const char*>();
      if (p && *p) copy_trunc(buddy->sessions[i].project, BUDDY_PROJECT_LEN, p);
      if (t && *t) copy_trunc(buddy->sessions[i].title,   BUDDY_TITLE_LEN,   t);
      if (m && *m) copy_trunc(buddy->sessions[i].msg,     BUDDY_MSG_LEN,     m);
      break;
    }
  }
  return true;
}

// "sonos" frame (CONTRACT.md A, phase 1 text only): a full snapshot of the selected room's now-playing
// state, not joined/sticky like sdetail. Every present field replaces; every absent field clears to its
// default -- copy_trunc already treats a missing key (nullptr from as<const char*>()) as "", and the
// `| false` idiom (fill_window's sibling) covers the bool. Unknown keys inside "sonos" are simply never
// read, so they cost nothing and never fail the frame.
bool hub_parse_sonos(const char* json, size_t len, sonos_rec_t* out, bool* had_sonos) {
  *had_sonos = false;
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return false;   // not valid JSON
  if ((doc["v"] | 0) != 1) return false;                // unknown major version => ignore
  JsonVariantConst s = doc["sonos"];
  if (!s.is<JsonObjectConst>()) return false;            // no "sonos" object in this frame
  *had_sonos = true;
  copy_trunc(out->room,   SONOS_ROOM_LEN,   s["room"].as<const char*>());
  copy_trunc(out->track,  SONOS_TRACK_LEN,  s["track"].as<const char*>());
  copy_trunc(out->artist, SONOS_ARTIST_LEN, s["artist"].as<const char*>());
  copy_trunc(out->album,  SONOS_ALBUM_LEN,  s["album"].as<const char*>());
  out->playing = s["playing"] | false;                   // absent/non-bool => false
  return true;
}

// Defined below with the other frame builders; declared here so the pages ack can sit beside its parser.
static size_t finish_frame(JsonDocument& doc, char* buf, size_t cap);

data_err_t hub_parse_pages(const char* json, size_t len, uint32_t* rev, page_list_t* out,
                           const char** err_out) {
  static const char* E_MALFORMED = "malformed";
  static const char* E_TOO_MANY  = "too_many_pages";
  if (out) memset(out, 0, sizeof(*out));
  JsonDocument doc;
  if (deserializeJson(doc, json, len))                 { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  if ((doc["v"] | 0) != 1)                             { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  JsonVariantConst p = doc["pages"];
  if (!p.is<JsonObjectConst>())                        { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  if (!p["rev"].is<uint32_t>() && !p["rev"].is<int>()) { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  JsonVariantConst list = p["list"];
  if (!list.is<JsonArrayConst>())                      { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }

  JsonArrayConst arr = list.as<JsonArrayConst>();
  if (arr.size() > PAGES_MAX)                          { if (err_out) *err_out = E_TOO_MANY;  return ERR_PARSE; }
  if (arr.size() == 0)                                 { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }

  page_list_t tmp; memset(&tmp, 0, sizeof(tmp));
  for (JsonVariantConst e : arr) {
    const char* id = e["id"].as<const char*>();
    if (!id || !*id)                                   { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
    if (!page_list_add(&tmp, id)) continue;   // duplicates collapse; unknown ids are resolve's problem
    // Flatten {"opts":{"k":"v"}} into the device's compact "k:v;k:v". Only scalars are taken -- a
    // nested object or array has no representation here and is skipped rather than half-encoded.
    JsonVariantConst opts = e["opts"];
    if (opts.is<JsonObjectConst>()) {
      char flat[PAGE_OPTS_LEN]; size_t n = 0; flat[0] = '\0';
      for (JsonPairConst kv : opts.as<JsonObjectConst>()) {
        char val[PAGE_OPTS_LEN];
        if (kv.value().is<const char*>())      snprintf(val, sizeof(val), "%s", kv.value().as<const char*>());
        else if (kv.value().is<int>())         snprintf(val, sizeof(val), "%d", kv.value().as<int>());
        else if (kv.value().is<bool>())        snprintf(val, sizeof(val), "%d", kv.value().as<bool>() ? 1 : 0);
        else continue;
        if (!val[0]) continue;
        int w = snprintf(flat + n, sizeof(flat) - n, "%s%s:%s", n ? ";" : "", kv.key().c_str(), val);
        if (w < 0 || (size_t)w >= sizeof(flat) - n) { flat[n] = '\0'; break; }   // full: keep what fits
        n += (size_t)w;
      }
      if (flat[0]) page_list_set_opts(&tmp, id, flat);
    }
  }
  if (tmp.count == 0)                                  { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  if (rev) *rev = (uint32_t)(p["rev"] | 0);
  if (out) *out = tmp;
  return ERR_NONE;
}

size_t hub_build_pages_ack(char* buf, size_t cap, uint32_t rev, bool ok, const char* err, int count) {
  if (!buf || cap == 0) return 0;
  JsonDocument doc;
  doc["v"] = 1;
  doc["cmd"] = "pages_ack";
  doc["rev"] = rev;
  doc["ok"] = ok;
  if (ok) doc["count"] = count;
  else    doc["err"] = (err && *err) ? err : "malformed";
  return finish_frame(doc, buf, cap);
}

data_err_t hub_parse_comps(const char* json, size_t len, uint32_t* rev,
                           const char* face_id, comp_list_t* out, bool* explicit_empty,
                           const char** err_out) {
  static const char* E_MALFORMED = "malformed";
  if (out) memset(out, 0, sizeof(*out));
  if (explicit_empty) *explicit_empty = false;
  if (!face_id || !*face_id)                           { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }

  JsonDocument doc;
  if (deserializeJson(doc, json, len))                 { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  if ((doc["v"] | 0) != 1)                              { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  JsonVariantConst c = doc["comps"];
  if (!c.is<JsonObjectConst>())                         { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  if (!c["rev"].is<uint32_t>() && !c["rev"].is<int>())  { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  JsonVariantConst slots = c["slots"];
  if (!slots.is<JsonObjectConst>())                     { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }
  // NOT `c["rev"] | 0`: ArduinoJson's operator| deduces T=int from the literal 0, and is<int>() is false
  // for a value above INT32_MAX (e.g. the worst-case uint32 rev), silently falling back to the default
  // (0) instead of the real value. .as<uint32_t>() extracts the full range validated above.
  if (rev) *rev = c["rev"].as<uint32_t>();

  // This frame simply does not carry `face_id` -- NOT an error (the pages analogy breaks here: an
  // absent "list" is malformed for pages, but an absent face here just means nothing to do).
  JsonVariantConst arrV = slots[face_id];
  if (arrV.isNull()) return ERR_NONE;
  if (!arrV.is<JsonArrayConst>())                       { if (err_out) *err_out = E_MALFORMED; return ERR_PARSE; }

  JsonArrayConst arr = arrV.as<JsonArrayConst>();
  if (explicit_empty) *explicit_empty = (arr.size() == 0);   // rule 5: distinct from *out ending up empty

  comp_list_t tmp; memset(&tmp, 0, sizeof(tmp));
  for (JsonVariantConst e : arr) {
    if (tmp.count >= COMP_SLOTS_MAX) break;              // structural cap; resolve truncates semantically too
    if (!e.is<const char*>()) continue;                   // a non-string entry: drop, don't fail the frame
    const char* raw = e.as<const char*>();
    char id[COMP_ID_LEN], arg[COMP_ARG_LEN];
    if (!comp_entry_split(raw, id, sizeof(id), arg, sizeof(arg))) continue;   // unsplittable: drop
    snprintf(tmp.ids[tmp.count],  COMP_ID_LEN,  "%s", id);
    snprintf(tmp.args[tmp.count], COMP_ARG_LEN, "%s", arg);
    tmp.count++;
  }
  if (out) *out = tmp;
  return ERR_NONE;
}

size_t hub_build_comps_ack(char* buf, size_t cap, uint32_t rev, bool ok, const char* err, int count) {
  if (!buf || cap == 0) return 0;
  JsonDocument doc;
  doc["v"] = 1;
  doc["cmd"] = "comps_ack";
  doc["rev"] = rev;
  doc["ok"] = ok;
  if (ok) doc["count"] = count;
  else    doc["err"] = (err && *err) ? err : "malformed";
  return finish_frame(doc, buf, cap);
}

bool hub_parse_loc(const char* json, size_t len, hub_loc_t* out) {
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return false;   // not valid JSON
  if ((doc["v"] | 0) != 1) return false;               // unknown major version => ignore
  JsonVariantConst l = doc["loc"];
  if (l.isNull()) return false;                         // no loc block in this frame
  out->lat = l["lat"] | 0.0f;
  out->lon = l["lon"] | 0.0f;
  copy_trunc(out->tz,   sizeof(out->tz),   l["tz"].as<const char*>());
  copy_trunc(out->name, sizeof(out->name), l["name"].as<const char*>());
  return true;
}

// Serialize `doc` into buf as a newline-terminated frame. Returns bytes (incl. '\n', excl. NUL) or 0.
static size_t finish_frame(JsonDocument& doc, char* buf, size_t cap) {
  size_t need = measureJson(doc);
  if (need + 2 > cap) return 0;            // no room for the JSON + '\n' + NUL
  size_t n = serializeJson(doc, buf, cap);
  buf[n++] = '\n';
  buf[n] = '\0';
  return n;
}

size_t hub_build_permission(char* buf, size_t cap, const char* id, bool approve) {
  if (!buf || !id || cap == 0) return 0;
  JsonDocument doc;
  doc["v"] = 1;
  doc["cmd"] = "permission";
  doc["id"] = id;
  doc["decision"] = approve ? "approve" : "deny";
  return finish_frame(doc, buf, cap);
}

size_t hub_build_open(char* buf, size_t cap, const char* id) {
  if (!buf || !id || cap == 0) return 0;
  JsonDocument doc;
  doc["v"] = 1;
  doc["cmd"] = "open";
  doc["id"] = id;
  return finish_frame(doc, buf, cap);
}

bool hub_parse_ack(const char* json, size_t len, hub_ack_t* out) {
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return false;
  if ((doc["v"] | 0) != 1) return false;
  JsonVariantConst ack = doc["ack"];
  if (!ack.isNull()) {                     // {"ack":"<id>","ok":true}
    out->is_err = false;
    out->ok = doc["ok"] | false;
    copy_trunc(out->id, BUDDY_ID_LEN, ack.as<const char*>());
    return true;
  }
  JsonVariantConst err = doc["err"];
  if (!err.isNull()) {                     // {"err":"<reason>","id":"<id>"}
    out->is_err = true;
    out->ok = false;
    copy_trunc(out->id, BUDDY_ID_LEN, doc["id"].as<const char*>());
    return true;
  }
  return false;
}

bool hub_apply_ack(buddy_rec_t* buddy, const hub_ack_t* ack) {
  buddy_prompt_t* p = &buddy->prompt;
  if (!p->present || p->decision_state != PROMPT_PENDING) return false;   // nothing awaiting an ack
  if (strncmp(p->id, ack->id, BUDDY_ID_LEN) != 0) return false;           // stale/mismatched id
  if (ack->ok && !ack->is_err) {
    p->decision_state = PROMPT_SENT_OK;                                   // keep present: the device tick clears it after the confirm-hold beat
  } else {
    p->decision_state = PROMPT_TOO_LATE;                                  // keep present so the UI can warn
  }
  return true;
}

// --- config chunk: wire enum string => firmware enum ---
// Returns false (leaving *out untouched) on an unknown string so the caller can ack the right bad_*.
static bool map_source(const char* s, ticker_source_t* out) {
  if (!s) return false;
  if (!strcmp(s, "binance")) { *out = SRC_BINANCE; return true; }
  if (!strcmp(s, "yahoo"))   { *out = SRC_YAHOO;   return true; }
  return false;
}
static bool map_kind(const char* s, ticker_kind_t* out) {
  if (!s) return false;
  if (!strcmp(s, "fx"))     { *out = KIND_FX;     return true; }
  if (!strcmp(s, "crypto")) { *out = KIND_CRYPTO; return true; }
  if (!strcmp(s, "index"))  { *out = KIND_INDEX;  return true; }
  if (!strcmp(s, "etf"))    { *out = KIND_ETF;    return true; }
  return false;
}
static bool map_basis(const char* s, change_basis_t* out) {
  if (!s) return false;
  if (!strcmp(s, "prev_close")) { *out = CHG_PREV_CLOSE; return true; }
  if (!strcmp(s, "24h"))        { *out = CHG_24H;        return true; }
  return false;
}

// Copy src into dst[cap] only if it fits (<= cap-1, +NUL); false otherwise (no silent truncation: the
// spec rejects over-length id/sym/name with "malformed", design §3.4). NULL/empty handled by caller.
static bool copy_bounded(char* dst, size_t cap, const char* src) {
  size_t n = strlen(src);
  if (n > cap - 1) return false;
  memcpy(dst, src, n);
  dst[n] = '\0';
  return true;
}

#define CFG_SET_ERR(s) do { if (err_out) *err_out = (s); } while (0)

data_err_t hub_parse_config_chunk(const char* json, size_t len, config_chunk_t* out,
                                  const char** err_out) {
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) { CFG_SET_ERR("malformed"); return ERR_PARSE; }
  if ((doc["v"] | 0) != 1)            { CFG_SET_ERR("malformed"); return ERR_PARSE; }

  JsonVariantConst cfg = doc["config"];
  JsonVariantConst tickers = cfg["tickers"];
  if (cfg.isNull() || !tickers.is<JsonArrayConst>()) { CFG_SET_ERR("malformed"); return ERR_PARSE; }

  // parts must be a positive total; part a valid 0-based index within it.
  int parts = cfg["parts"] | 0;
  int part  = cfg["part"]  | -1;
  if (parts <= 0 || part < 0 || part >= parts) { CFG_SET_ERR("malformed"); return ERR_PARSE; }
  out->rev   = cfg["rev"] | (uint32_t)0;
  out->part  = part;
  out->parts = parts;

  out->row_count = 0;
  for (JsonVariantConst row : tickers.as<JsonArrayConst>()) {
    if (out->row_count >= MAX_TICKERS) { CFG_SET_ERR("malformed"); return ERR_PARSE; }  // accumulator re-checks totals
    ticker_runtime_t* r = &out->rows[out->row_count];

    const char* id = row["id"].as<const char*>();
    if (!id || id[0] == '\0' || !copy_bounded(r->id, FIN_ID_LEN, id)) {  // id required + non-empty
      CFG_SET_ERR("malformed"); return ERR_PARSE;
    }
    const char* sym = row["sym"].as<const char*>();
    const char* name = row["name"].as<const char*>();
    if (!sym || !name || !copy_bounded(r->symbol, TKR_SYM_LEN, sym) ||
        !copy_bounded(r->name, TKR_NAME_LEN, name)) {
      CFG_SET_ERR("malformed"); return ERR_PARSE;
    }
    if (!map_source(row["src"].as<const char*>(), &r->source)) { CFG_SET_ERR("bad_source"); return ERR_PARSE; }
    if (!map_kind(row["kind"].as<const char*>(), &r->kind))    { CFG_SET_ERR("bad_kind");   return ERR_PARSE; }
    if (!map_basis(row["basis"].as<const char*>(), &r->change_basis)) { CFG_SET_ERR("bad_basis"); return ERR_PARSE; }
    r->cadence_s = (uint16_t)(row["cadence"] | 0);
    r->stale_s   = row["stale"] | (uint32_t)0;
    out->row_count++;
  }
  return ERR_NONE;
}

config_status_t hub_config_accum_step(config_accum_t* acc, const config_chunk_t* chunk,
                                      const char** err_out) {
  if (chunk->part == 0) {                 // part 0 always (re)starts a fresh accumulation
    acc->active    = true;
    acc->rev       = chunk->rev;
    acc->parts     = chunk->parts;
    acc->next_part = 0;
    acc->row_count = 0;
  } else if (!acc->active || chunk->rev != acc->rev || chunk->parts != acc->parts ||
             chunk->part != acc->next_part) {
    acc->active = false;                   // discard partial: out-of-order/duplicate/rev mismatch/gap
    CFG_SET_ERR("bad_chunking");
    return CFG_ERR;
  }

  if (acc->row_count + chunk->row_count > MAX_TICKERS) {
    acc->active = false;
    CFG_SET_ERR("too_many_tickers");
    return CFG_ERR;
  }
  for (int i = 0; i < chunk->row_count; i++) acc->rows[acc->row_count++] = chunk->rows[i];
  acc->next_part = chunk->part + 1;

  if (acc->next_part < acc->parts) return CFG_PENDING;   // more parts to come

  acc->active = false;                    // snapshot complete (success or empty both end accumulation)
  if (acc->row_count < 1) { CFG_SET_ERR("empty"); return CFG_ERR; }
  return CFG_DONE;
}

#undef CFG_SET_ERR

size_t hub_build_config_ack(char* buf, size_t cap, uint32_t rev, bool ok, const char* err, int count) {
  if (!buf || cap == 0) return 0;
  JsonDocument doc;
  doc["v"] = 1;
  doc["cmd"] = "config_ack";
  doc["rev"] = rev;
  doc["ok"] = ok;
  if (ok) doc["count"] = count;
  else    doc["err"] = err ? err : "malformed";
  return finish_frame(doc, buf, cap);
}

// --- device -> hub ticker report (issue #105) ---
#define REPORT_CHUNK_MAX 900   // mirror ConfigFrame maxBytes; margin under HUB_FRAME_MAX

static const char* src_to_wire(ticker_source_t s) {
  switch (s) { case SRC_BINANCE: return "binance"; case SRC_YAHOO: return "yahoo"; }
  return NULL;
}
static const char* kind_to_wire(ticker_kind_t k) {
  switch (k) {
    case KIND_FX: return "fx"; case KIND_CRYPTO: return "crypto";
    case KIND_INDEX: return "index"; case KIND_ETF: return "etf";
  }
  return NULL;
}
static const char* basis_to_wire(change_basis_t b) {
  switch (b) { case CHG_PREV_CLOSE: return "prev_close"; case CHG_24H: return "24h"; }
  return NULL;
}

size_t hub_build_report_frame(const ticker_runtime_t* rows, int lo, int hi,
                              int part, int parts, char* buf, size_t cap) {
  if (!rows || !buf || cap == 0) return 0;
  if (parts <= 0 || part < 0 || part >= parts) return 0;            // bad chunk coordinates
  if (lo < 0 || hi <= lo || hi > MAX_TICKERS) return 0;             // bad / out-of-bounds range
  JsonDocument doc;
  doc["v"]    = 1;
  doc["cmd"]  = "report";
  doc["what"] = "tickers";
  doc["rev"]  = 0;
  doc["part"] = part;
  doc["parts"] = parts;
  JsonArray arr = doc["tickers"].to<JsonArray>();
  for (int i = lo; i < hi; i++) {
    const char* src   = src_to_wire(rows[i].source);
    const char* kind  = kind_to_wire(rows[i].kind);
    const char* basis = basis_to_wire(rows[i].change_basis);
    if (!src || !kind || !basis) return 0;          // unmappable enum => fail closed (all-or-zero)
    JsonObject o = arr.add<JsonObject>();
    o["id"]      = rows[i].id;
    o["src"]     = src;
    o["sym"]     = rows[i].symbol;
    o["name"]    = rows[i].name;
    o["kind"]    = kind;
    o["cadence"] = rows[i].cadence_s;
    o["stale"]   = rows[i].stale_s;
    o["basis"]   = basis;
  }
  return finish_frame(doc, buf, cap);
}

int hub_report_plan(const ticker_runtime_t* rows, int count, int group_start[MAX_TICKERS]) {
  if (!rows || !group_start || count < 1 || count > MAX_TICKERS) return 0;
  // Measure with worst-case header digits: parts=count AND part=count-1 (the real part/parts are both
  // <= these, so a group that fits the measurement still fits when re-serialized with the real values).
  const int wp = count - 1;
  int groups = 0, lo = 0;
  for (int i = 0; i < count; i++) {
    char tmp[HUB_FRAME_MAX];
    size_t n = hub_build_report_frame(rows, lo, i + 1, wp, count, tmp, sizeof(tmp));
    // n==0 when the probe overflowed HUB_FRAME_MAX (definitely >REPORT_CHUNK_MAX) or an enum error.
    // Both are treated as "over budget" — the split logic below disambiguates the i==lo failure.
    bool over = (n == 0 || n > REPORT_CHUNK_MAX);
    if (!over) continue;                             // row i still fits the current group
    if (i == lo) return 0;                          // a single row alone exceeds the budget (or enum error)
    group_start[groups++] = lo;                     // close [lo..i)
    lo = i;                                          // row i opens a new group
    size_t n2 = hub_build_report_frame(rows, lo, i + 1, wp, count, tmp, sizeof(tmp));
    if (n2 == 0 || n2 > REPORT_CHUNK_MAX) return 0; // row i alone over budget
  }
  group_start[groups++] = lo;                       // final open group
  return groups;
}
