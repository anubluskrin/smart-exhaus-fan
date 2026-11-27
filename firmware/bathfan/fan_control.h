#pragma once

#include <stdint.h>

enum State { IDLE, RUNNING, POSTRUN };

struct FanMemory {
  State state = IDLE;
  uint32_t postrunStart = 0;
};

struct FanPolicy {
  float humOn, humOff;
  int maxSpeed, minSpeed;
  uint32_t postrunMs;
};

inline int fanControlStep(FanMemory& memory, const FanPolicy& p, float humidity,
                          uint32_t now, bool power, bool alarm, bool standby,
                          bool manual, int manualSpeed, bool immediateRising = false) {
  const auto humiditySpeed = [&] {
    const long floor = static_cast<long>(p.humOff);
    const long speed = (static_cast<long>(humidity) - floor) * (100 - p.minSpeed) /
                       (90 - floor) + p.minSpeed;
    return speed < p.minSpeed ? p.minSpeed : speed > p.maxSpeed ? p.maxSpeed : static_cast<int>(speed);
  };
  if (!power) return 0;
  if (alarm) {
    memory.state = RUNNING;
    return p.maxSpeed;
  }
  if (standby) {
    memory.state = IDLE;
    return humidity >= 90 ? humiditySpeed() : 0;
  }
  if (manual) return manualSpeed < p.maxSpeed ? manualSpeed : p.maxSpeed;
  switch (memory.state) {
    case IDLE:
      if (!(humidity > p.humOn)) return 0;
      memory.state = RUNNING;
      return immediateRising ? humiditySpeed() : 0;
    case RUNNING:
      if (humidity < p.humOff) {
        memory.state = POSTRUN;
        memory.postrunStart = now;
      }
      return humiditySpeed();
    case POSTRUN:
      if (humidity > p.humOn) memory.state = RUNNING;
      else if (now - memory.postrunStart >= p.postrunMs) {
        memory.state = IDLE;
        return 0;
      }
      return p.minSpeed;
  }
  return 0;
}
