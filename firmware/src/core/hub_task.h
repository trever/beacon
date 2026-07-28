#pragma once
#include <stdbool.h>
#include <stdint.h>

// Hub-plane wiring (P2, Core-0). Owns the Bluedroid HubLink: pumps loop(), routes inbound status
// frames into ds_set_usage/ds_set_buddy, flips to ST_HUB_OFFLINE on disconnect, and tracks the
// running-min internal heap for the coexistence re-measure (tech.md §8). Started in the non-dev
// build alongside fetch_task; under BEACON_DEV the seed fakes the hub plane instead.
#ifdef __cplusplus
extern "C" {
#endif

void hub_task_start(void);

// Device->hub permission decision, safe to call from Core-1 (the buddy decide path). Builds the §7.1
// command frame and enqueues it via HubLink::send (which copies + is thread-safe). Returns true if
// accepted for transport. With no hub link initialized (BEACON_DEV), returns true so the on-device UI
// still clears locally for testing.
bool hub_send_permission(const char* id, bool approve);

// Device -> hub Sonos art outcome (S3, WS-2, CONTRACT.md §B4). Safe to call from any Core-0 task --
// core/sonos_art.cpp calls this from the fetch task, a DIFFERENT task than the one that owns g_link,
// same cross-task guarantee hub_send_permission already relies on from Core-1 (HubLink::send copies +
// is thread-safe). With no hub link initialized (BEACON_DEV), returns true (no-op success).
bool hub_send_sart_stat(uint32_t gen, bool ok, const char* err);

// Centralized buddy decide path (issue #8): the single place a view calls to approve/deny the active
// prompt. Applies the canonical guard (present && not hub-offline/reconnecting && not already decided),
// enqueues the §7.1 command, and on success marks the prompt PROMPT_PENDING WITHOUT clearing present --
// the prompt is cleared only later by a truthful hub ack (hub_apply_ack). Returns true if enqueued.
bool buddy_decide(bool approve);

// Dismiss a prompt the hub said did not apply (PROMPT_TOO_LATE): clears present locally so the warning
// goes away. No-op for any other state. Returns true if a prompt was dismissed.
bool buddy_dismiss(void);

// Tap-to-open: ask the hub to focus the terminal/editor for session `id` (issue #110, P2-b). Builds
// the §7.1 "open" command frame and enqueues it via HubLink::send. Returns true if accepted for
// transport. With no hub link (BEACON_DEV) returns true so the UI path can still be exercised.
bool buddy_open(const char* id);

#ifdef __cplusplus
}
#endif
