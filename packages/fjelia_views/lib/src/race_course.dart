import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fjelia_core/services/activity_kind.dart';
import 'package:fjelia_core/services/course/course.dart';
import 'package:fjelia_core/services/course/course_prediction.dart';
import 'package:fjelia_core/services/course/course_profile.dart';
import 'package:fjelia_core/models/workout_nutrition.dart';
import 'package:fjelia_core/services/course/grade_pace.dart';
import 'package:fjelia_core/services/course/race_plan.dart';
import 'package:fjelia_data/database.dart';

import 'fuel.dart' show loadNutritionPreferences;

/// Runs this far back make the athlete's own grade table.
const gradeTableDays = 180;

/// How the course of a race goal came to be.
enum CourseSource { library, upload }

/// A race goal with its course, the course analysed, and the finish and
/// checkpoint times predicted from the athlete's own running on hills.
class RaceCourseView {
  const RaceCourseView({
    required this.goal,
    required this.course,
    required this.source,
    this.startAt,
    this.profile,
    this.table,
    this.prediction,
    this.plan,
    this.fuel,
  });
  final RaceGoal goal;
  final Course course;
  final CourseSource source;
  final DateTime? startAt;

  /// Null when the file has no heights.
  final CourseProfile? profile;

  /// The athlete's pace per grade; null with too little hilly running.
  final GradePaceTable? table;

  /// Null without a profile or a table.
  final CoursePrediction? prediction;

  /// The prediction with race-day conditions (night, heat, stops) from the
  /// course's settings; null without a prediction.
  final RacePlan? plan;

  /// Carbohydrate, fluid and sodium per hour from the Fuel planning, for the
  /// race's length and expected heat; null without a plan.
  final NutritionStrategy? fuel;

  /// The margin to the cut-off at the end of [leg], when there is one and
  /// the start time is known: positive when ahead of it.
  Duration? marginAt(PlannedLeg leg) {
    final cutoff = leg.leg.cutoff(course);
    final start = startAt;
    if (cutoff == null || start == null) return null;
    return cutoff.difference(start.add(Duration(seconds: leg.arrival.round())));
  }

  /// What to take on [leg]: grams of carbohydrate, millilitres to drink,
  /// milligrams of sodium, at the Fuel planning's hourly rates.
  ({double carbs, double fluid, double sodium})? fuelFor(PlannedLeg leg) {
    final f = fuel;
    if (f == null) return null;
    final hours = leg.seconds / 3600;
    return (
      carbs: f.carbs * hours,
      fluid: f.fluid * hours,
      sodium: f.sodium * hours,
    );
  }
}

/// The athlete's pace per grade from the runs of the last
/// [gradeTableDays] that recorded altitude.
Future<GradePaceTable?> loadGradePaceTable(
  AppDatabase db, {
  DateTime? now,
}) async {
  final since = (now ?? DateTime.now()).subtract(
    const Duration(days: gradeTableDays),
  );
  final rows =
      await (db.select(db.activityRecords)..where(
            (a) =>
                a.startDate.isBiggerOrEqualValue(since) &
                a.metricsJson.isNotNull(),
          ))
          .get();
  final runs = <List<Map<String, num>>>[];
  for (final r in rows) {
    if (activityKind(r.type) != ActivityKind.running) continue;
    final json = r.metricsJson!;
    if (!json.contains('"ele"')) continue;
    try {
      runs.add([
        for (final s in jsonDecode(json) as List)
          (s as Map).cast<String, num>(),
      ]);
    } on Object {
      continue;
    }
  }
  return buildGradePaceTable(runs);
}

/// The course of [goalId] with its analysis and prediction, or null when it
/// has none. With [texts] (the app's wording for the Fuel planning) it also
/// plans the fuel per leg.
Future<RaceCourseView?> loadRaceCourse(
  AppDatabase db,
  String goalId, {
  DateTime? now,
  NutritionTexts? texts,
}) async {
  final row = await (db.select(
    db.raceCourses,
  )..where((c) => c.goalId.equals(goalId))).getSingleOrNull();
  final goal = await (db.select(
    db.raceGoals,
  )..where((g) => g.id.equals(goalId))).getSingleOrNull();
  if (row == null || goal == null) return null;
  final course = Course.fromJson(row.courseJson);
  if (course == null) return null;
  final profile = analyseCourse(course);
  final table = await loadGradePaceTable(db, now: now);
  final prediction = profile == null || table == null
      ? null
      : predictCourse(course, profile, table: table);
  final plan = prediction == null
      ? null
      : planRace(
          course,
          prediction,
          start: row.startAt,
          settings: course.settings,
        );
  return RaceCourseView(
    goal: goal,
    course: course,
    source: CourseSource.values.asNameMap()[row.source] ?? CourseSource.upload,
    startAt: row.startAt,
    profile: profile,
    table: table,
    prediction: prediction,
    plan: plan,
    fuel: plan == null || texts == null
        ? null
        : planNutritionWith(
            texts,
            NutritionWorkout(
              key: 'race:$goalId',
              title: goal.name,
              sport: goal.primarySport,
              date: goal.raceDate,
              minutes: plan.seconds / 60,
              zone: 2,
            ),
            await loadNutritionPreferences(db),
            NutritionConditions(
              temperature: course.settings.highTempC,
              ascent: profile?.gain,
            ),
            now: now,
          ),
  );
}

