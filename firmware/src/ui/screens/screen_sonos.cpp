#include "ui/screens/screen_sonos.h"
#include "ui/screens/screen_module.h"

// Sonos now-playing (hub-plane, phase 1 text only -- design doc §3). Room selection is a per-page hub
// option (opts["room"], hub UI scope); the device just renders whatever room/track/artist/album/playing
// the hub pushes in the "sonos" frame.
SCREEN_MODULE_SIMPLE(sonos, "SONOS", sonos_module);
