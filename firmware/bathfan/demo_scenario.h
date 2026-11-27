#pragma once

#include <stdint.h>

enum class DemoKind { Shower, Smoke };
enum class DemoIntensity { Thin, Medium, Thick };
enum class DemoPattern { Together, Staggered };
enum class DemoPhase { Idle, Shower, Recovery, Smoking, Settling };

struct DemoPreset {
  DemoKind kind = DemoKind::Shower;
  uint8_t minutes = 10;
  uint8_t speed = 1;
  uint8_t people = 1;
  DemoIntensity intensity = DemoIntensity::Medium;
  DemoPattern pattern = DemoPattern::Together;
};

struct DemoSample {
  float humidity, temperature, smokeDelta;
  DemoPhase phase;
};

inline bool validDemoPreset(const DemoPreset& p) {
  if (p.speed != 1 && p.speed != 10) return false;
  if (p.kind == DemoKind::Shower) return p.minutes == 5 || p.minutes == 10 || p.minutes == 20;
  return p.kind == DemoKind::Smoke && p.people >= 1 && p.people <= 3 &&
         p.intensity >= DemoIntensity::Thin && p.intensity <= DemoIntensity::Thick &&
         p.pattern >= DemoPattern::Together && p.pattern <= DemoPattern::Staggered;
}

inline DemoSample sampleScenario(const DemoPreset& p, uint32_t elapsedRealMs) {
  DemoSample result{55, 26, 0, DemoPhase::Settling};
  if (!validDemoPreset(p) || elapsedRealMs >= 1800000u) return result;
  const float t = elapsedRealMs * p.speed / 1000.0f;
  if (p.kind == DemoKind::Shower) {
    const float end = p.minutes * 60.0f;
    const float ramp = end / 4;
    if (t < end + 120) {
      const float fraction = t < ramp ? t / ramp : t < end ? 1 : 1 - (t - end) / 120;
      return {55 + 30 * fraction, 26 + 4 * fraction, 0,
              t < end ? DemoPhase::Shower : DemoPhase::Recovery};
    }
    return result;
  }
  const int offset = p.pattern == DemoPattern::Staggered ? 30 : 0;
  if (t >= 120 + offset * (p.people - 1)) return result;
  result.phase = DemoPhase::Smoking;
  const int peak = 160 * (1 + static_cast<int>(p.intensity));
  for (int i = 0; i < p.people; ++i) {
    const float age = t - i * offset;
    if (age < 0 || age >= 120) continue;
    result.smokeDelta += peak * (age < 30 ? age / 30 : age < 60 ? 1 : (120 - age) / 60);
  }
  return result;
}
