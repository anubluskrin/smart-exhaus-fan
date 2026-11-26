#pragma once

#include <string.h>
#include "demo_scenario.h"
#include "smoke_alarm.h"

inline bool validDemoId(const char* id) {
  if (!id || strlen(id) != 36 || id[14] != '4' || !strchr("89ab", id[19])) return false;
  for (unsigned i = 0; i < 36; i++) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (id[i] != '-') return false;
    } else if (!strchr("0123456789abcdef", id[i])) return false;
  }
  return true;
}

inline bool validDemoDeadline(uint32_t now, uint32_t expiry) {
  return now != 0 && expiry >= now && expiry - now <= 10;
}

struct DemoSession {
  DemoPreset preset;
  char id[37] = {};
  uint32_t generation = 0;
  uint32_t started = 0;
  bool active = false;
  const char* reason = nullptr;

  uint32_t elapsed(uint32_t now) const { return now - started; }
  bool expired(uint32_t now) const { return active && elapsed(now) >= 1800000u; }

  bool start(const DemoPreset& value, const char* runId, uint32_t expected,
             uint32_t next, uint32_t now, bool ready) {
    if (!ready || active || generation != expected || !validDemoId(runId) ||
        strcmp(id, runId) == 0 || !validDemoPreset(value)) return false;
    strcpy(id, runId);
    preset = value;
    generation = next;
    started = now;
    reason = nullptr;
    active = true;
    return true;
  }

  void finish(const char* why, uint32_t next) {
    active = false;
    reason = why;
    generation = next;
  }

  bool stop(const char* runId, uint32_t expected, uint32_t next) {
    if (!active || generation != expected || !validDemoId(runId) ||
        strcmp(id, runId) != 0) return false;
    finish("stopped", next);
    return true;
  }
};
