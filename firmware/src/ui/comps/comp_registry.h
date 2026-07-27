#pragma once
#include <lvgl.h>
#include "core/complications.h"

// The renderer contract (WS-1 writes comp_registry.cpp: the COMP_REGISTRY[] array + comp_find) and the
// six-slot Home geometry every renderer aligns against
// (design docs/specs/2026-07-27-hub-app-and-home-complications-design.md §5, §7).
//
// HEADER ONLY -- no comp_registry.cpp in this change. `size`/`takes_arg` deliberately do NOT live on
// `complication_t`: COMP_CATALOG (core/complications.h) is their only home. This file is LVGL-coupled
// (comp_registry.cpp will link lv_obj_t) and cannot be host-tested, so a fact duplicated here would
// drift silently until a slot rendered at the wrong span (plan §13 item 1, settled).

typedef void (*comp_build_fn)(lv_obj_t* slot);   // slot = a transparent container, already sized/placed
typedef void (*comp_update_fn)(void);

typedef struct {
  const char*    id;       // wire id; must match a COMP_CATALOG entry
  const char*    owner;    // page id that provides it; "" for core. HUB METADATA -- never a gate. Never
                           // consulted by comp_list_resolve, and no renderer/registry code may consult
                           // it either (a complication's entire point is surviving its page being hidden).
  const char*    label;    // default display name (hub UI + on-device row label fallback)
  comp_build_fn  build;
  comp_update_fn update;
} complication_t;

extern const complication_t COMP_REGISTRY[];
extern const uint8_t        COMP_REGISTRY_N;

// NULL when this firmware has no renderer for `id` (e.g. "chart" in Phase 1, or an id a newer hub
// invented that this build predates). comp_list_resolve's caller builds its `known[]`/`known_size[]`
// arrays from whichever COMP_CATALOG entries comp_find() answers non-NULL for -- the unknown-id rule,
// one level in.
const complication_t* comp_find(const char* id);

// --- Geometry: the six-slot grid on Home, 466x466 panel, SAFE_INSET 40 (design §5.3) ---
#define COMP_SLOT_PITCH   62
#define COMP_SLOT_A1      68     // anchors: 68 130 192 254 316 378
#define COMP_BAND_TOP_DY (-14)   // a placement's container top, relative to its anchor (the hairline
                                 // rule's local y is 0 -- see the offset table below)
// n = 1..6 (the FIRST slot a placement occupies; a 2-slot complication also covers slot n+1).
static inline int comp_slot_anchor(uint8_t n) { return COMP_SLOT_A1 + COMP_SLOT_PITCH * (n - 1); }

// Container-local element offsets (absolute y minus the container's top; design §7 derives these and
// proves they reproduce home_editorial.cpp's shipped pixels exactly, apart from the one intentional 4 px
// move on shape-B line 2). A renderer's build()/update() must position elements at exactly these LOCAL
// offsets -- do not re-derive them per renderer, and do not hardcode the equivalent page-absolute
// coordinate (the whole point of a container is that renderers stop caring which slot they landed in).
//
//   Element                     Local y   Local x                                   Style
//   ------------------------------------------------------------------------------------------------
//   separator rule (386 x 1)    0         0                                         S.hairline
//   shape-A name                18        0 (TOP_LEFT)                              S.slot
//   shape-A value                10        0 (TOP_RIGHT)                             S.display
//   shape-A change %             40        0 (TOP_RIGHT)                             S.slot
//   shape-A trend glyph         --        align_to(pct, OUT_LEFT_MID, -6, 0)         t->f_icon
//   shape-B icon                18        0                                         t->f_icon
//   shape-B line 1                14        26, width 356, LONG_DOT                   S.body
//   shape-B line 2                40        26, width 356, LONG_DOT                   S.slot
//   clock hero                    4        0                                         S.hero
//   clock meridiem               --        align_to(hero, OUT_RIGHT_BOTTOM, 8, -14)  S.slot
//   clock date                   96        0                                         S.slot
//
// The STACK (ui/comps/comp_stack.cpp), not the renderer, decides the separator rule: no rule when a
// placement starts at slot 1 (nothing above it to separate from -- a rule there would land in the header
// band); every other placement draws one at local y 0.
