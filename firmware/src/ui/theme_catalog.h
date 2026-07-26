#pragma once
#include <stdint.h>
#include "ui/gauge_style.h"

// LVGL-free catalog data (host-testable). theme.cpp maps this -> beacon_theme_t (lv_color_t/lv_font_t).
// DESIGN.md owns token VALUES; only Editorial has full hex there, so the other six are concrete
// realizations of DESIGN.md's named accents (tunable on hardware in the Task 9 demo). bg is always
// pure black (AMOLED off-pixels). The ids + gauge mapping + struct are the frozen part.

typedef struct { uint8_t r, g, b; } bt_rgb_t;

typedef struct {
  const char*   id;                 // canonical id (DESIGN.md)
  bt_rgb_t      bg, ink, ink_dim, line, accent, accent2, up, down, alert;
  gauge_style_t gauge;
  uint8_t       glow;               // 0..255
  uint8_t       radius;             // element corner radius (px)
  uint8_t       stroke_hair, stroke_med;
} theme_catalog_t;

#define THEME_COUNT 1
// Single theme (2026-07-26): the other six were removed to reclaim flash -- each carried its own
// hero/display/body font subsets and six per-screen views. Re-adding one means a catalog row, a
// THEME_FONTS row, a SCREEN_MODULE_SIMPLE entry, a chrome kind, and one view per screen
// (docs/recipes.md 3).
#define DEFAULT_THEME_INDEX 0   // editorial
// Bump when DEFAULT_THEME_INDEX changes so the carousel re-applies it once (see carousel_init).
// Bumped to 2 when the catalog collapsed to editorial: a device holding a stored index of 2
// (dotmatrix) must land back on 0 rather than be silently clamped every boot.
#define THEME_DEFAULT_VER   2

static const theme_catalog_t THEME_CATALOG[THEME_COUNT] = {
  // Editorial Index (default) — DESIGN.md exact values
  { "editorial",
    {0,0,0}, {244,243,239}, {116,114,108}, {36,36,34}, {255,74,43}, {255,74,43},
    {244,243,239}, {255,74,43}, {255,74,43}, GAUGE_BAR, 0, 0, 1, 2 },
};
