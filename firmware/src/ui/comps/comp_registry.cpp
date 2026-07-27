#include "ui/comps/comp_registry.h"
#include <string.h>

// The COMP_REGISTRY[] array + comp_find() (plan §4 "What to build" item 1's header, this file). Each
// renderer file exports one `extern const complication_t comp_<id>_reg`, the same one-export-per-file
// idiom views use for `extern const screen_view_t <screen>_<theme>_view` (views/CONVENTIONS.md) -- this
// file only aggregates those externs into the array comp_find() walks.
//
// `chart` is deliberately ABSENT: its renderer is Phase 2 (plan §4 traps / core/complications.h). With
// no comp_chart.cpp, comp_find("chart") correctly returns NULL, so comp_list_resolve's caller (built
// from whichever COMP_CATALOG entries comp_find() answers non-NULL for) never offers "chart" as known,
// and the resolver drops any "chart" placement a newer hub might push -- the correct Phase 1 behaviour.
extern const complication_t comp_clock_reg;
extern const complication_t comp_fin_reg;
extern const complication_t comp_ice_reg;
extern const complication_t comp_agents_reg;
extern const complication_t comp_usage_reg;
extern const complication_t comp_weather_reg;
extern const complication_t comp_sonos_reg;

const complication_t COMP_REGISTRY[] = {
  comp_clock_reg,
  comp_fin_reg,
  comp_ice_reg,
  comp_agents_reg,
  comp_usage_reg,
  comp_weather_reg,
  comp_sonos_reg,
};
const uint8_t COMP_REGISTRY_N = (uint8_t)(sizeof(COMP_REGISTRY) / sizeof(COMP_REGISTRY[0]));

const complication_t* comp_find(const char* id) {
  if (!id) return nullptr;
  for (uint8_t i = 0; i < COMP_REGISTRY_N; i++)
    if (COMP_REGISTRY[i].id && strcmp(COMP_REGISTRY[i].id, id) == 0) return &COMP_REGISTRY[i];
  return nullptr;
}
