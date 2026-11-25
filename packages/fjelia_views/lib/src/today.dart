import 'package:drift/drift.dart';
import 'package:fjelia_core/services/readiness.dart';
import 'package:fjelia_core/utils/week.dart';
import 'package:fjelia_data/database.dart';

import 'activities.dart';
import 'training_load.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Calendar days from [from] to [to]; local days are 23 or 25 hours long
/// when the clocks change.
int _calendarDays(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// Session states that count as planned for a day; skipped and superseded
/// sessions do not.
const plannedSessionStates = ['planned', 'adapted', 'completed'];

/// The morning check as the phone worked it out.
class ReadinessView {
  const ReadinessView({
    required this.level,
    required this.computedAt,
    required this.flags,
    this.hrvToday,
    this.hrvDropPct,
    this.restingHrToday,
    this.restingHrElevation,
    this.sleepScore,
  });

  final ReadinessLevel level;
  final DateTime computedAt;

  /// What pulled readiness down.
  final Set<ReadinessFlag> flags;
  final double? hrvToday;

  /// Below the 7-day baseline, in percent; negative when above.
  final double? hrvDropPct;
  final double? restingHrToday;

  /// Above the 7-day baseline, in beats per minute.
  final double? restingHrElevation;
  final int? sleepScore;
}

enum ReadinessFlag { hrv, restingHr, sleep, battery, skinTemperature, fatigue }

/// One planned session.
class PlannedSession {
  const PlannedSession({
    required this.id,
    required this.title,
    required this.sport,
    required this.date,
    required this.durationMin,
    required this.zone,
    required this.load,
    required this.done,
  });

  final String id;
  final String title;
  final String sport;
  final DateTime date;
  final int durationMin;
  final int zone;
  final int load;
  final bool done;
}

/// One day of the current week.
class WeekDay {
  const WeekDay(this.date, this.planned, this.activities);
  final DateTime date;
  final List<PlannedSession> planned;
  final List<ActivityItem> activities;
}

/// The current week: what was done against the plan.
class WeekProgress {
  const WeekProgress(this.days);
  final List<WeekDay> days;

  Duration get done => days
      .expand((d) => d.activities)
      .fold(Duration.zero, (s, a) => s + a.duration);
  Duration get planned => Duration(
    minutes: days.expand((d) => d.planned).fold(0, (s, p) => s + p.durationMin),
  );
  double get doneLoad =>
      days.expand((d) => d.activities).fold(0, (s, a) => s + a.load);
  int get plannedLoad =>
      days.expand((d) => d.planned).fold(0, (s, p) => s + p.load);
}

/// The next race goal.
class GoalView {
  const GoalView({
    required this.name,
    required this.date,
    required this.daysToGo,
    required this.priority,
    required this.sport,
    required this.distanceMeters,
    this.targetSeconds,
  });

  final String name;
  final DateTime date;
  final int daysToGo;

  /// `A`, `B` or `C`.
  final String priority;
  final String sport;
  final double distanceMeters;
  final int? targetSeconds;
}

/// Everything the Today screen shows.
class TodayView {
  const TodayView({
    required this.date,
    required this.load,
    required this.today,
    required this.week,
    required this.recent,
    this.readiness,
    this.nextGoal,
  });

  final DateTime date;

  /// Null until the phone has done today's morning check.
  final ReadinessView? readiness;
  final TrainingLoadSummary load;

  /// Today's planned sessions.
  final List<PlannedSession> today;
  final WeekProgress week;
  final GoalView? nextGoal;

  /// The newest activities.
  final List<ActivityItem> recent;

  /// Nothing synced or recorded yet.
  bool get isEmpty =>
      readiness == null && !load.hasHistory && today.isEmpty && recent.isEmpty;
}

/// [mondayFirst] follows the athlete's calendar week setting.
Future<TodayView> loadToday(
  AppDatabase db, {
  DateTime? now,
  bool mondayFirst = true,
}) async {
  final date = _day(now ?? DateTime.now());
  final start = weekStartOf(date, mondayFirst: mondayFirst);
  final end = DateTime(start.year, start.month, start.day + 7);
  final history = await readTrainingLoadHistory(db, now: date);

  final s = db.trainingSessions;
  final sessions =
      await (db.select(s)
            ..where(
              (t) =>
                  t.athleteId.equals('self') &
                  t.sessionDate.isBiggerOrEqualValue(start) &
                  t.sessionDate.isSmallerThanValue(end) &
                  t.status.isIn(plannedSessionStates),
            )
            ..orderBy([
              (t) => OrderingTerm(expression: t.sessionDate),
              (t) => OrderingTerm(expression: t.sessionNumber),
            ]))
          .get();
  final planned = [
    for (final x in sessions)
      PlannedSession(
        id: x.id,
        title: x.title,
        sport: x.sport,
        date: _day(x.sessionDate.toLocal()),
        durationMin: x.plannedDurationMin,
        zone: x.primaryZone,
        load: x.plannedTrimp,
        done: x.status == 'completed',
      ),
  ];
  final recent = await readActivityItems(db, limit: 5);
  final thisWeek = await readActivityItems(db, since: start);
  final week = WeekProgress([
    for (var i = 0; i < 7; i++)
      () {
        final day = DateTime(start.year, start.month, start.day + i);
        return WeekDay(
          day,
          [
            for (final p in planned)
              if (p.date == day) p,
          ],
          [
            for (final a in thisWeek)
              if (_day(a.start) == day) a,
          ],
        );
      }(),
  ]);

  final goal =
      await (db.select(db.raceGoals)
            ..where(
              (g) =>
                  g.athleteId.equals('self') &
                  g.raceDate.isBiggerOrEqualValue(date),
            )
            ..orderBy([(g) => OrderingTerm(expression: g.raceDate)])
            ..limit(1))
          .getSingleOrNull();

  return TodayView(
    date: date,
    readiness: _readiness(await db.getTodayReadiness()),
    load: TrainingLoadSummary.of(history),
    today: [
      for (final p in planned)
        if (p.date == date) p,
    ],
    week: week,
    nextGoal: goal == null
        ? null
        : GoalView(
            name: goal.name,
            date: _day(goal.raceDate.toLocal()),
            daysToGo: _calendarDays(date, goal.raceDate.toLocal()),
            priority: goal.priority,
            sport: goal.primarySport,
            distanceMeters: goal.distanceM,
            targetSeconds: goal.targetFinishSeconds,
          ),
    recent: recent,
  );
}

ReadinessView? _readiness(DailyReadinessRecord? r) {
  if (r == null) return null;
  final level = ReadinessLevel.values.asNameMap()[r.level];
  if (level == null) return null;
  return ReadinessView(
    level: level,
    computedAt: r.computedAt.toLocal(),
    flags: {
      if (r.flagHrv) ReadinessFlag.hrv,
      if (r.flagHr) ReadinessFlag.restingHr,
      if (r.flagSleep) ReadinessFlag.sleep,
      if (r.flagBattery) ReadinessFlag.battery,
      if (r.flagSkinTemp) ReadinessFlag.skinTemperature,
      if (r.flagFatigue) ReadinessFlag.fatigue,
    },
    hrvToday: r.hrvToday,
    hrvDropPct: r.hrvDropPct,
    restingHrToday: r.restingHrToday,
    restingHrElevation: r.restingHrElevation,
    sleepScore: r.sleepScore,
  );
}
