import 'package:drift/drift.dart';
import 'package:fjelia_core/services/compliance.dart';
import 'package:fjelia_core/services/readiness.dart';
import 'package:fjelia_core/services/training_form.dart';
import 'package:fjelia_core/utils/week.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_core/utils/days.dart';

import 'activities.dart';
import 'today.dart';
import 'training_load.dart';

/// Something on a calendar day.
sealed class CalendarEntry {
  const CalendarEntry();
}

/// A planned session, with the activity that did it when there is one.
class SessionEntry extends CalendarEntry {
  const SessionEntry(this.session, this.compliance, {this.activity});
  final PlannedSession session;
  final Compliance compliance;
  final ActivityItem? activity;
}

/// An activity no session asked for.
class ActivityEntry extends CalendarEntry {
  const ActivityEntry(this.activity);
  final ActivityItem activity;
  Compliance get compliance => Compliance.unplanned;
}

/// A race goal on its day.
class RaceEntry extends CalendarEntry {
  const RaceEntry(this.goal);
  final GoalView goal;
}

/// A time the athlete cannot train: `illness`, `injury`, `vacation` or
/// `offseason`.
class AbsenceEntry extends CalendarEntry {
  const AbsenceEntry(this.kind, {required this.first, required this.last});
  final String kind;
  final DateTime first;
  final DateTime last;
}

class CalendarDay {
  const CalendarDay({
    required this.date,
    required this.entries,
    required this.isToday,
    required this.inFocus,
    this.hrv,
    this.readiness,
  });

  final DateTime date;

  /// Races and absences first, then sessions and activities by time.
  final List<CalendarEntry> entries;
  final bool isToday;

  /// In the month or week being looked at; the days around it are dimmed.
  final bool inFocus;

  /// Last night's HRV, ms.
  final double? hrv;
  final ReadinessLevel? readiness;
}

/// The week's totals, as in the calendar's summary column.
class CalendarWeekSummary {
  const CalendarWeekSummary({
    required this.done,
    required this.planned,
    required this.distanceMeters,
    required this.load,
    required this.plannedLoad,
    this.form,
  });

  final Duration done;
  final Duration planned;
  final double distanceMeters;
  final double load;
  final int plannedLoad;

  /// Fitness, fatigue and form at the end of the week, or today for the
  /// current week; null for weeks to come.
  final FormPoint? form;
}

class CalendarWeek {
  const CalendarWeek(this.days, this.summary);
  final List<CalendarDay> days;
  final CalendarWeekSummary summary;
  DateTime get start => days.first.date;
}

class CalendarView {
  const CalendarView(
    this.weeks, {
    required this.focusStart,
    required this.focusEnd,
  });
  final List<CalendarWeek> weeks;

  /// The month or week asked for, end excluded.
  final DateTime focusStart;
  final DateTime focusEnd;
}

/// The weeks around [month]: from the week its first day falls in to the
/// week of its last day.
Future<CalendarView> loadCalendarMonth(
  AppDatabase db,
  DateTime month, {
  bool mondayFirst = true,
  DateTime? now,
}) {
  final first = DateTime(month.year, month.month);
  final next = DateTime(month.year, month.month + 1);
  final start = weekStartOf(first, mondayFirst: mondayFirst);
  final lastWeek = weekStartOf(
    next.subtract(const Duration(hours: 12)),
    mondayFirst: mondayFirst,
  );
  final weeks =
      (DateTime.utc(lastWeek.year, lastWeek.month, lastWeek.day)
              .difference(DateTime.utc(start.year, start.month, start.day))
              .inDays ~/
          7) +
      1;
  return loadCalendar(
    db,
    start: start,
    weeks: weeks,
    focusStart: first,
    focusEnd: next,
    now: now,
  );
}

/// The week that contains [day].
Future<CalendarView> loadCalendarWeek(
  AppDatabase db,
  DateTime day, {
  bool mondayFirst = true,
  DateTime? now,
}) {
  final start = weekStartOf(day, mondayFirst: mondayFirst);
  return loadCalendar(
    db,
    start: start,
    weeks: 1,
    focusStart: start,
    focusEnd: DateTime(start.year, start.month, start.day + 7),
    now: now,
  );
}

