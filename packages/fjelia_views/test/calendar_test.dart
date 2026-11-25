import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_core/services/compliance.dart';
import 'package:fjelia_core/services/readiness.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 25, 9); // a Wednesday
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> activity(String id, DateTime start, {int minutes = 60}) => db
      .into(db.activityRecords)
      .insert(
        ActivityRecordsCompanion.insert(
          activityId: id,
          name: 'Run $id',
          type: 'running',
          startDate: start,
          durationSeconds: minutes * 60,
          distanceMeters: const Value(10000),
          trainingLoad: const Value(50),
        ),
      );

  Future<void> session(
    String id,
    DateTime day,
    String status, {
    String? activityId,
    String? verdict,
  }) async {
    await db
        .into(db.trainingSessions)
        .insert(
          TrainingSessionsCompanion.insert(
            id: id,
            planId: 'p',
            athleteId: 'self',
            sessionDate: day,
            sessionNumber: 1,
            weekNumber: 1,
            sport: 'running',
            sessionType: 'easy',
            phase: 'base',
            primaryZone: 2,
            title: 'Session $id',
            plannedDurationMin: 60,
            plannedTrimp: 55,
            sessionLevel: 2,
            status: Value(status),
          ),
        );
    if (activityId != null) {
      await db
          .into(db.sessionActuals)
          .insert(
            SessionActualsCompanion.insert(
              sessionId: id,
              activityId: Value(activityId),
              executionVerdict: Value(verdict),
            ),
          );
    }
  }

  test('a month spans whole weeks in the week start', () async {
    final november = await loadCalendarMonth(db, now, now: now);
    expect(november.weeks.first.start, DateTime(2026, 10, 26));
    expect(november.weeks.last.days.last.date, DateTime(2026, 12, 6));
    expect(november.weeks, hasLength(6));
    final days = november.weeks.expand((w) => w.days);
    expect(days.where((d) => d.isToday).single.date, DateTime(2026, 11, 25));
    expect(days.first.inFocus, isFalse);
    expect(days.firstWhere((d) => d.inFocus).date, DateTime(2026, 11, 1));
    final sundayFirst = await loadCalendarMonth(
      db,
      now,
      mondayFirst: false,
      now: now,
    );
    expect(sundayFirst.weeks.first.start, DateTime(2026, 11, 1));
  });

  test(
    'sessions show how they were done; extra activities show apart',
    () async {
      await activity('a1', DateTime(2026, 11, 23, 7));
      await activity('a2', DateTime(2026, 11, 24, 7), minutes: 30);
      await activity('extra', DateTime(2026, 11, 24, 18));
      await session(
        's1',
        DateTime(2026, 11, 23),
        'completed',
        activityId: 'a1',
        verdict: 'on_target',
      );
      await session(
        's2',
        DateTime(2026, 11, 24),
        'completed',
        activityId: 'a2',
        verdict: 'under',
      );
      await session('s3', DateTime(2026, 11, 22), 'planned'); // last Sunday
      await session('s4', DateTime(2026, 11, 26), 'planned');
      await db
          .into(db.absences)
          .insert(
            AbsencesCompanion.insert(
              kind: 'vacation',
              startDay: DateTime(2026, 11, 28),
              endDay: DateTime(2026, 11, 29),
              createdAt: now,
            ),
          );
      await db
          .into(db.dailyReadinessRecords)
          .insert(
            DailyReadinessRecordsCompanion.insert(
              id: 'r',
              athleteId: 'self',
              date: DateTime(2026, 11, 25),
              level: 'red',
              computedAt: now,
            ),
          );

      final week = (await loadCalendarWeek(db, now, now: now)).weeks.single;
      CalendarDay day(int d) => week.days.firstWhere((x) => x.date.day == d);
      final monday = day(23).entries.single as SessionEntry;
      expect(monday.compliance, Compliance.onTarget);
      expect(monday.activity?.id, 'a1');
      final tuesday = day(24).entries;
      expect((tuesday.first as SessionEntry).compliance, Compliance.partly);
      expect((tuesday.last as ActivityEntry).activity.id, 'extra');
      expect(
        (day(26).entries.single as SessionEntry).compliance,
        Compliance.upcoming,
      );
      expect(day(28).entries.single, isA<AbsenceEntry>());
      expect(day(25).readiness, ReadinessLevel.red);
      expect(week.summary.done, const Duration(minutes: 150));
      expect(week.summary.planned, const Duration(hours: 3));
      expect(week.summary.form, isNotNull);

      final last = (await loadCalendarWeek(
        db,
        DateTime(2026, 11, 22),
        now: now,
      )).weeks.single;
      expect(
        (last.days.last.entries.single as SessionEntry).compliance,
        Compliance.missed,
      );
      final next = (await loadCalendarWeek(
        db,
        DateTime(2026, 12, 1),
        now: now,
      )).weeks.single;
      expect(next.summary.form, isNull);
    },
  );
}