/// Why a course was not saved.
enum CourseRefusal { unreadable, noElevation }

class CourseRefused implements Exception {
  const CourseRefused(this.reason);
  final CourseRefusal reason;
}

/// Changes to the course of a race goal; they sync like the goal.
class RaceCourseEdits {
  RaceCourseEdits(this.db);
  final AppDatabase db;

  /// Saves the course in [gpx] for [goalId], replacing any. Waypoints near
  /// the track become checkpoints; [checkpoints], when given, replace them.
  /// Throws [CourseRefused] for a file without a track or heights.
  Future<Course> setFromGpx(
    String goalId,
    String gpx, {
    CourseSource source = CourseSource.upload,
    String? libraryRaceId,
    List<CourseCheckpoint>? checkpoints,
    DateTime? startAt,
  }) async {
    final parsed = parseCourseGpx(gpx);
    if (parsed == null) throw const CourseRefused(CourseRefusal.unreadable);
    if (!parsed.hasElevation) {
      throw const CourseRefused(CourseRefusal.noElevation);
    }
    final course = checkpoints == null
        ? parsed
        : parsed.withCheckpoints(checkpoints);
    await db
        .into(db.raceCourses)
        .insertOnConflictUpdate(
          RaceCourseRow(
            goalId: goalId,
            courseJson: course.toJson(),
            source: source.name,
            libraryRaceId: libraryRaceId,
            startAt: startAt,
            updatedAt: DateTime.now(),
          ),
        );
    return course;
  }

  Future<void> setCheckpoints(
    String goalId,
    List<CourseCheckpoint> checkpoints,
  ) => _change(goalId, (c) => c.withCheckpoints(checkpoints));

  /// Race-day expectations: heat, night, stops.
  Future<void> setSettings(String goalId, RacePlanSettings settings) =>
      _change(goalId, (c) => c.withSettings(settings));

  Future<void> setStart(String goalId, DateTime? startAt) =>
      (db.update(db.raceCourses)..where((c) => c.goalId.equals(goalId))).write(
        RaceCoursesCompanion(
          startAt: Value(startAt),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> remove(String goalId) =>
      (db.delete(db.raceCourses)..where((c) => c.goalId.equals(goalId))).go();

  Future<void> _change(String goalId, Course Function(Course) f) async {
    final row = await (db.select(
      db.raceCourses,
    )..where((c) => c.goalId.equals(goalId))).getSingleOrNull();
    final course = Course.fromJson(row?.courseJson);
    if (row == null || course == null) return;
    await (db.update(
      db.raceCourses,
    )..where((c) => c.goalId.equals(goalId))).write(
      RaceCoursesCompanion(
        courseJson: Value(f(course).toJson()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}

/// Checkpoints from the race library's aid stations (`name`, `km`,
/// `cutoff` as an ISO time); entries without a name or distance are left
/// out.
List<CourseCheckpoint> checkpointsFromLibrary(List<Object?> aidStations) => [
  for (final a in aidStations)
    if (a is Map && a['name'] is String && a['km'] is num)
      CourseCheckpoint(
        name: a['name'] as String,
        km: (a['km'] as num).toDouble(),
        cutoff: DateTime.tryParse('${a['cutoff']}'),
      ),
];

/// A race goal and whether it has a course yet.
class RaceGoalItem {
  const RaceGoalItem(this.goal, {required this.hasCourse});
  final RaceGoal goal;
  final bool hasCourse;

  bool upcoming(DateTime now) =>
      !goal.raceDate.isBefore(DateTime(now.year, now.month, now.day));
}

/// The athlete's race goals, coming ones first (soonest first), then past
/// ones (latest first). Cancelled goals are left out.
Future<List<RaceGoalItem>> loadRaceGoals(
  AppDatabase db, {
  DateTime? now,
}) async {
  final today = now ?? DateTime.now();
  final goals = await (db.select(
    db.raceGoals,
  )..where((g) => g.participation.isNotValue('cancelled'))).get();
  final withCourse = {
    for (final c in await db.select(db.raceCourses).get()) c.goalId,
  };
  final items = [
    for (final g in goals)
      RaceGoalItem(g, hasCourse: withCourse.contains(g.id)),
  ];
  final coming = [
    for (final i in items)
      if (i.upcoming(today)) i,
  ]..sort((a, b) => a.goal.raceDate.compareTo(b.goal.raceDate));
  final past = [
    for (final i in items)
      if (!i.upcoming(today)) i,
  ]..sort((a, b) => b.goal.raceDate.compareTo(a.goal.raceDate));
  return [...coming, ...past];
}
