#include "core/net_lan.h"
#include "core/sonos_art.h"   // sonos_art_length_ok (Layer 1, pure -- safe to call from device code too)
#include "util/log.h"
#include <Arduino.h>
#include <WiFiClient.h>
#include <string.h>
#include <stdlib.h>
#include <strings.h>          // strncasecmp
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

// Arduino-coupled thin socket loop (deliberately NOT in [env:native]'s build_src_filter -- see the
// header comment). Every decision worth testing lives in core/sonos_art.cpp instead.

#define LAN_CONNECT_TIMEOUT_MS 3000u
#define LAN_IDLE_TIMEOUT_MS    3000u
#define LAN_HARD_ABORT_MS      8000u

// Parse "http://<host>:<port><path>" -- the ONLY shape hub_parse_sart ever accepts on the way in
// (records.h SONOS_ART_URL_LEN caps the whole url at 96 chars). Defensive only: a conforming hub never
// sends anything else, and an over-cap/wrong-scheme url is already rejected at the wire layer.
static bool parse_url(const char* url, char* host, size_t host_cap, uint16_t* port, const char** path) {
  static const char PFX[] = "http://";
  const size_t pfx_n = sizeof(PFX) - 1;
  if (strncmp(url, PFX, pfx_n) != 0) return false;
  const char* p = url + pfx_n;
  const char* colon = strchr(p, ':');
  const char* slash = strchr(p, '/');
  if (!colon || !slash || colon >= slash) return false;
  size_t hn = (size_t)(colon - p);
  if (hn == 0 || hn >= host_cap) return false;
  memcpy(host, p, hn);
  host[hn] = '\0';
  long prt = strtol(colon + 1, nullptr, 10);
  if (prt <= 0 || prt > 65535) return false;
  *port = (uint16_t)prt;
  *path = slash;   // includes the leading '/'
  return true;
}

// Read one CRLF- or LF-terminated line (CR stripped) into `line` (NUL-terminated, silently truncated
// past cap-1). Gates every wait on available() and yields IDLE0 when the socket has none (net.cpp's
// #92 cooperative-drain pattern -- a busy-spin here would starve the Core-0 task watchdog exactly like
// the bug that pattern was written to fix). Returns false on abort / stall past either deadline / the
// peer closing before a line completed.
static bool read_line(WiFiClient& cli, char* line, size_t cap,
                      uint32_t* idle_deadline, uint32_t hard_deadline, volatile bool* abort_flag) {
  size_t n = 0;
  for (;;) {
    if (abort_flag && *abort_flag) return false;
    if (cli.available() <= 0) {
      if (!cli.connected() && cli.available() <= 0) return false;   // peer closed with nothing more queued
      uint32_t now = millis();
      if ((int32_t)(now - *idle_deadline) >= 0) return false;
      if ((int32_t)(now - hard_deadline) >= 0) return false;
      vTaskDelay(pdMS_TO_TICKS(2));
      continue;
    }
    uint8_t b;
    int r = cli.read(&b, 1);
    if (r <= 0) { vTaskDelay(pdMS_TO_TICKS(2)); continue; }
    *idle_deadline = millis() + LAN_IDLE_TIMEOUT_MS;   // reset on every byte, like net.cpp's drain
    if (b == '\n') { line[n] = '\0'; return true; }
    if (b == '\r') continue;
    if (n < cap - 1) line[n++] = (char)b;
  }
}

