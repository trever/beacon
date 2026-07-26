#include "ui/screens/screen_finance.h"
#include "ui/chrome.h"
#include "config/ticker_table.h"

// Finance keeps its own module body (not SCREEN_MODULE_SIMPLE) because it must REBUILD on a ticker
// config change, not just update -- see below.
extern const screen_view_t finance_editorial_view;

// Track the ticker-table gen the current view was built against. A hub config swap bumps the gen
// (Core-0); the next Core-1 update tick rebuilds the view so its row count + names match the new set.
static lv_obj_t* s_page = nullptr;
static uint32_t  s_built_gen = 0;

static lv_obj_t* build(lv_obj_t* page) {
  s_page = page;
  s_built_gen = ticker_table_gen();
  finance_editorial_view.build(page);
  return page;
}

static void update(void) {
  uint32_t gen = ticker_table_gen();
  if (s_page && gen != s_built_gen) {
    // Rebuild against the new ticker set (Core-1 safe: only the existing LVGL lifecycle + accessors).
    // Views build row objects once and cache row pointers, so a count change needs a teardown, not a restyle.
    lv_obj_clean(s_page);
    chrome_attach(s_page);
    s_built_gen = gen;
    finance_editorial_view.build(s_page);
  }
  finance_editorial_view.update();
}
const screen_module_t finance_module = {"MARKETS", build, update};
