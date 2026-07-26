#pragma once
#include "core/screen_state.h"
#ifdef __cplusplus
extern "C" {
#endif
// Intraday series for the graph screen (Yahoo chart). Core-0 fetch task only.
data_err_t fetch_series(void);
#ifdef __cplusplus
}
#endif
