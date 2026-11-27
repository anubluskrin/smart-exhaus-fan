#pragma once

#include <stdint.h>

struct SmokeAlarm {
  bool active = false;
  bool clearing = false;
  uint32_t clearSince = 0;

  // Returns true only when a previously active alarm clears.
  bool update(float delta, bool ready, float on, float off, uint32_t now) {
    if (!ready) {
      active = clearing = false;
    } else if (!active) {
      active = delta > on;
    } else if (delta >= off) {
      clearing = false;
    } else if (!clearing) {
      clearSince = now;
      clearing = true;
    } else if (now - clearSince >= 60000u) {
      active = clearing = false;
      return true;
    }
    return false;
  }
};
