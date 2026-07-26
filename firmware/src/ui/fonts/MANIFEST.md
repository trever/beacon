# Font asset manifest (P0-B)

Glyph-subset LVGL fonts for the 7-theme engine. Generated C arrays (`font_*.c`) are committed and
link into the **app slot (~3 MB `ota_0`)**, not the data partition. Total generated C: ~980 KB
(GC-dropped until referenced; real linked cost is measured by the Task 9 demo build).

## Sources (google/fonts, OFL) + weights

Variable fonts instanced to static weights via `fonttools varLib.instancer`.

| Family | google/fonts path | Instanced weight |
|---|---|---|
| Space Grotesk | `ofl/spacegrotesk/SpaceGrotesk[wght].ttf` | wght=500 |
| Rajdhani | `ofl/rajdhani/Rajdhani-Medium.ttf` | static Medium |
| Doto | `ofl/doto/Doto[ROND,wght].ttf` | wght=500, ROND=0 |
| Chakra Petch | `ofl/chakrapetch/ChakraPetch-Medium.ttf` | static Medium |
| Pixelify Sans | `ofl/pixelifysans/PixelifySans[wght].ttf` | wght=400 |
| JetBrains Mono | `ofl/jetbrainsmono/JetBrainsMono[wght].ttf` | wght=500 |
| Inter | `ofl/inter/Inter[opsz,wght].ttf` | wght=400, opsz=14 |

## Roles, sizes, glyph subsets (lv_font_conv@1.5.3, --bpp 4)

| Role | Size px | Glyphs | Files |
|---|---|---|---|
| hero | 84 | `0-9 : % . , + - / ° space` | one per display family (7) |
| display | 30 | printable ASCII `0x20-0x7E` + `0xB0` | one per display family (7) |
| body | 18 | printable ASCII + `0xB0` | sg, raj, cp, inter, jbm (5) |
| mono | 15 | printable ASCII + `0xB0` | jbm (1, shared by all themes) |
| **icon** | 14, 22 | 12 lucide PUA glyphs (see `icons.h`) | `font_lucide_14/22` (2) |

## Icons (lucide)

From the official lucide webfont, `npm lucide-static` (`font/lucide.ttf` + `font/info.json` for the
codepoint map). **Lucide is ISC-licensed** (Copyright (c) Lucide Icons and Contributors); the notice is
retained in the generated `font_lucide_*.c` headers, as ISC requires in all copies. Two sizes because LVGL cannot scale a bitmap font: **14** pairs with mono/body text,
**22** with the display face. ~23 KB of generated C for both.

These are Private Use Area codepoints, so an `ICON_*` string renders as a missing glyph in any text
font -- icons always need their own label styled with `t->f_icon` / `t->f_icon_lg`. That constraint is
why `fmt_change_num` exists alongside `fmt_change`: the number and its trend glyph cannot share a
label. Regeneration commands + the glyph list live in `icons.h`.

## Per-theme mapping (theme.cpp `THEME_FONTS[]`)

Single-theme catalog since 2026-07-26; the other six families were deleted with their themes.

| Theme | hero / display | body | mono | icon |
|---|---|---|---|---|
| editorial | Space Grotesk | Space Grotesk | JetBrains Mono | lucide |

## Regenerate

```bash
# 1. download + instance to /tmp/beaconfonts/ttf/<Family>.ttf (see Sources table; fonttools instancer)
# 2. per family: lv_font_conv hero(84,symbols) + display(30,ascii); bodies(18,ascii); jbm mono(15,ascii)
npx -y lv_font_conv@1.5.3 --font <ttf> --size <px> --bpp 4 --format lvgl \
    [-r 0x20-0x7E -r 0xB0 | --symbols "0123456789:%.,+-/° "] -o font_<key>_<role>.c
```

Requires `-DLV_LVGL_H_INCLUDE_SIMPLE` in the build (generated files then `#include "lvgl.h"`).
Weights/hues are tunable on hardware (Task 9 demo); the frozen part is the theme ids + gauge mapping + `beacon_theme_t`.
