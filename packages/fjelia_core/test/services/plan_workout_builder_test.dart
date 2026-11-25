import 'package:fjelia_core/services/plan_rules.dart';
import 'package:fjelia_core/services/plan_workout_builder.dart';
import 'package:test/test.dart';

Map<String, dynamic> hrStep(String type, int zone) => {
  'type': 'ExecutableStepDTO',
  'stepType': {'stepTypeKey': type},
  'endCondition': {'conditionTypeKey': 'time'},
  'endConditionValue': 1800,
  'zoneNumber': zone,
  'targetType': {'workoutTargetTypeKey': 'heart.rate.zone'},
};

PlanAthleteFitnessSnapshot runner(List<int> floors) =>
    PlanAthleteFitnessSnapshot(
      ctl: 0,
      tsb: 0,
      tier: 'intermediate',
      hrFloors: floors,
      maxHr: 183,
      easyRunZ2: true,
    );

void main() {
  final build = PlanWorkoutBuilder();

  test('a step resolved again takes the heart rates of the new zones', () {
    final planned = build.resolveStep(
      hrStep('interval', 3),
      null,
      runner(const [92, 110, 128, 146, 165]),
      power: false,
    );
    expect([planned['targetValueOne'], planned['targetValueTwo']], [128, 145]);
    final again = build.resolveStep(
      planned,
      null,
      runner(const [100, 120, 135, 150, 168]),
      power: false,
    );
    expect([again['targetValueOne'], again['targetValueTwo']], [135, 149]);
  });

  test('an easy run stays in the lower half of zone 2 when resolved again', () {
    final planned = build.resolveStep(
      hrStep('interval', 1),
      null,
      runner(const [92, 110, 128, 146, 165]),
      power: false,
    );
    expect(planned['zoneNumber'], 2);
    expect([planned['targetValueOne'], planned['targetValueTwo']], [110, 119]);
    // New zones: zone 2 is 120 to 134, its lower half 120 to 127.
    final again = build.resolveStep(
      planned,
      null,
      runner(const [100, 120, 135, 150, 168]),
      power: false,
    );
    expect(again['zoneNumber'], 2);
    expect([again['targetValueOne'], again['targetValueTwo']], [120, 127]);
  });

  test('a warm-up in zone 1 is no easy run', () {
    final warm = build.resolveStep(
      hrStep('warmup', 1),
      null,
      runner(const [92, 110, 128, 146, 165]),
      power: false,
    );
    expect(warm['zoneNumber'], 1);
    expect(warm.containsKey('easyRun'), isFalse);
  });
}
