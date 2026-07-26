#include "fetch/ice.h"
#include "fetch/parse_ice.h"
#include "core/net.h"
#include "core/datastore.h"
#include "core/timekeep.h"
#include "core/fetch_task.h"
#include "config/ice.h"
#include "util/log.h"
#include <string.h>

data_err_t fetch_ice(void) {
  int status = 0;
  data_err_t e = net_https_get(ICE_HOST, ICE_CONTRACT_PATH, nullptr, nullptr, 0,
                               fetch_scratch(), fetch_scratch_cap(), &status);
  if (e != ERR_NONE) { ds_set_state_ice(e == ERR_NO_ROUTE ? ST_OFFLINE : ST_ERROR, e); return e; }

  ice_rec_t r; memset(&r, 0, sizeof(r));
  e = parse_ice(fetch_scratch(), strlen(fetch_scratch()), &r);
  if (e != ERR_NONE) { ds_set_state_ice(ST_ERROR, e); return e; }

  r.hdr.last_updated = (uint32_t)timekeep_now();
  ds_set_ice(&r);   // forces ST_LIVE / ERR_NONE
  // The front-month quote is the whole point of the screen; logging it makes a blank or wrong screen
  // diagnosable from the serial log alone (public market data -- nothing sensitive).
  if (r.count) LOGI("ice: %u contract(s), front %s=%.4f (%+.2f%%)",
                    (unsigned)r.count, r.c[0].strip, r.c[0].last, r.c[0].change_pct);
  else         LOGW("ice: 200 OK but no contracts listed (check productId/hubId in config/ice.h)");
  return ERR_NONE;
}
