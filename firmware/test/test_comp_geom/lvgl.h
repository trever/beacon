#pragma once
// Minimal host-only stand-in for the real LVGL header, used ONLY so this test can include
// ui/comps/comp_registry.h (a WS-0 file this workstream must not edit) without pulling the real
// LVGL library into [env:native] (plan §4 "no LVGL" for this suite). comp_registry.h only needs
// `lv_obj_t` as a type name for its function-pointer typedefs (comp_build_fn/comp_update_fn) --
// it never dereferences or constructs one here, so an opaque forward declaration is sufficient.
// This file is NOT visible outside this test directory and never ships.
typedef struct lv_obj_t lv_obj_t;