data_err_t net_lan_get(const char* url, uint8_t* out, size_t expect_len,
                       const char** err_out, volatile bool* abort_flag) {
  if (err_out) *err_out = nullptr;
  if (!url || !out || expect_len == 0) { if (err_out) *err_out = "net"; return ERR_HTTP; }

  char host[40];
  uint16_t port;
  const char* path;
  if (!parse_url(url, host, sizeof(host), &port, &path)) {
    if (err_out) *err_out = "net";
    return ERR_HTTP;
  }

  const uint32_t hard_deadline = millis() + LAN_HARD_ABORT_MS;

  if (abort_flag && *abort_flag) { if (err_out) *err_out = "net"; return ERR_HTTP; }

  WiFiClient cli;
  uint32_t t0 = millis();
  bool connected = cli.connect(host, port, LAN_CONNECT_TIMEOUT_MS) != 0;
  uint32_t connect_elapsed = millis() - t0;
  if (!connected) {
    cli.stop();
    // A fast negative (RST-shaped: e.g. the port is closed / firewalled) returns quickly; a device-side
    // connect() that ran nearly the whole budget with no response is the TCC-denial shape (design §2.3,
    // §8) -- the Mac's OS silently drops the traffic instead of rejecting it, so the device just times
    // out. There is no socket-level signal that distinguishes these more directly than elapsed time.
    bool looks_like_timeout = connect_elapsed >= (LAN_CONNECT_TIMEOUT_MS * 8u / 10u);
    if (err_out) *err_out = looks_like_timeout ? "timeout" : "conn_refused";
    return looks_like_timeout ? ERR_TIMEOUT : ERR_NO_ROUTE;
  }

  char req[192];
  int rn = snprintf(req, sizeof(req), "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", path, host);
  if (rn <= 0 || (size_t)rn >= sizeof(req)) {
    cli.stop();
    if (err_out) *err_out = "net";
    return ERR_HTTP;
  }
  cli.write((const uint8_t*)req, (size_t)rn);

  uint32_t idle_deadline = millis() + LAN_IDLE_TIMEOUT_MS;

  // --- status line: "HTTP/1.1 200 OK" ---
  char line[128];
  if (!read_line(cli, line, sizeof(line), &idle_deadline, hard_deadline, abort_flag)) {
    cli.stop();
    if (err_out) *err_out = (abort_flag && *abort_flag) ? "net" : "timeout";
    return ERR_TIMEOUT;
  }
  int status = 0;
  { const char* sp = strchr(line, ' '); if (sp) status = atoi(sp + 1); }

  // --- headers, until the blank line; capture Content-Length ---
  long content_length = -1;
  for (;;) {
    if (!read_line(cli, line, sizeof(line), &idle_deadline, hard_deadline, abort_flag)) {
      cli.stop();
      if (err_out) *err_out = (abort_flag && *abort_flag) ? "net" : "timeout";
      return ERR_TIMEOUT;
    }
    if (line[0] == '\0') break;   // blank line => end of headers
    if (strncasecmp(line, "Content-Length:", 15) == 0) {
      content_length = strtol(line + 15, nullptr, 10);
    }
  }

  // Design §4.3 rule 3: 200 AND Content-Length == expect_len, checked BEFORE reading a byte of body.
  if (status != 200 || content_length != (long)expect_len) {
    cli.stop();
    if (err_out) *err_out = (status != 200) ? "http" : "size";
    return ERR_HTTP;
  }

  // --- body: read exactly expect_len bytes straight into `out` (zero staging, design §4.1) ---
  // Each cli.read() is capped well under 4KB so the abort flag is re-polled far more often than "once
  // per 4KB" (plan trap) even during a fast, uninterrupted transfer -- a superseded gen must stop
  // quickly, not after however much a single socket read happened to hand back.
  #define LAN_READ_CHUNK 1024u
  size_t received = 0;
  while (received < expect_len) {
    if (abort_flag && *abort_flag) { cli.stop(); return ERR_TIMEOUT; }   // caller discards on abort
    if (cli.available() <= 0) {
      if (!cli.connected() && cli.available() <= 0) break;   // peer closed early => short read, below
      uint32_t now = millis();
      if ((int32_t)(now - idle_deadline) >= 0) break;
      if ((int32_t)(now - hard_deadline) >= 0) break;
      vTaskDelay(pdMS_TO_TICKS(2));
      continue;
    }
    size_t want = expect_len - received;
    if (want > LAN_READ_CHUNK) want = LAN_READ_CHUNK;
    int n = cli.read(out + received, want);   // hard-capped at expect_len regardless of the header
    if (n <= 0) { vTaskDelay(pdMS_TO_TICKS(2)); continue; }
    received += (size_t)n;
    idle_deadline = millis() + LAN_IDLE_TIMEOUT_MS;
  }
  cli.stop();
  #undef LAN_READ_CHUNK

  if (abort_flag && *abort_flag) return ERR_TIMEOUT;   // superseded during the body read: caller discards

  if (!sonos_art_length_ok(status, content_length, received)) {
    if (err_out) *err_out = (received == 0) ? "timeout" : "size";
    return ERR_HTTP;
  }
  return ERR_NONE;
}
