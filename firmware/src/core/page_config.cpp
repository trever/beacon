#include "core/page_config.h"
#include <string.h>
#include <stdio.h>

bool page_list_contains(const page_list_t* l, const char* id) {
  if (!l || !id) return false;
  for (uint8_t i = 0; i < l->count && i < PAGES_MAX; i++)
    if (strncmp(l->ids[i], id, PAGE_ID_LEN) == 0) return true;
  return false;
}

bool page_list_equal(const page_list_t* a, const page_list_t* b) {
  if (!a || !b) return a == b;
  if (a->count != b->count) return false;
  for (uint8_t i = 0; i < a->count && i < PAGES_MAX; i++) {
    if (strncmp(a->ids[i],  b->ids[i],  PAGE_ID_LEN)   != 0) return false;
    if (strncmp(a->opts[i], b->opts[i], PAGE_OPTS_LEN) != 0) return false;
  }
  return true;
}

bool page_list_add(page_list_t* l, const char* id) {
  if (!l || !id || !*id) return false;
  if (l->count >= PAGES_MAX) return false;
  if (page_list_contains(l, id)) return false;
  snprintf(l->ids[l->count], PAGE_ID_LEN, "%s", id);
  l->count++;
  return true;
}

bool page_opts_get(const char* opts, const char* key, char* out, size_t cap) {
  if (out && cap) out[0] = '\0';
  if (!opts || !key || !*key || !out || cap == 0) return false;
  size_t klen = strlen(key);
  const char* p = opts;
  while (*p) {
    const char* semi = strchr(p, ';');
    size_t rec = semi ? (size_t)(semi - p) : strlen(p);
    const char* colon = (const char*)memchr(p, ':', rec);
    if (colon) {
      size_t this_klen = (size_t)(colon - p);
      if (this_klen == klen && strncmp(p, key, klen) == 0) {
        size_t vlen = rec - this_klen - 1;
        if (vlen > cap - 1) vlen = cap - 1;
        memcpy(out, colon + 1, vlen);
        out[vlen] = '\0';
        return vlen > 0;
      }
    }
    if (!semi) break;
    p = semi + 1;
  }
  return false;
}

const char* page_list_opts(const page_list_t* l, const char* id) {
  if (!l || !id) return "";
  for (uint8_t i = 0; i < l->count && i < PAGES_MAX; i++)
    if (strncmp(l->ids[i], id, PAGE_ID_LEN) == 0) return l->opts[i];
  return "";
}

void page_list_set_opts(page_list_t* l, const char* id, const char* opts) {
  if (!l || !id) return;
  for (uint8_t i = 0; i < l->count && i < PAGES_MAX; i++) {
    if (strncmp(l->ids[i], id, PAGE_ID_LEN) != 0) continue;
    if (!opts) { l->opts[i][0] = '\0'; return; }
    // ':' and ';' are this string's OWN structure, so they survive; the record separators do not.
    size_t n = 0;
    for (const char* p = opts; *p && n + 1 < PAGE_OPTS_LEN; p++) {
      if (*p == '|' || *p == '=' || *p == ',') continue;
      l->opts[i][n++] = *p;
    }
    l->opts[i][n] = '\0';
    return;
  }
}

static bool known_has(const char* const* known, uint8_t n, const char* id) {
  for (uint8_t i = 0; i < n; i++)
    if (known[i] && strncmp(known[i], id, PAGE_ID_LEN) == 0) return true;
  return false;
}

uint8_t page_list_resolve(const page_list_t* requested,
                          const char* const* known, uint8_t known_count,
                          const char* always_id,
                          const page_list_t* fallback,
                          page_list_t* out) {
  if (!out) return 0;
  memset(out, 0, sizeof(*out));

  if (requested) {
    for (uint8_t i = 0; i < requested->count && i < PAGES_MAX; i++) {
      const char* id = requested->ids[i];
      if (!*id) continue;
      if (!known_has(known, known_count, id)) continue;   // newer hub named a page we don't carry
      if (page_list_add(out, id))                         // add() already collapses duplicates
        page_list_set_opts(out, id, requested->opts[i]);  // options ride along with their page
    }
  }

  // Nothing usable: fall back rather than render a blank carousel. The fallback is filtered too, so a
  // stale default can never smuggle in an id this build no longer has.
  if (out->count == 0 && fallback) {
    for (uint8_t i = 0; i < fallback->count && i < PAGES_MAX; i++)
      if (known_has(known, known_count, fallback->ids[i])) page_list_add(out, fallback->ids[i]);
  }

  // Lockout guard: settings must always be reachable. If the list is full, evict the last entry to make
  // room -- being unable to reach settings is worse than losing the least-prominent page.
  if (always_id && *always_id && known_has(known, known_count, always_id) &&
      !page_list_contains(out, always_id)) {
    if (out->count >= PAGES_MAX) out->count = PAGES_MAX - 1;
    page_list_add(out, always_id);
  }
  return out->count;
}

// "home|chart=sym:sp500|ice". Records are '|'-joined so a legacy comma-joined blob (ids only, written
// before options existed) still parses -- see page_list_deserialize.
size_t page_list_serialize(const page_list_t* l, char* buf, size_t cap) {
  if (!l || !buf || cap == 0) return 0;
  size_t n = 0;
  buf[0] = '\0';
  for (uint8_t i = 0; i < l->count && i < PAGES_MAX; i++) {
    if (!l->ids[i][0]) continue;
    int w = l->opts[i][0]
          ? snprintf(buf + n, cap - n, "%s%s=%s", n ? "|" : "", l->ids[i], l->opts[i])
          : snprintf(buf + n, cap - n, "%s%s",    n ? "|" : "", l->ids[i]);
    if (w < 0 || (size_t)w >= cap - n) { buf[n] = '\0'; break; }   // truncate cleanly, never overrun
    n += (size_t)w;
  }
  return n;
}

void page_list_deserialize(const char* s, page_list_t* out) {
  if (!out) return;
  memset(out, 0, sizeof(*out));
  if (!s) return;
  // Pre-options blobs are comma-joined ids with no '|'; reading them keeps a device's page set across
  // the firmware update that introduced options, instead of silently resetting it to the default.
  const char sep = strchr(s, '|') ? '|' : ',';
  const char* p = s;
  while (*p && out->count < PAGES_MAX) {
    const char* next = strchr(p, sep);
    size_t len = next ? (size_t)(next - p) : strlen(p);
    if (len > 0) {
      const char* eq = (const char*)memchr(p, '=', len);
      size_t idlen = eq ? (size_t)(eq - p) : len;
      char id[PAGE_ID_LEN];
      size_t copy = idlen < PAGE_ID_LEN - 1 ? idlen : PAGE_ID_LEN - 1;
      memcpy(id, p, copy);
      id[copy] = '\0';
      if (page_list_add(out, id) && eq) {
        char opts[PAGE_OPTS_LEN];
        size_t olen = len - idlen - 1;
        if (olen > PAGE_OPTS_LEN - 1) olen = PAGE_OPTS_LEN - 1;
        memcpy(opts, eq + 1, olen);
        opts[olen] = '\0';
        page_list_set_opts(out, id, opts);
      }
    }
    if (!next) break;
    p = next + 1;
  }
}
