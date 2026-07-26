#include <unity.h>
#include <string.h>
#include "ui/theme_catalog.h"   // LVGL-free; the device beacon_theme_t (theme.h) wraps this

void setUp(void) {}
void tearDown(void) {}

// Single-theme catalog since 2026-07-26 (the other six were removed to reclaim flash). The asserts
// below are written over THEME_COUNT rather than fixed 7-element lists, so re-adding a theme only
// needs its id/gauge appended to `expect`.
static void test_catalog_count(void) {
  TEST_ASSERT_EQUAL_INT(1, THEME_COUNT);
}

// ids match the DESIGN.md canonical set, in order, unique.
static void test_catalog_ids(void) {
  const char* expect[] = { "editorial" };
  TEST_ASSERT_EQUAL_INT((int)(sizeof(expect) / sizeof(expect[0])), THEME_COUNT);
  for (int i = 0; i < THEME_COUNT; i++) {
    TEST_ASSERT_NOT_NULL(THEME_CATALOG[i].id);
    TEST_ASSERT_EQUAL_STRING(expect[i], THEME_CATALOG[i].id);
    for (int j = i + 1; j < THEME_COUNT; j++)
      TEST_ASSERT_TRUE(strcmp(THEME_CATALOG[i].id, THEME_CATALOG[j].id) != 0);
  }
}

// every theme is pure-black canvas (AMOLED) and carries a valid gauge style.
static void test_catalog_invariants(void) {
  for (int i = 0; i < THEME_COUNT; i++) {
    const theme_catalog_t* t = &THEME_CATALOG[i];
    TEST_ASSERT_EQUAL_UINT8(0, t->bg.r);
    TEST_ASSERT_EQUAL_UINT8(0, t->bg.g);
    TEST_ASSERT_EQUAL_UINT8(0, t->bg.b);
    TEST_ASSERT_TRUE(t->gauge >= GAUGE_BAR && t->gauge <= GAUGE_SUBDIAL);
  }
}

// gauge style per DESIGN.md catalog (the frozen mapping).
static void test_catalog_gauge_mapping(void) {
  gauge_style_t expect[] = { GAUGE_BAR };
  TEST_ASSERT_EQUAL_INT((int)(sizeof(expect) / sizeof(expect[0])), THEME_COUNT);
  for (int i = 0; i < THEME_COUNT; i++)
    TEST_ASSERT_EQUAL_INT(expect[i], THEME_CATALOG[i].gauge);
}

// The default must be a real index, and the migration version must be past the collapse so a device
// holding a stored index from the 7-theme era lands back on editorial instead of clamping every boot.
static void test_default_and_migration(void) {
  TEST_ASSERT_TRUE(DEFAULT_THEME_INDEX < THEME_COUNT);
  TEST_ASSERT_TRUE(THEME_DEFAULT_VER >= 2);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_catalog_count);
  RUN_TEST(test_catalog_ids);
  RUN_TEST(test_catalog_invariants);
  RUN_TEST(test_catalog_gauge_mapping);
  RUN_TEST(test_default_and_migration);
  return UNITY_END();
}
