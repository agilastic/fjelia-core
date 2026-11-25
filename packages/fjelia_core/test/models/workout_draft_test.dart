import 'package:fjelia_core/models/workout_draft.dart';
import 'package:fjelia_core/models/workout_profile.dart';
import 'package:fjelia_core/services/plan_workout_builder.dart';
import 'package:test/test.dart';

void main() {
  test('a built workout round-trips and counts like the plan', () {
    const draft = WorkoutDraft([
      DraftStep(kind: DraftStepKind.warmup, zone: 1, seconds: 600),
      DraftRepeat(
        times: 5,
        steps: [
          DraftStep(kind: DraftStepKind.interval, zone: 4, seconds: 240),
          DraftStep(kind: DraftStepKind.recovery, zone: 1, seconds: 120),
        ],
      ),
      DraftStep(kind: DraftStepKind.cooldown, zone: 1, meters: 1000),
    ]);
    final json = draft.toStepsJson();
    final back = WorkoutDraft.fromStepsJson(json)!;
    expect(back.items, hasLength(3));
    final repeat = back.items[1] as DraftRepeat;
    expect(repeat.times, 5);
    expect(repeat.steps.first.zone, 4);
    expect((back.items.last as DraftStep).meters, 1000);
    final semantics = draft.semantics(sport: 'running');
    // 10 + 5 × 6 min + about 6 min for the kilometre.
    expect(semantics.totalMinutes, closeTo(46, 1));
    expect(semantics.zoneSeconds[4], 1200);
    // The phone's profile reads it as the same blocks.
    expect(
      workoutProfile(json, primaryZone: 2, sport: 'running'),
      hasLength(12),
    );
  });

  test('a plan-made workout reads as a draft', () {
    final steps = PlanWorkoutBuilder.steadySteps(60, 2);
    final draft = WorkoutDraft.fromStepsJson(steps)!;
    expect(draft.items, hasLength(3));
    expect((draft.items[1] as DraftStep).zone, 2);
    expect(WorkoutDraft.fromStepsJson('nope'), isNull);
    expect(WorkoutDraft.fromStepsJson(null), isNull);
  });
}
