#pragma once
#include <stddef.h>
#include "core/screen_state.h"
#ifdef __cplusplus
extern "C" {
#endif
// Intraday series for the graph screen (Yahoo chart). Core-0 fetch task only.
data_err_t fetch_series(void);
#ifdef __cplusplus
}
#endif

// Display name of the instrument the graph currently follows (resolved from the chart page's
// `sym` option, falling back to CHART_LABEL). Fills `out` with a NUL-terminated string.
void chart_display_label(char* out, size_t cap);
