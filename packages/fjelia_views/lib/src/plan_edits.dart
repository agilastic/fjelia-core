import 'dart:math';

import 'package:drift/drift.dart';
import 'package:fjelia_core/services/season/goal_set.dart';
import 'package:fjelia_core/services/season/season_goal.dart';
import 'package:fjelia_core/utils/week.dart';
import 'package:fjelia_data/database.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Why a plan edit was not made.
sealed class PlanEditRefused implements Exception {
  const PlanEditRefused();
}

/// The day belongs to an event: the race itself or the rest day before it.
class EventDayRefused extends PlanEditRefused {
  const EventDayRefused(this.event);
  final String event;
}

/// The athlete is away that day; [kind] is the absence's.
class AbsenceRefused extends PlanEditRefused {
  const AbsenceRefused(this.kind);
  final String kind;
}

/// The session is already done and stays where it was done.
class DoneRefused extends PlanEditRefused {
  const DoneRefused();
}

/// A plan edit one by one failed for [session]; nothing was changed.
class PlanShiftRefused extends PlanEditRefused {
  const PlanShiftRefused(this.session, this.reason);
  final String session;
  final PlanEditRefused reason;
}

/// Changes to planned sessions that only touch the database, shared by the
/// phone and the computer. The rules are the same wherever the athlete
/// edits: a session never lands on an event day or a day away, and a
/// done session stays where it was done. Telling watch platforms is the
/// phone's part and follows when it syncs.
class PlanEdits {
  PlanEdits(this.db);
  final AppDatabase db;

  /// Every goal of the athlete, read once.
  Future<GoalSet> goalSet({String athleteId = 'self', DateTime? today}) async {
    final rows = await (db.select(
      db.raceGoals,
    )..where((t) => t.athleteId.equals(athleteId))).get();
    return GoalSet([
      for (final r in rows) SeasonGoal.fromRow(r),
    ], today: today ?? DateTime.now());
  }

  /// Throws when nothing may be planned on [day].
  Future<void> checkDay(DateTime day, {GoalSet? goals}) async {
    final target = _day(day);
    // An event day, or the rest day before it, belongs to the event.
    final event = (goals ?? await goalSet()).eventBlocking(target);
    if (event != null) throw EventDayRefused(event.name);
    // Nor a day the athlete is ill, injured or away.
    final away = await db.absencesBetween(target, target);
    if (away.isNotEmpty) throw AbsenceRefused(away.first.kind);
  }

  Future<TrainingSession> session(String id) => (db.select(
    db.trainingSessions,
  )..where((t) => t.id.equals(id))).getSingle();

  Future<TrainingSession> moveDay(TrainingSession session, int days) {
    final d = session.sessionDate;
    return moveToDate(session, DateTime(d.year, d.month, d.day + days));
  }

  /// Moves a session to [day] (the date only; the steps stay as they are).
  /// The first date it was planned for is kept, and the week number follows
  /// the plan's calendar weeks.
  Future<TrainingSession> moveToDate(
    TrainingSession session,
    DateTime day, {
    GoalSet? goals,
  }) async {
    if (session.status == 'completed') throw const DoneRefused();
    final d = session.sessionDate;
    final target = _day(day);
    await checkDay(target, goals: goals);
    final week = await _week(session, target);
    await (db.update(
      db.trainingSessions,
    )..where((t) => t.id.equals(session.id))).write(
      TrainingSessionsCompanion(
        sessionDate: Value(target),
        sessionDateOriginal: Value(
          session.sessionDateOriginal ?? d.toIso8601String(),
        ),
        priorSessionDate: Value(d.toIso8601String()),
        weekNumber: Value(week),
        isMovedFromDifferentWeek: Value(week != session.weekNumber),
        dateModified: Value(DateTime.now()),
        modifiedBy: const Value('athlete'),
      ),
    );
    return this.session(session.id);
  }

  /// A copy of [session] on [day], planned and not yet done.
  Future<TrainingSession> copyToDate(
    TrainingSession session,
    DateTime day,
  ) async {
    final target = _day(day);
    await checkDay(target);
    final id = _newId();
    await db
        .into(db.trainingSessions)
        .insert(
          session
              .toCompanion(true)
              .copyWith(
                id: Value(id),
                sessionDate: Value(target),
                weekNumber: Value(await _week(session, target)),
                status: const Value('planned'),
                sessionDateOriginal: const Value(null),
                priorSessionDate: const Value(null),
                isMovedFromDifferentWeek: const Value(false),
                garminWorkoutId: const Value(null),
                garminAlternativeId: const Value(null),
                addedByAthlete: const Value(true),
                dateModified: Value(DateTime.now()),
                modifiedBy: const Value('athlete'),
              ),
        );
    return this.session(id);
  }

  /// Removes a session, such as a copy the athlete made. A session the plan
  /// made is better marked as rest, so the plan knows it was let go.
  Future<void> delete(TrainingSession session) async {
    if (session.status == 'completed') throw const DoneRefused();
    await (db.delete(
      db.trainingSessions,
    )..where((t) => t.id.equals(session.id))).go();
  }

  /// Marks a planned session as rest, with [reason].
  Future<TrainingSession> markRest(
    TrainingSession session, {
    String reason = 'Marked as rest',
  }) async {
    if (session.status == 'completed') throw const DoneRefused();
    await db.transaction(() async {
      await (db.update(
        db.trainingSessions,
      )..where((t) => t.id.equals(session.id))).write(
        TrainingSessionsCompanion(
          status: const Value('skipped'),
          dateModified: Value(DateTime.now()),
          modifiedBy: const Value('athlete'),
        ),
      );
      await db
          .into(db.sessionActuals)
          .insertOnConflictUpdate(
            SessionActualsCompanion.insert(
              sessionId: session.id,
              skipReason: Value(reason),
            ),
          );
    });
    return this.session(session.id);
  }

