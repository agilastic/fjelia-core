import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fjelia_core/models/workout_nutrition.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

class _Texts implements NutritionTexts {
  @override
  dynamic noSuchMethod(Invocation i) => i.memberName.toString();
}

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 25, 9);
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> session(String id, DateTime day, int minutes, String sport) => db
      .into(db.trainingSessions)
      .insert(
        TrainingSessionsCompanion.insert(
          id: id,
          planId: 'p',
          athleteId: 'self',
          sessionDate: day,
          sessionNumber: 1,
          weekNumber: 1,
          sport: sport,
          sessionType: 'long',
          phase: 'base',
          primaryZone: 2,
          title: 'Session $id',
          plannedDurationMin: minutes,
          plannedTrimp: minutes,
          sessionLevel: 2,
        ),
      );

  test(
    'suggested fuelling, and the phone’s saved plan where there is one',
    () async {
      await session('long', DateTime(2026, 11, 29), 150, 'running');
      await session('gym', DateTime(2026, 11, 27), 45, 'strength');
      await session('ride', DateTime(2026, 11, 28), 180, 'cycling');
      final view = await loadFuel(db, _Texts(), now: now);
      expect(view.plans.map((p) => p.strategy.workout.title), [
        'Session ride',
        'Session long',
      ]);
      final ride = view.plans.first;
      expect(ride.saved, isFalse);
      expect(ride.strategy.carbs, greaterThan(0));

      // The athlete set the run's fuelling on the phone.
      final mine = planNutritionWith(
        _Texts(),
        view.plans.last.strategy.workout,
        view.preferences,
        const NutritionConditions(),
        carbs: 42,
      );
      await db
          .into(db.nutritionRecords)
          .insert(
            NutritionRecordsCompanion.insert(
              recordKey: fuelKey('long'),
              kind: 'plan',
              dataJson: jsonEncode(mine.toJson()),
              updatedAt: now,
            ),
          );
      final again = await loadFuel(db, _Texts(), now: now);
      expect(again.plans.last.saved, isTrue);
      expect(again.plans.last.strategy.carbs, 42);
    },
  );
}
