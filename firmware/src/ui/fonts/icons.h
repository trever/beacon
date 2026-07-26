#pragma once

// Lucide icon glyphs, subset into lucide_14 / lucide_22 (fonts.h) from the official lucide webfont
// (npm lucide-static, font/lucide.ttf + font/info.json). Regenerate with:
//
//   npm pack lucide-static@latest && tar xzf lucide-static-*.tgz package/font
//   npx -y lv_font_conv@1.5.3 --font package/font/lucide.ttf --size <14|22> --bpp 4 --format lvgl \
//     --range "<comma-separated codepoints below>" --lv-font-name lucide_<size> -o font_lucide_<size>.c
//
// These are Private Use Area codepoints, so they only render in a lucide face -- never set an ICON_*
// string on a label styled with a text font, and never concatenate one into a text string. Use a
// separate label styled with t->f_icon / t->f_icon_lg (that is also why fmt_change_num exists: the
// number and its trend glyph live in different fonts and cannot share a label).
//
// Adding one: look up its `encodedCode` in package/font/info.json, add the codepoint to BOTH size
// commands above, regenerate, and add a #define here.

#define ICON_TREND_UP   "\xEE\x86\x91"   // lucide trending-up (U+E191)
#define ICON_TREND_DOWN "\xEE\x86\x90"   // lucide trending-down (U+E190)
#define ICON_FLAT       "\xEE\x84\x9C"   // lucide minus (U+E11C)
#define ICON_WIFI       "\xEE\x86\xAE"   // lucide wifi (U+E1AE)
#define ICON_WIFI_OFF   "\xEE\x86\xAF"   // lucide wifi-off (U+E1AF)
#define ICON_BT         "\xEE\x81\x9C"   // lucide bluetooth (U+E05C)
#define ICON_BT_OFF     "\xEE\x86\xB9"   // lucide bluetooth-off (U+E1B9)
#define ICON_CLOCK      "\xEE\x82\x87"   // lucide clock (U+E087)
#define ICON_ALERT      "\xEE\x81\xB7"   // lucide circle-alert (U+E077)
#define ICON_BOT        "\xEE\x86\xBB"   // lucide bot (U+E1BB)
#define ICON_TERMINAL   "\xEE\x86\x81"   // lucide terminal (U+E181)
#define ICON_ZAP        "\xEE\x86\xB4"   // lucide zap (U+E1B4)