  /// Plans a skipped session again. A sport replacement made from it is
  /// not handled here; the phone's restore does that.
  Future<TrainingSession> restore(TrainingSession session) async {
    if (session.status != 'skipped') return session;
    await db.transaction(() async {
      final actual = await (db.select(
        db.sessionActuals,
      )..where((t) => t.sessionId.equals(session.id))).getSingleOrNull();
      if (actual != null && actual.completedAt == null) {
        await (db.delete(
          db.sessionActuals,
        )..where((t) => t.sessionId.equals(session.id))).go();
      }
      await (db.update(
        db.trainingSessions,
      )..where((t) => t.id.equals(session.id))).write(
        TrainingSessionsCompanion(
          status: const Value('planned'),
          dateModified: Value(DateTime.now()),
          modifiedBy: const Value('athlete'),
        ),
      );
    });
    return this.session(session.id);
  }

  Future<TrainingSession> setNotes(
    TrainingSession session,
    String notes,
  ) async {
    await (db.update(
      db.trainingSessions,
    )..where((t) => t.id.equals(session.id))).write(
      TrainingSessionsCompanion(
        athleteNotes: Value(notes.trim().isEmpty ? null : notes.trim()),
        dateModified: Value(DateTime.now()),
        modifiedBy: const Value('athlete'),
      ),
    );
    return this.session(session.id);
  }

  /// Turns an outdoor session into its indoor form (treadmill, trainer) or
  /// back. The steps stay.
  Future<TrainingSession> setIndoor(
    TrainingSession session,
    bool indoor,
  ) async {
    if (session.indoor == indoor) return session;
    await (db.update(
      db.trainingSessions,
    )..where((t) => t.id.equals(session.id))).write(
      TrainingSessionsCompanion(
        indoor: Value(indoor),
        dateModified: Value(DateTime.now()),
        modifiedBy: const Value('athlete'),
      ),
    );
    return this.session(session.id);
  }

  /// Sets the main target of a ride, `hr` or `power`. The steps keep their
  /// zones and the other value stays in the step note.
  Future<TrainingSession> setTargetMetric(
    TrainingSession session,
    String metric,
  ) async {
    if (session.targetMetric == metric) return session;
    await (db.update(
      db.trainingSessions,
    )..where((t) => t.id.equals(session.id))).write(
      TrainingSessionsCompanion(
        targetMetric: Value(metric),
        dateModified: Value(DateTime.now()),
        modifiedBy: const Value('athlete'),
      ),
    );
    return this.session(session.id);
  }

  /// Moves every session of [planId] from [from] on by [days], as one
  /// piece: when one of them cannot go (an event day, a day away), none
  /// moves. Done sessions stay. Returns how many moved.
  Future<int> shiftPlan(String planId, int days, {required DateTime from}) =>
      db.transaction(() async {
        final start = _day(from);
        final sessions =
            await (db.select(db.trainingSessions)..where(
                  (t) =>
                      t.planId.equals(planId) &
                      t.sessionDate.isBiggerOrEqualValue(start) &
                      t.status.isIn(const ['planned', 'adapted', 'skipped']),
                ))
                .get();
        final goals = await goalSet();
        for (final s in sessions) {
          final d = s.sessionDate.toLocal();
          try {
            await checkDay(
              DateTime(d.year, d.month, d.day + days),
              goals: goals,
            );
          } on PlanEditRefused catch (e) {
            throw PlanShiftRefused(s.title, e);
          }
        }
        for (final s in sessions) {
          await moveDay(s, days);
        }
        return sessions.length;
      });

  /// Copies the planned sessions of the week starting [from] into the week
  /// starting [to]; days that cannot take one are left out. Returns the
  /// copies.
  Future<List<TrainingSession>> copyWeek(DateTime from, DateTime to) async {
    final start = _day(from);
    final sessions =
        await (db.select(db.trainingSessions)
              ..where(
                (t) =>
                    t.athleteId.equals('self') &
                    t.sessionDate.isBiggerOrEqualValue(start) &
                    t.sessionDate.isSmallerThanValue(
                      start.add(const Duration(days: 7)),
                    ) &
                    t.status.isIn(const ['planned', 'adapted', 'completed']),
              )
              ..orderBy([(t) => OrderingTerm(expression: t.sessionDate)]))
            .get();
    final copies = <TrainingSession>[];
    final offset = DateTime.utc(
      to.year,
      to.month,
      to.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    for (final s in sessions) {
      final d = s.sessionDate.toLocal();
      try {
        copies.add(
          await copyToDate(s, DateTime(d.year, d.month, d.day + offset)),
        );
      } on PlanEditRefused {
        // That day cannot take it; the rest of the week still copies.
      }
    }
    return copies;
  }

  /// Calendar weeks from the plan's anchor, as the plan generator counts.
  Future<int> _week(TrainingSession session, DateTime target) async {
    final plan = await (db.select(
      db.trainingPlans,
    )..where((t) => t.id.equals(session.planId))).getSingleOrNull();
    if (plan == null) return session.weekNumber;
    final anchor = weekStartOf(plan.startDate);
    return (DateTime.utc(target.year, target.month, target.day)
                    .difference(
                      DateTime.utc(anchor.year, anchor.month, anchor.day),
                    )
                    .inDays ~/
                7 +
            1)
        .clamp(1, 156);
  }

  static final _random = Random.secure();

  static String _newId() {
    String hex(int bytes) => [
      for (var i = 0; i < bytes; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    return '${hex(4)}-${hex(2)}-${hex(2)}-${hex(2)}-${hex(6)}';
  }
}
