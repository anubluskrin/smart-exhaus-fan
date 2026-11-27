#include <cassert>
#include <initializer_list>
#include "../bathfan/demo_scenario.h"

int main() {
  for (int minutes : {5, 10, 20}) {
    for (int speed : {1, 10}) {
      DemoPreset preset;
      preset.minutes = minutes;
      preset.speed = speed;
      const uint32_t end = minutes * 60000u / speed;
      assert(sampleScenario(preset, 0).humidity == 55);
      assert(sampleScenario(preset, end / 4).humidity == 85);
      assert(sampleScenario(preset, end / 4).temperature == 30);
      assert(sampleScenario(preset, end).phase == DemoPhase::Recovery);
      assert(sampleScenario(preset, end + 120000 / speed).humidity == 55);
      assert(sampleScenario(preset, end + 120000 / speed).temperature == 26);
    }
  }
  DemoPreset smoke;
  smoke.kind = DemoKind::Smoke;
  smoke.intensity = DemoIntensity::Thin;
  assert(sampleScenario(smoke, 30000).smokeDelta == 160);
  smoke.people = 3;
  smoke.intensity = DemoIntensity::Thick;
  assert(sampleScenario(smoke, 30000).smokeDelta == 1440);
  smoke.people = 2;
  smoke.intensity = DemoIntensity::Medium;
  smoke.pattern = DemoPattern::Staggered;
  assert(sampleScenario(smoke, 30000).smokeDelta == 320);
  assert(sampleScenario(smoke, 60000).smokeDelta == 640);
  assert(sampleScenario(smoke, 150000).phase == DemoPhase::Settling);
}
