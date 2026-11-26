import 'package:drift/native.dart';
import 'package:fjelia_core/models/strength_workout.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  StrengthExerciseVariant exercise(String id) =>
      builtInStrengthVariants.firstWhere((v) => v.id == id);

  test('a superset with RIR is saved, read back and versioned', () async {
    final plans = StrengthPlans(db);
    final squat = builtInStrengthVariants.first;
    final second = builtInStrengthVariants[1];
    var plan = const StrengthWorkoutPlan(blocks: [])
        .addExercise(squat)
        .addExercise(second);
    final first = plan.blocks.first.exercises.single;
    plan = plan
        .groupWithNext(first.id, StrengthBlockKind.superset)
        .updateExercise(
          first.id,
          (e) => e.copyWith(
            sets: [
              for (final s in e.sets)
                s.copyWith(
                  effort: () =>
                      const StrengthEffort(StrengthEffortScale.rir, 2),
                ),
            ],
          ),
        );
    expect(plan.blocks.single.kind, StrengthBlockKind.superset);

    final owner = StrengthPlanOwner.session('s1');
    final saved = await plans.save(owner, plan, expectedRevision: 0);
    expect(saved.revision, 1);
    final back = (await plans.load(owner))!;
    expect(back.plan.blocks.single.exercises, hasLength(2));
    expect(back.plan.blocks.single.exercises.first.sets.first.effort?.value, 2);

    // Saved meanwhile on the other device: this draft is refused.
    expect(
      () => plans.save(owner, plan, expectedRevision: 0),
      throwsA(isA<StrengthPlanConflict>()),
    );
    expect(
      () => plans.save(
        owner,
        const StrengthWorkoutPlan(blocks: []),
        expectedRevision: 1,
      ),
      throwsA(isA<StrengthPlanInvalid>()),
    );
  });

  test('custom exercises join the built-in ones', () async {
    final plans = StrengthPlans(db);
    await plans.addCustomExercise(name: 'Copenhagen plank', equipment: '');
    final all = await plans.exercises();
    expect(all.length, builtInStrengthVariants.length + 1);
    expect(all.last.name, 'Copenhagen plank');
    expect(exercise(builtInStrengthVariants.first.id).id, isNotEmpty);
  });
}
