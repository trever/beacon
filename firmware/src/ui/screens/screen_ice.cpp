#include "ui/screens/screen_ice.h"
#include "ui/screens/screen_module.h"

// ICE D4 RIN futures (device-plane). "RIN" reads better than "ICE" on the eyebrow -- the exchange is
// the source, the contract is the subject.
SCREEN_MODULE_SIMPLE(ice, "D4 RIN", ice_module);
