#include "fetch/series.h"
#include "fetch/parse_series.h"
#include "core/net.h"
#include "core/datastore.h"
#include "core/timekeep.h"
#include "core/fetch_task.h"
#include "config/chart.h"
#include "util/log.h"
#include <string.h>

data_err_t fetch_series(void) {
  // Yahoo 429s requests without a browser-ish UA, same as the finance rows.
  static const char* K[] = {"User-Agent"};
  static const char* V[] = {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"};
  int status = 0;
  data_err_t e = net_https_get(CHART_HOST, CHART_PATH, K, V, 1,
                               fetch_scratch(), fetch_scratch_cap(), &status);
  if (e != ERR_NONE) { ds_set_state_series(e == ERR_NO_ROUTE ? ST_OFFLINE : ST_ERROR, e); return e; }

  series_rec_t r; memset(&r, 0, sizeof(r));
  e = parse_series(fetch_scratch(), strlen(fetch_scratch()), &r);
  if (e != ERR_NONE) { ds_set_state_series(ST_ERROR, e); return e; }

  strncpy(r.id, CHART_TICKER_ID, FIN_ID_LEN - 1);
  r.hdr.last_updated = (uint32_t)timekeep_now();
  ds_set_series(&r);
  LOGI("series: %u pts, last=%.2f prev=%.2f lo=%.1f hi=%.1f",
       (unsigned)r.count, r.last, r.prev_close, r.lo, r.hi);
  return ERR_NONE;
}
