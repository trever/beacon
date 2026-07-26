#pragma once
#include "core/screen_state.h"   // data_err_t

// ICE D4 RIN futures (device-plane). Public product-guide endpoint -- no key, no auth; the chain roots
// at DigiCert Global Root G2, already in ROOT_CA_BUNDLE, so no CA change was needed.
// Core-0 fetch task only (net_https_get is serialized and not UI-safe). Writes ds_set_ice on success,
// ds_set_state_ice on failure.
#ifdef __cplusplus
extern "C" {
#endif
data_err_t fetch_ice(void);
#ifdef __cplusplus
}
#endif
