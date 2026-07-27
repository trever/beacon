#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// The Home-screen "complication" assignment: which small renderers occupy the six-slot grid, and in
// what order (design docs/specs/2026-07-27-hub-app-and-home-complications-design.md §4). Mirrors
// core/page_config.h in shape -- a reader who knows one knows the other -- but resolves against SLOT
// UNITS rather than a flat count, because the clock spans two slots.
//
// Pure + freestanding C (no LVGL, no Arduino): this whole resolve step is host-tested in [env:native].
// NVS and LVGL live in the caller (carousel.cpp / ui/comps/*, both WS-1).

#define COMP_SLOTS_MAX   6     // per face; the geometry cap derived in design §5.3
#define COMP_FACES_MAX   2     // wire cap; only "home" exists today (design §6.1)
#define COMP_ID_LEN     12     // 11 chars + NUL
#define COMP_ARG_LEN    16     // 15 chars + NUL
#define COMP_ENTRY_LEN  28     // "id.arg" = 11 + 1(.) + 15 + NUL

typedef struct {
  char    ids [COMP_SLOTS_MAX][COMP_ID_LEN];
  char    args[COMP_SLOTS_MAX][COMP_ARG_LEN];   // "" = no arg supplied
  uint8_t count;               // PLACEMENTS, not slot units -- a placed clock is still one entry here
} comp_list_t;

// Static, LVGL-free mirror of what this firmware CAN draw, independent of what it actually has a
// renderer for. THE single source of truth for `size` and `takes_arg` on the device -- ui/comps/
// comp_registry.cpp (WS-1, LVGL-coupled, not host-tested) reads size/takes_arg from HERE and never
// re-states them, so the two cannot drift (plan §13 item 1, settled: do not add `size` back onto
// `complication_t`).
typedef struct { const char* id; uint8_t size; bool takes_arg; } comp_def_t;
extern const comp_def_t COMP_CATALOG[];
extern const uint8_t    COMP_CATALOG_N;

// Charset + length, both ends (device and hub validate the same alphabet): `id` <= 11 chars from
// [a-z0-9_-]; `arg` may be "" (no arg) or <= 15 chars from the same alphabet. Neither charset is
// JSON-escapable, which is why character caps bound the wire frame's bytes exactly (design §6.2) --
// there is no encode-measure-shrink loop here, unlike SessionDetailsFrame's free-form text fields.
bool comp_entry_valid(const char* id, const char* arg);

// Split a wire/NVS token ("fin.sp500" or "clock") into `id`/`arg`. `.` is the only separator; a token
// with no '.' has an empty arg. Returns false (leaves `arg` empty, `id` undefined) for anything that
// cannot be split structurally: empty input, an id that does not fit `id_cap`, a trailing '.' with
// nothing after it, or a second '.' (the id/arg alphabet itself never contains '.', so two dots means
// corrupt input, not a legal arg containing one). This is a STRUCTURAL check only -- charset validity
// is comp_entry_valid's job, called separately by comp_list_resolve (rule 7 below).
bool comp_entry_split(const char* entry, char* id, size_t id_cap, char* arg, size_t arg_cap);

// Same placements, same order, same args. Used to make applying a comps frame IDEMPOTENT: the hub
// re-pushes the current assignment on every reconnect, and comp_stack_apply() (WS-1) no-ops when the
// resolved list already equals the active one.
bool comp_list_equal(const comp_list_t* a, const comp_list_t* b);

// Resolve a REQUESTED list (from the hub, or restored from NVS) against the ids this firmware actually
// has a renderer for, producing the list the Home stack should build. `known`/`known_size`/`known_count`
// name the renderer set and its per-id slot span (WS-1 builds these from comp_find()+COMP_CATALOG);
// `slot_cap` is COMP_SLOTS_MAX. Rules (design §4.3, verbatim -- do not re-derive them):
//
//  1. An unknown id is DROPPED, not rejected, and the remaining entries compact upward. A newer hub may
//     name a complication this firmware has no renderer for (e.g. "chart" in Phase 1); ignoring it keeps
//     the device usable instead of leaving a hole.
//  2. Duplicate ids collapse to the FIRST occurrence, regardless of arg. One instance per id (owner
//     decision): a differing arg does NOT make a second placement legal.
//  3. An entry that does not fit the remaining slot units is DROPPED, and the walk CONTINUES -- a later
//     1-slot entry may still fit where an earlier 2-slot one did not. Never degraded to a smaller size.
//  4. Over the total capacity, the tail truncates. There is no `too_many` error -- this falls out of
//     rule 3 applied to the end of the list.
//  5. An explicitly empty request (`requested_was_explicit_empty` true) is HONOURED and resolves to 0
//     placements -- a legitimate (if austere) face. A non-empty request that resolves to 0 (everything in
//     it was unknown/invalid/didn't fit) falls back to `fallback`. This is why the flag is explicit
//     rather than inferred from `requested->count`: a request of 3 unknown ids also arrives with a
//     resolved count of 0 and must behave differently from `[]` (plan §13 item 2, settled).
//  6. `owner` is NEVER consulted here -- it is hub metadata (ui/comps/comp_registry.h), and the device
//     does not know or care whether the owning page is enabled. A resolver that checks this would defeat
//     the whole feature (a complication's entire point is surviving its page being hidden).
//  7. An entry whose id or arg fails comp_entry_valid is dropped (both ends validate the same alphabet).
//
// Returns the number of placements in *out (0..slot_cap worth of entries, never more units than
// slot_cap allows).
uint8_t comp_list_resolve(const comp_list_t* requested,
                          const char* const* known, const uint8_t* known_size, uint8_t known_count,
                          uint8_t slot_cap,               /* COMP_SLOTS_MAX */
                          bool requested_was_explicit_empty,
                          const comp_list_t* fallback,
                          comp_list_t* out);

// NVS round-trip: comma-joined "id" or "id.arg" tokens ("clock,fin.sp500,ice,agents"). Writes at most
// `cap` bytes including NUL; returns the length written (excl. NUL), or 0 on bad args.
size_t comp_list_serialize(const comp_list_t* l, char* buf, size_t cap);

// Parse a comma-joined token string. Tolerates empty fields and leading/trailing commas; a token that
// does not split structurally (comp_entry_split returns false) is silently dropped -- a corrupt NVS blob
// must degrade to something resolvable, never crash or overrun. Charset validity is NOT checked here
// (that is resolve's job, rule 7) so a garbage-but-structurally-shaped token still reaches resolve and is
// dropped there, exactly as a garbage wire entry would be.
void comp_list_deserialize(const char* s, comp_list_t* out);
