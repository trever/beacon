#include "fetch/series.h"
#include "fetch/parse_series.h"
#include "core/net.h"
#include "core/datastore.h"
#include "core/timekeep.h"
#include "core/fetch_task.h"
#include "config/chart.h"
#include "config/ticker_table.h"
#include "ui/carousel.h"
#include "util/log.h"
#include <string.h>
#include <stdio.h>

// Which instrument the graph follows. The chart page's `sym` option names a TICKER ID, not a raw symbol:
// the hub already configures the ticker table, so the Yahoo symbol and display name come from that row
// and there is no free-form text to escape or validate on the wire.
//
// Binance rows are ineligible -- this fetch speaks the Yahoo chart API only -- and anything unresolvable
// falls back to the compiled S&P default rather than leaving the page dark.
//
// The interval stays pinned at 15m regardless: the response must fit the shared 8 KB fetch_scratch(),
// where 5m measured 7789 B against 15m's 3449 B (config/chart.h). It is not a user option.
static void resolve_chart(char* path, size_t path_cap, char* id, size_t id_cap,
                          char* label, size_t label_cap) {
  snprintf(path,  path_cap,  "%s", CHART_PATH);
  snprintf(id,    id_cap,    "%s", CHART_TICKER_ID);
  snprintf(label, label_cap, "%s", CHART_LABEL);

  char want[FIN_ID_LEN];
  if (!carousel_page_opt("chart", "sym", want, sizeof(want)) || !want[0]) return;

  for (int i = 0, n = ticker_table_count(); i < n; i++) {
    ticker_runtime_t t;
    if (!ticker_table_get(i, &t)) continue;
    if (strncmp(t.id, want, FIN_ID_LEN) != 0) continue;
    if (t.source != SRC_YAHOO) {
      LOGW("chart: ticker '%s' is not a Yahoo row; keeping %s", want, CHART_TICKER_ID);
      return;
    }
    snprintf(path,  path_cap,  "/v8/finance/chart/%s?range=1d&interval=15m", t.symbol);
    snprintf(id,    id_cap,    "%s", t.id);
    snprintf(label, label_cap, "%s", t.name[0] ? t.name : t.id);
    return;
  }
  LOGW("chart: ticker '%s' not in the table; keeping %s", want, CHART_TICKER_ID);
}

// The resolved display name, for the screen header. Cheap enough to recompute; the table is in RAM.
void chart_display_label(char* out, size_t cap) {
  char path[160], id[FIN_ID_LEN];
  resolve_chart(path, sizeof(path), id, sizeof(id), out, cap);
}

data_err_t fetch_series(void) {
  // Yahoo 429s requests without a browser-ish UA, same as the finance rows.
  static const char* K[] = {"User-Agent"};
  static const char* V[] = {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"};
  char path[160], tid[FIN_ID_LEN], label[TKR_NAME_LEN];
  resolve_chart(path, sizeof(path), tid, sizeof(tid), label, sizeof(label));

  int status = 0;
  data_err_t e = net_https_get(CHART_HOST, path, K, V, 1,
                               fetch_scratch(), fetch_scratch_cap(), &status);
  if (e != ERR_NONE) { ds_set_state_series(e == ERR_NO_ROUTE ? ST_OFFLINE : ST_ERROR, e); return e; }

  series_rec_t r; memset(&r, 0, sizeof(r));
  e = parse_series(fetch_scratch(), strlen(fetch_scratch()), &r);
  if (e != ERR_NONE) { ds_set_state_series(ST_ERROR, e); return e; }

  strncpy(r.id, tid, FIN_ID_LEN - 1);
  r.hdr.last_updated = (uint32_t)timekeep_now();
  ds_set_series(&r);
  LOGI("series: %u pts, last=%.2f prev=%.2f lo=%.1f hi=%.1f",
       (unsigned)r.count, r.last, r.prev_close, r.lo, r.hi);
  return ERR_NONE;
}
