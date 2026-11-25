import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_core/services/compliance.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 25, 9);
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> session(String id, DateTime day, String status) => db
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
          title: 'Run $id',
          plannedDurationMin: 50,
          plannedTrimp: 50,
          sessionLevel: 2,
          status: Value(status),
        ),
      );

  test('an athlete who missed sessions and went quiet needs a look', () async {
    await session('a', DateTime(2026, 11, 20), 'planned');
    await session('b', DateTime(2026, 11, 22), 'planned');
    await session('c', DateTime(2026, 11, 27), 'planned');
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
    final s = await loadAthleteSummary(db, 'Mia', now: now);
    expect(s.past, hasLength(7));
    expect(s.past.last.date, DateTime(2026, 11, 25));
    expect(s.ahead.first.date, DateTime(2026, 11, 26));
    expect(s.missed, 2);
    expect(s.ahead[1].compliance, [Compliance.upcoming]);
    expect(s.alerts, {
      AthleteAlert.missedSessions,
      AthleteAlert.redReadiness,
      AthleteAlert.quiet,
    });
  });

  test('an athlete on track has no alerts', () async {
    await db
        .into(db.activityRecords)
        .insert(
          ActivityRecordsCompanion.insert(
            activityId: 'x',
            name: 'Run',
            type: 'running',
            startDate: DateTime(2026, 11, 24, 7),
            durationSeconds: 3000,
          ),
        );
    final s = await loadAthleteSummary(db, 'Ben', now: now);
    expect(s.alerts, isEmpty);
    expect(s.lastActivity, isNotNull);
  });
}