Future<CalendarView> loadCalendar(
  AppDatabase db, {
  required DateTime start,
  required int weeks,
  required DateTime focusStart,
  required DateTime focusEnd,
  DateTime? now,
}) async {
  final today = dayOf(now ?? DateTime.now());
  final end = DateTime(start.year, start.month, start.day + 7 * weeks);

  final s = db.trainingSessions;
  final sessions =
      await (db.select(s)
            ..where(
              (t) =>
                  t.athleteId.equals('self') &
                  t.sessionDate.isBiggerOrEqualValue(start) &
                  t.sessionDate.isSmallerThanValue(end) &
                  t.status.isIn([...plannedSessionStates, 'skipped']),
            )
            ..orderBy([
              (t) => OrderingTerm(expression: t.sessionDate),
              (t) => OrderingTerm(expression: t.sessionNumber),
            ]))
          .get();
  final actuals = {
    for (final a in await (db.select(
      db.sessionActuals,
    )..where((a) => a.sessionId.isIn([for (final x in sessions) x.id]))).get())
      a.sessionId: a,
  };
  final activities = {
    for (final a in await readActivityItems(db, since: start))
      if (a.start.isBefore(end)) a.id: a,
  };
  final matched = <String>{};
  final byDay = <DateTime, List<CalendarEntry>>{};
  void add(DateTime day, CalendarEntry e) => (byDay[day] ??= []).add(e);

  for (final x in sessions) {
    final day = dayOf(x.sessionDate.toLocal());
    final actual = actuals[x.id];
    final activityId = actual?.activityId ?? actual?.creditedByActivityId;
    final activity = activityId == null ? null : activities[activityId];
    if (activity != null) matched.add(activity.id);
    add(
      day,
      SessionEntry(
        PlannedSession(
          id: x.id,
          title: x.title,
          sport: x.sport,
          date: day,
          durationMin: x.plannedDurationMin,
          zone: x.primaryZone,
          load: x.plannedTrimp,
          done: x.status == 'completed',
        ),
        Compliance.ofSession(
          status: x.status,
          isPast: day.isBefore(today),
          verdict: actual?.executionVerdict,
        ),
        activity: activity,
      ),
    );
  }
  for (final a in activities.values) {
    if (!matched.contains(a.id)) add(dayOf(a.start), ActivityEntry(a));
  }
  for (final g
      in await (db.select(db.raceGoals)..where(
            (g) =>
                g.athleteId.equals('self') &
                g.raceDate.isBiggerOrEqualValue(start) &
                g.raceDate.isSmallerThanValue(end),
          ))
          .get()) {
    final day = dayOf(g.raceDate.toLocal());
    add(
      day,
      RaceEntry(
        GoalView(
          name: g.name,
          date: day,
          daysToGo: 0,
          priority: g.priority,
          sport: g.primarySport,
          distanceMeters: g.distanceM,
          targetSeconds: g.targetFinishSeconds,
        ),
      ),
    );
  }
  final absences = await db.absencesBetween(
    start,
    end.subtract(const Duration(days: 1)),
  );

  final hrv = <DateTime, double>{};
  for (final r
      in await (db.select(db.hrvRecords)..where(
            (r) =>
                r.date.isBiggerOrEqualValue(start) &
                r.date.isSmallerThanValue(end),
          ))
          .get()) {
    if (r.hrvLastNight case final v? when v > 0) {
      hrv[dayOf(r.date.toLocal())] = v;
    }
  }
  final readiness = <DateTime, ReadinessLevel>{};
  for (final r
      in await (db.select(db.dailyReadinessRecords)..where(
            (r) =>
                r.athleteId.equals('self') &
                r.date.isBiggerOrEqualValue(start) &
                r.date.isSmallerThanValue(end),
          ))
          .get()) {
    if (ReadinessLevel.values.asNameMap()[r.level] case final level?) {
      readiness[dayOf(r.date.toLocal())] = level;
    }
  }
  final form = {
    for (final p in (await readTrainingLoadHistory(db, now: today)).points)
      dayOf(p.date): p,
  };

  int rank(CalendarEntry e) => switch (e) {
    RaceEntry() => 0,
    AbsenceEntry() => 1,
    _ => 2,
  };
  return CalendarView(
    [
      for (var w = 0; w < weeks; w++)
        () {
          final days = [
            for (var i = 0; i < 7; i++)
              () {
                final date = DateTime(
                  start.year,
                  start.month,
                  start.day + w * 7 + i,
                );
                final entries = [
                  ...?byDay[date],
                  for (final a in absences)
                    if (!dayOf(a.startDay).isAfter(date) &&
                        !dayOf(a.endDay).isBefore(date))
                      AbsenceEntry(
                        a.kind,
                        first: dayOf(a.startDay),
                        last: dayOf(a.endDay),
                      ),
                ]..sort((a, b) => rank(a).compareTo(rank(b)));
                return CalendarDay(
                  date: date,
                  entries: entries,
                  isToday: date == today,
                  inFocus:
                      !date.isBefore(focusStart) && date.isBefore(focusEnd),
                  hrv: hrv[date],
                  readiness: readiness[date],
                );
              }(),
          ];
          final done = [
            for (final d in days)
              for (final e in d.entries)
                if (e case SessionEntry(:final activity?))
                  activity
                else if (e case ActivityEntry(:final activity))
                  activity,
          ];
          final planned = [
            for (final d in days)
              for (final e in d.entries)
                if (e case SessionEntry(:final session)) session,
          ];
          final last = days.last.date.isAfter(today) ? today : days.last.date;
          return CalendarWeek(
            days,
            CalendarWeekSummary(
              done: done.fold(Duration.zero, (s, a) => s + a.duration),
              planned: Duration(
                minutes: planned.fold(0, (s, p) => s + p.durationMin),
              ),
              distanceMeters: done.fold(
                0,
                (s, a) => s + (a.distanceMeters ?? 0),
              ),
              load: done.fold(0, (s, a) => s + a.load),
              plannedLoad: planned.fold(0, (s, p) => s + p.load),
              form: days.first.date.isAfter(today) ? null : form[last],
            ),
          );
        }(),
    ],
    focusStart: focusStart,
    focusEnd: focusEnd,
  );
}

/// One saved workout of the library.
class LibraryWorkout {
  const LibraryWorkout({
    required this.id,
    required this.name,
    required this.sport,
    required this.durationMin,
    required this.load,
    required this.description,
  });
  final String id;
  final String name;
  final String sport;
  final int durationMin;
  final int load;
  final String description;
}

/// The saved workouts by sport, most used first.
Future<Map<String, List<LibraryWorkout>>> loadWorkoutLibrary(
  AppDatabase db,
) async {
  final t = db.workoutTemplates;
  final rows =
      await (db.select(t)..orderBy([
            (x) => OrderingTerm.desc(x.usageCount),
            (x) => OrderingTerm(expression: x.name),
          ]))
          .get();
  final library = <String, List<LibraryWorkout>>{};
  for (final r in rows) {
    (library[r.sport] ??= []).add(
      LibraryWorkout(
        id: r.id,
        name: r.name,
        sport: r.sport,
        durationMin: r.estimatedDurationMin,
        load: r.estimatedTss,
        description: r.description,
      ),
    );
  }
  return library;
}
