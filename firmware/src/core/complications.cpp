#include "core/complications.h"
#include <string.h>
#include <stdio.h>

// COMP_CATALOG contents, exactly (design §4.2). `chart`'s renderer is Phase 2 (comp_find("chart") will
// return NULL on the device -- WS-1 does not register one), so resolve legitimately drops any "chart"
// placement on this firmware today; that is the correct Phase 1 behaviour, not a bug.
const comp_def_t COMP_CATALOG[] = {
  { "clock",   2, false },
  { "fin",     1, true  },
  { "ice",     1, false },
  { "agents",  1, false },
  { "usage",   1, true  },
  { "weather", 1, false },
  { "sonos",   1, false },
  { "chart",   2, true  },
};
const uint8_t COMP_CATALOG_N = sizeof(COMP_CATALOG) / sizeof(COMP_CATALOG[0]);

static bool char_ok(char c) {
  return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

static bool chars_ok(const char* s, size_t maxlen) {
  if (!s) return false;
  size_t n = strlen(s);
  if (n == 0 || n > maxlen) return false;
  for (size_t i = 0; i < n; i++) if (!char_ok(s[i])) return false;
  return true;
}

bool comp_entry_valid(const char* id, const char* arg) {
  if (!chars_ok(id, COMP_ID_LEN - 1)) return false;
  if (arg && *arg && !chars_ok(arg, COMP_ARG_LEN - 1)) return false;   // "" (no arg) is always fine
  return true;
}

bool comp_entry_split(const char* entry, char* id, size_t id_cap, char* arg, size_t arg_cap) {
  if (arg && arg_cap) arg[0] = '\0';
  if (!entry || !*entry || !id || id_cap == 0 || !arg || arg_cap == 0) return false;
  const char* dot = strchr(entry, '.');
  size_t idlen = dot ? (size_t)(dot - entry) : strlen(entry);
  if (idlen == 0 || idlen >= id_cap) return false;
  memcpy(id, entry, idlen);
  id[idlen] = '\0';
  if (dot) {
    const char* rest = dot + 1;
    if (!*rest) return false;              // trailing '.' with nothing after: malformed
    if (strchr(rest, '.')) return false;   // a second '.': the alphabet never contains one, so this is
                                            // corrupt input rather than a legal arg
    size_t arglen = strlen(rest);
    if (arglen >= arg_cap) return false;
    memcpy(arg, rest, arglen);
    arg[arglen] = '\0';
  }
  return true;
}

bool comp_list_equal(const comp_list_t* a, const comp_list_t* b) {
  if (!a || !b) return a == b;
  if (a->count != b->count) return false;
  for (uint8_t i = 0; i < a->count && i < COMP_SLOTS_MAX; i++) {
    if (strncmp(a->ids[i],  b->ids[i],  COMP_ID_LEN)  != 0) return false;
    if (strncmp(a->args[i], b->args[i], COMP_ARG_LEN) != 0) return false;
  }
  return true;
}

static int known_index(const char* const* known, uint8_t known_count, const char* id) {
  for (uint8_t i = 0; i < known_count; i++)
    if (known[i] && strncmp(known[i], id, COMP_ID_LEN) == 0) return (int)i;
  return -1;
}

static bool out_has(const comp_list_t* out, const char* id) {
  for (uint8_t i = 0; i < out->count; i++)
    if (strncmp(out->ids[i], id, COMP_ID_LEN) == 0) return true;
  return false;
}

// Walk `src`, placing valid + known + non-duplicate + fitting entries into `out` (already zeroed by the
// caller). Returns the slot units consumed. An entry that does not fit is dropped and the walk CONTINUES
// (rule 3) -- it never stops early and never shrinks an entry to make it fit.
static uint8_t place(const comp_list_t* src,
                     const char* const* known, const uint8_t* known_size, uint8_t known_count,
                     uint8_t slot_cap, comp_list_t* out) {
  uint8_t used = 0;
  if (!src) return used;
  for (uint8_t i = 0; i < src->count && i < COMP_SLOTS_MAX; i++) {
    const char* id  = src->ids[i];
    const char* arg = src->args[i];
    if (!id[0]) continue;
    if (!comp_entry_valid(id, arg)) continue;                 // rule 7
    int k = known_index(known, known_count, id);
    if (k < 0) continue;                                       // rule 1 (compaction falls out for free:
                                                                // we simply never write a hole into `out`)
    if (out_has(out, id)) continue;                            // rule 2: first occurrence wins
    uint8_t size = known_size[k];
    if ((uint8_t)(slot_cap - used) < size) continue;           // rule 3 / 4: doesn't fit, drop, continue
    if (out->count >= COMP_SLOTS_MAX) break;                    // structural safety; slot_cap already caps this
    snprintf(out->ids[out->count],  COMP_ID_LEN,  "%s", id);
    snprintf(out->args[out->count], COMP_ARG_LEN, "%s", arg);
    out->count++;
    used = (uint8_t)(used + size);
  }
  return used;
}

uint8_t comp_list_resolve(const comp_list_t* requested,
                          const char* const* known, const uint8_t* known_size, uint8_t known_count,
                          uint8_t slot_cap,
                          bool requested_was_explicit_empty,
                          const comp_list_t* fallback,
                          comp_list_t* out) {
  if (!out) return 0;
  memset(out, 0, sizeof(*out));
  place(requested, known, known_size, known_count, slot_cap, out);

  // Nothing usable from the request. An explicitly empty request (rule 5) is a legitimate blank face --
  // never fall back for it. Otherwise (everything present was unknown/invalid/didn't fit), fall back
  // rather than render a blank Home the user never asked for.
  if (out->count == 0 && !requested_was_explicit_empty && fallback) {
    memset(out, 0, sizeof(*out));
    place(fallback, known, known_size, known_count, slot_cap, out);
  }
  return out->count;
}

// "clock,fin.sp500,ice,agents"
size_t comp_list_serialize(const comp_list_t* l, char* buf, size_t cap) {
  if (!l || !buf || cap == 0) return 0;
  size_t n = 0;
  buf[0] = '\0';
  for (uint8_t i = 0; i < l->count && i < COMP_SLOTS_MAX; i++) {
    if (!l->ids[i][0]) continue;
    int w = l->args[i][0]
          ? snprintf(buf + n, cap - n, "%s%s.%s", n ? "," : "", l->ids[i], l->args[i])
          : snprintf(buf + n, cap - n, "%s%s",    n ? "," : "", l->ids[i]);
    if (w < 0 || (size_t)w >= cap - n) { buf[n] = '\0'; break; }   // truncate cleanly, never overrun
    n += (size_t)w;
  }
  return n;
}

void comp_list_deserialize(const char* s, comp_list_t* out) {
  if (!out) return;
  memset(out, 0, sizeof(*out));
  if (!s) return;
  const char* p = s;
  while (*p && out->count < COMP_SLOTS_MAX) {
    const char* next = strchr(p, ',');
    size_t len = next ? (size_t)(next - p) : strlen(p);
    if (len > 0) {
      char token[COMP_ENTRY_LEN * 2];   // generous local scratch; comp_entry_split enforces the real caps
      size_t copy = len < sizeof(token) - 1 ? len : sizeof(token) - 1;
      memcpy(token, p, copy);
      token[copy] = '\0';
      char id[COMP_ID_LEN], arg[COMP_ARG_LEN];
      if (comp_entry_split(token, id, sizeof(id), arg, sizeof(arg))) {
        snprintf(out->ids[out->count],  COMP_ID_LEN,  "%s", id);
        snprintf(out->args[out->count], COMP_ARG_LEN, "%s", arg);
        out->count++;
      }
      // A token that fails to split (empty, oversize id, bad dot placement) is silently dropped -- a
      // corrupt NVS blob must degrade to something resolvable, never crash.
    }
    if (!next) break;
    p = next + 1;
  }
}
