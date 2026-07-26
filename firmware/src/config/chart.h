#pragma once

// The single-ticker graph screen tracks ONE instrument. Yahoo, same host as the finance rows, so the
// scheduler's same-host TLS reuse (#61) covers it for free.
//
// interval=15m, not 5m: the body must fit fetch_scratch() (8192 B shared). Measured 2026-07-26 --
// 5m = 7789 B (5% margin, a busier session would overflow), 15m = 3449 B. See records.h SERIES_MAX.
#define CHART_TICKER_ID   "sp500"        // matches config/tickers.h; the graph follows this row
#define CHART_SYMBOL      "%5EGSPC"      // Yahoo, percent-encoded once for the URL path
#define CHART_LABEL       "S&P 500"
#define CHART_PATH        "/v8/finance/chart/" CHART_SYMBOL "?range=1d&interval=15m"
#define CHART_HOST        "query1.finance.yahoo.com"
#define CHART_CADENCE_S   300u           // 5 min; a 15m-bucket series gains nothing from faster polling
