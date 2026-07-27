#include <unity.h>
#include "config/layout.h"        // SAFE_INSET -- LVGL-free
#include "ui/comps/comp_registry.h"

// Pure host test over the Home complication geometry (plan
// docs/plans/2026-07-27-home-complications-plan.md §4 item 8 / §7). No LVGL: this directory ships a
// stand-in lvgl.h (test/test_comp_geom/lvgl.h) so ui/comps/comp_registry.h's typedefs compile without
// the real library -- this suite only exercises the header's integer geometry, never a widget.
//
// This is the hardware-free half of the pixel-preserving proof (§7): every container-local offset in
// comp_registry.h's offset table must reproduce home_editorial.cpp's shipped absolute coordinates,
// through the formula container_top(slot) + local_y == absolute_y, where
// container_top(slot) = comp_slot_anchor(slot) + COMP_BAND_TOP_DY.

void setUp(void) {} void tearDown(void) {}

static int container_top(uint8_t slot) { return comp_slot_anchor(slot) + COMP_BAND_TOP_DY; }

// The six anchors, verbatim from the plan and comp_registry.h's own comment.
static void test_anchor_values(void) {
  const int expect[6] = { 68, 130, 192, 254, 316, 378 };
  for (uint8_t n = 1; n <= 6; n++)
    TEST_ASSERT_EQUAL_INT(expect[n - 1], comp_slot_anchor(n));
}

// The pitch between consecutive anchors is the single constant COMP_SLOT_PITCH -- if a renderer or the
// stack ever hardcoded a per-slot delta instead of reading the shared constant, this catches the drift.
static void test_pitch_is_constant_between_anchors(void) {
  for (uint8_t n = 1; n < 6; n++)
    TEST_ASSERT_EQUAL_INT(COMP_SLOT_PITCH, comp_slot_anchor(n + 1) - comp_slot_anchor(n));
}

// COMP_BAND_TOP_DY is the one constant every renderer and the stack must share to place a container's
// top relative to its anchor; a hardcoded -14 anywhere else (instead of reading this) would drift
// invisibly the next time the band offset changes.
static void test_band_top_dy_value(void) {
  TEST_ASSERT_EQUAL_INT(-14, COMP_BAND_TOP_DY);
  TEST_ASSERT_EQUAL_INT(COMP_SLOT_A1 + COMP_BAND_TOP_DY, container_top(1));
}

// Safe-area bounds on the first/last slot (design §5.3): slot 1's rule must not creep above the header
// band; slot 6's ink must stay inside SAFE_INSET's bottom edge (466 - 40 = 426).
static void test_slot_bounds_inside_safe_area(void) {
  TEST_ASSERT_TRUE(comp_slot_anchor(1) - 4 >= 60);
  TEST_ASSERT_TRUE(comp_slot_anchor(6) + 46 <= 426);
}

// clock (slots 1-2): hero at local y 4, date at local y 96.
static void test_clock_offsets_match_shipped(void) {
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 18,  container_top(1) + 4);    // hero
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 110, container_top(1) + 96);   // date
}

// S&P 500 (shape A, slot 3, anchor 192): rule/name/value/pct at local y 0/18/10/40.
static void test_shape_a_slot3_offsets_match_shipped(void) {
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 152 - 14, container_top(3) + 0);    // rule
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 152 + 4,  container_top(3) + 18);   // name
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 152 - 4,  container_top(3) + 10);   // value
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 152 + 26, container_top(3) + 40);   // pct
}

// D4 RIN (shape A, slot 4, anchor 254): same locals, next slot up.
static void test_shape_a_slot4_offsets_match_shipped(void) {
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 214 - 14, container_top(4) + 0);    // rule
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 214 + 4,  container_top(4) + 18);   // name
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 214 - 4,  container_top(4) + 10);   // value
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 214 + 26, container_top(4) + 40);   // pct
}

// Claude / agents (shape B, slot 5, anchor 316): rule/icon/line1 unchanged; line2 is the ONE
// intentional 4 px move (346 -> 342) called out in plan §4/§7 -- assert the NEW position, and that it
// differs from the OLD one, so a future edit cannot silently drift back or move further.
static void test_shape_b_slot5_offsets_match_shipped(void) {
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 262, container_top(5) + 0);     // rule
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 280, container_top(5) + 18);    // icon
  TEST_ASSERT_EQUAL_INT(SAFE_INSET + 276, container_top(5) + 14);    // line 1
  const int old_line2 = SAFE_INSET + 306;   // 346 -- today's shipped position, pre-refactor
  const int new_line2 = container_top(5) + 40;
  TEST_ASSERT_EQUAL_INT(342, new_line2);
  TEST_ASSERT_NOT_EQUAL(old_line2, new_line2);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_anchor_values);
  RUN_TEST(test_pitch_is_constant_between_anchors);
  RUN_TEST(test_band_top_dy_value);
  RUN_TEST(test_slot_bounds_inside_safe_area);
  RUN_TEST(test_clock_offsets_match_shipped);
  RUN_TEST(test_shape_a_slot3_offsets_match_shipped);
  RUN_TEST(test_shape_a_slot4_offsets_match_shipped);
  RUN_TEST(test_shape_b_slot5_offsets_match_shipped);
  return UNITY_END();
}
