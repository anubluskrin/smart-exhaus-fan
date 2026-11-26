#include <cassert>
#include "../bathfan/demo_session.h"

int main() {
  DemoSession run;
  DemoPreset preset;
  constexpr char a[] = "00000000-0000-4000-8000-000000000001";
  constexpr char b[] = "00000000-0000-4000-8000-000000000002";
  run.generation = 7;
  assert(!run.start(preset, a, 7, 8, 100, false));
  assert(!run.start(preset, a, 6, 8, 100, true));
  assert(run.start(preset, a, 7, 8, 100, true));
  assert(!run.start(preset, b, 7, 9, 200, true));
  assert(!run.start(preset, a, 8, 9, 200, true));
  assert(run.elapsed(200) == 100);
  assert(run.stop(a, 8, 9));
  assert(!run.start(preset, a, 9, 10, 300, true));
  assert(run.start(preset, b, 9, 10, 300, true));
  assert(!run.stop(a, 10, 11));
  assert(!run.stop(b, 9, 11));
  assert(!run.expired(1800299));
  assert(run.expired(1800300));
  assert(!validDemoDeadline(100, 99));
  assert(!validDemoDeadline(100, 111));
  assert(validDemoDeadline(100, 110));
  assert(!validDemoDeadline(0, 10));
  SmokeAlarm alarm;
  alarm.update(250, true, 250, 100, 0);
  assert(!alarm.active);
  alarm.update(251, true, 250, 100, 1);
  assert(alarm.active);
  alarm.update(99, true, 250, 100, 2);
  alarm.update(99, true, 250, 100, 59002);
  assert(alarm.active);
  alarm.update(100, true, 250, 100, 59003);
  alarm.update(99, true, 250, 100, 59004);
  assert(!alarm.update(99, true, 250, 100, 119003));
  assert(alarm.update(99, true, 250, 100, 119004));
  assert(!alarm.active);
}
