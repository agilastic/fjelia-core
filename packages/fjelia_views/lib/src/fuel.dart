import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fjelia_core/models/workout_nutrition.dart';
import 'package:fjelia_data/database.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// The fuelling of one planned workout.
class FuelPlan {
  const FuelPlan(this.strategy, {required this.saved});
  final NutritionStrategy strategy;

  /// The athlete set it on the phone; otherwise Fjelia's suggestion.
  final bool saved;
}

/// What the Fuel screen shows: the athlete's tolerances and the fuelling of
/// the workouts ahead.
class FuelView {
  const FuelView({required this.preferences, required this.plans});
  final NutritionPreferences preferences;

  /// The coming days' workouts, in order.
  final List<FuelPlan> plans;
}

/// The key the phone stores a session's fuelling under.
String fuelKey(String sessionId) => 'plan:$sessionId';

/// Fuelling for the planned workouts of the next [days] days: the plan
/// saved on the phone, else the suggestion of fjelia_core's
/// planNutritionWith, worded by [texts].
Future<FuelView> loadFuel(
  AppDatabase db,
  NutritionTexts texts, {
  int days = 7,
  DateTime? now,
}) async {
  final today = _day(now ?? DateTime.now());
  final records = {
    for (final r in await db.select(db.nutritionRecords).get()) r.recordKey: r,
  };
  Map<String, dynamic>? json(String key) {
    final r = records[key];
    if (r == null) return null;
    try {
      return (jsonDecode(r.dataJson) as Map).cast<String, dynamic>();
    } on Object {
      return null;
    }
  }

  final preferences = await loadNutritionPreferences(db);
  final sessions =
      await (db.select(db.trainingSessions)
            ..where(
              (t) =>
                  t.athleteId.equals('self') &
                  t.sessionDate.isBiggerOrEqualValue(today) &
                  t.sessionDate.isSmallerThanValue(
                    DateTime(today.year, today.month, today.day + days),
                  ) &
                  t.status.isIn(const ['planned', 'adapted']) &
                  t.sport.isNotValue('strength') &
                  t.sport.isNotValue('yoga'),
            )
            ..orderBy([(t) => OrderingTerm(expression: t.sessionDate)]))
          .get();
  return FuelView(
    preferences: preferences,
    plans: [
      for (final s in sessions)
        if (json(fuelKey(s.id)) case final saved?)
          FuelPlan(NutritionStrategy.fromJson(saved), saved: true)
        else
          FuelPlan(
            planNutritionWith(
              texts,
              NutritionWorkout(
                key: fuelKey(s.id),
                title: s.title,
                sport: s.sport,
                date: s.sessionDate,
                minutes: s.plannedDurationMin.toDouble(),
                zone: s.primaryZone,
                indoor: s.indoor,
              ),
              preferences,
              const NutritionConditions(),
              now: now,
            ),
            saved: false,
          ),
    ],
  );
}

/// The athlete's fuel preferences (the Fuel planning's settings).
Future<NutritionPreferences> loadNutritionPreferences(AppDatabase db) async {
  final r =
      await (db.select(db.nutritionRecords)
            ..where((n) => n.recordKey.equals('nutrition:preferences')))
          .getSingleOrNull();
  if (r == null) return const NutritionPreferences();
  try {
    return NutritionPreferences.fromJson(
      (jsonDecode(r.dataJson) as Map).cast<String, dynamic>(),
    );
  } on Object {
    return const NutritionPreferences();
  }
}
