#pragma once
#include "ui/screen.h"
#include "ui/theme.h"

// Generates the boilerplate for a simple screen module. With a single-theme catalog this is a
// direct call to the editorial view; it kept a theme_index()-keyed table when there were seven. `PREFIX` is the view name prefix (e.g. home), `ID` is
// the carousel label (e.g. "HOME"), `MODULE` is the exported module symbol name.
//
// Usage (in a .cpp that includes the theme view externs):
//   SCREEN_MODULE_SIMPLE(home, "HOME", home_module)
//
// Expands to:
//   extern const screen_view_t home_editorial_view, ...;
//   static const screen_view_t* V[] = { &home_editorial_view, ... };
//   static lv_obj_t* build(lv_obj_t* page) { V[theme_index()]->build(page); return page; }
//   static void update(void) { V[theme_index()]->update(); }
//   const screen_module_t home_module = { "HOME", build, update };

#define SCREEN_MODULE_SIMPLE(PREFIX, ID, MODULE)                                    \
  extern const screen_view_t PREFIX##_editorial_view;                                \
  static lv_obj_t* build(lv_obj_t* page) { PREFIX##_editorial_view.build(page); return page; } \
  static void update(void) { PREFIX##_editorial_view.update(); }                     \
  const screen_module_t MODULE = {ID, build, update}
