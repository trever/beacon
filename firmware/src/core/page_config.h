#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// Which pages the carousel shows, and in what order -- chosen on the hub, persisted in NVS, applied
// without reflashing (design docs/specs/2026-07-26-hub-as-controller-and-sonos-design.md §2).
//
// Pages are identified by a STABLE STRING ID, never an index. carousel.cpp used to carry a
// `#define BUDDY_INDEX`, which was wrong or moved four times as screens came and went; an id survives
// insertion, removal and reordering by construction.
//
// Pure + freestanding so the whole resolve step is host-tested; NVS and LVGL live in the caller.

#define PAGES_MAX      8    // s_pages[]/s_dots[] in carousel.cpp are fixed at 8
#define PAGE_ID_LEN   12    // 11 chars + NUL
#define PAGE_OPTS_LEN 48    // "k:v;k:v" per page + NUL

typedef struct {
  char    ids[PAGES_MAX][PAGE_ID_LEN];
  // Per-page options as a compact "k:v;k:v" string -- a tiny format rather than JSON so the device
  // stores and re-serializes it without a parser. Keys and values carry none of the separators
  // (: ; | = ,); both ends strip them, so a value can never split a record.
  char    opts[PAGES_MAX][PAGE_OPTS_LEN];
  uint8_t count;
} page_list_t;

// Read one option out of a "k:v;k:v" string. Returns false (and empties `out`) when absent.
bool page_opts_get(const char* opts, const char* key, char* out, size_t cap);

// The opts string for `id`, or "" when the page is absent or carries none.
const char* page_list_opts(const page_list_t* l, const char* id);

// Set the opts string for an existing page. Separators are stripped from `opts`, which is then
// truncated to PAGE_OPTS_LEN-1. No-op when the id is not present.
void page_list_set_opts(page_list_t* l, const char* id, const char* opts);

// Append `id` if it is not already present and there is room. Returns false when full or duplicate.
bool page_list_add(page_list_t* l, const char* id);

bool page_list_contains(const page_list_t* l, const char* id);

// Resolve a REQUESTED list (from the hub, or restored from NVS) against the ids this firmware actually
// has, producing the list the carousel should build. The rules exist to make a bad config non-fatal:
//
//  - Unknown ids are DROPPED, not rejected. A newer hub may name a page this firmware does not carry;
//    ignoring it keeps an older device usable instead of bricking its page set.
//  - Duplicates collapse to their first occurrence.
//  - `always_id` (settings) is force-appended when missing, so no configuration can leave the device
//    with no way to reach its own settings. Pass NULL to disable.
//  - An empty or fully-unknown request falls back to `fallback` -- never to a blank carousel.
//
// `known` is the registry's id list. Returns the number of pages in *out.
uint8_t page_list_resolve(const page_list_t* requested,
                          const char* const* known, uint8_t known_count,
                          const char* always_id,
                          const page_list_t* fallback,
                          page_list_t* out);

// NVS round-trip: the list is stored as a comma-joined id string ("home,chart,agents,settings").
// Writes at most `cap` bytes including NUL; returns the length written (excl. NUL), or 0 on bad args.
size_t page_list_serialize(const page_list_t* l, char* buf, size_t cap);

// Parse a comma-joined id string. Tolerates empty fields, leading/trailing commas and over-long ids
// (truncated to PAGE_ID_LEN-1) -- a corrupt NVS blob must degrade to a resolvable list, not a crash.
void page_list_deserialize(const char* s, page_list_t* out);
