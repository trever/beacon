#include "core/page_config.h"
#include <string.h>
#include <stdio.h>

bool page_list_contains(const page_list_t* l, const char* id) {
  if (!l || !id) return false;
  for (uint8_t i = 0; i < l->count && i < PAGES_MAX; i++)
    if (strncmp(l->ids[i], id, PAGE_ID_LEN) == 0) return true;
  return false;
}

bool page_list_add(page_list_t* l, const char* id) {
  if (!l || !id || !*id) return false;
  if (l->count >= PAGES_MAX) return false;
  if (page_list_contains(l, id)) return false;
  snprintf(l->ids[l->count], PAGE_ID_LEN, "%s", id);
  l->count++;
  return true;
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
      page_list_add(out, id);                             // add() already collapses duplicates
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

size_t page_list_serialize(const page_list_t* l, char* buf, size_t cap) {
  if (!l || !buf || cap == 0) return 0;
  size_t n = 0;
  buf[0] = '\0';
  for (uint8_t i = 0; i < l->count && i < PAGES_MAX; i++) {
    if (!l->ids[i][0]) continue;
    int w = snprintf(buf + n, cap - n, "%s%s", n ? "," : "", l->ids[i]);
    if (w < 0 || (size_t)w >= cap - n) { buf[n] = '\0'; break; }   // truncate cleanly, never overrun
    n += (size_t)w;
  }
  return n;
}

void page_list_deserialize(const char* s, page_list_t* out) {
  if (!out) return;
  memset(out, 0, sizeof(*out));
  if (!s) return;
  const char* p = s;
  while (*p && out->count < PAGES_MAX) {
    const char* comma = strchr(p, ',');
    size_t len = comma ? (size_t)(comma - p) : strlen(p);
    if (len > 0) {
      char id[PAGE_ID_LEN];
      size_t copy = len < PAGE_ID_LEN - 1 ? len : PAGE_ID_LEN - 1;
      memcpy(id, p, copy);
      id[copy] = '\0';
      page_list_add(out, id);
    }
    if (!comma) break;
    p = comma + 1;
  }
}
