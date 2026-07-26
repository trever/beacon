#include <unity.h>
#include "core/button.h"

void setUp(void) {} void tearDown(void) {}

// A raw press must not register until it has held for BTN_STABLE_MS.
static void test_press_requires_settle(void) {
  btn_state_t b = {};
  TEST_ASSERT_FALSE(btn_poll(&b, false, 0));            // seed
  TEST_ASSERT_FALSE(btn_poll(&b, true, 10));            // pressed, not settled
  TEST_ASSERT_FALSE(btn_poll(&b, true, 10 + BTN_STABLE_MS - 1));
  TEST_ASSERT_TRUE(btn_poll(&b, true, 10 + BTN_STABLE_MS));
}

// Contact chatter inside the window restarts it, so one physical press yields one event.
static void test_chatter_yields_single_press(void) {
  btn_state_t b = {};
  btn_poll(&b, false, 0);
  int presses = 0;
  uint32_t t = 10;
  for (int i = 0; i < 6; i++) { if (btn_poll(&b, i & 1, t)) presses++; t += 5; }   // bouncing
  for (int i = 0; i < 10; i++) { if (btn_poll(&b, true, t)) presses++; t += 10; }  // then held
  TEST_ASSERT_EQUAL_INT(1, presses);
}

// Holding must not repeat: this drives "advance one page", not a key-repeat.
static void test_hold_does_not_repeat(void) {
  btn_state_t b = {};
  btn_poll(&b, false, 0);
  int presses = 0;
  for (uint32_t t = 10; t < 5000; t += 10) if (btn_poll(&b, true, t)) presses++;
  TEST_ASSERT_EQUAL_INT(1, presses);
}

// Release then press again is a second event.
static void test_release_then_press_again(void) {
  btn_state_t b = {};
  btn_poll(&b, false, 0);
  int presses = 0;
  for (uint32_t t = 10; t < 200; t += 10) if (btn_poll(&b, true, t)) presses++;
  for (uint32_t t = 200; t < 400; t += 10) if (btn_poll(&b, false, t)) presses++;   // release: no event
  for (uint32_t t = 400; t < 600; t += 10) if (btn_poll(&b, true, t)) presses++;
  TEST_ASSERT_EQUAL_INT(2, presses);
}

// A button already held at boot must never read as a deliberate press -- BOOT doubles as the
// download-mode pin, so it can legitimately be held while the device starts.
static void test_held_at_boot_is_not_a_press(void) {
  btn_state_t b = {};
  int presses = 0;
  for (uint32_t t = 0; t < 2000; t += 10) if (btn_poll(&b, true, t)) presses++;
  TEST_ASSERT_EQUAL_INT(0, presses);
}

// Release edges never report.
static void test_release_never_reports(void) {
  btn_state_t b = {};
  btn_poll(&b, true, 0);   // seeded pressed
  int presses = 0;
  for (uint32_t t = 10; t < 500; t += 10) if (btn_poll(&b, false, t)) presses++;
  TEST_ASSERT_EQUAL_INT(0, presses);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_press_requires_settle);
  RUN_TEST(test_chatter_yields_single_press);
  RUN_TEST(test_hold_does_not_repeat);
  RUN_TEST(test_release_then_press_again);
  RUN_TEST(test_held_at_boot_is_not_a_press);
  RUN_TEST(test_release_never_reports);
  return UNITY_END();
}
