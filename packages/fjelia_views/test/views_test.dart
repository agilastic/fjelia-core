import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_core/models/garmin_data.dart';
import 'package:fjelia_core/services/activity_kind.dart';
import 'package:fjelia_core/services/readiness.dart';
import 'package:fjelia_core/services/training_form.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  // Wednesday.
  final now = DateTime(2026, 11, 25, 9, 41);
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> activity(
    String id,
    String type,
    DateTime start, {
    int minutes = 60,
    double? km,
    double? hr,
    double? watts,
  }) => db
      .into(db.activityRecords)
      .insert(
        ActivityRecordsCompanion.insert(
          activityId: id,
          name: 'Activity $id',
          type: type,
          startDate: start,
          durationSeconds: minutes * 60,
          distanceMeters: Value(km == null ? null : km * 1000),
          avgHeartRate: Value(hr),
          avgWatts: Value(watts),
          trainingLoad: const Value(50),
        ),
      );

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
          sessionType: 'intervals',
          phase: 'base',
          primaryZone: 4,
          title: 'Session $id',
          plannedDurationMin: 55,
          plannedTrimp: 74,
          sessionLevel: 3,
          status: Value(status),
        ),
      );

  test('an empty database shows an empty Today', () async {
    final today = await loadToday(db, now: now);
    expect(today.isEmpty, isTrue);
    expect(today.load.status, FormStatus.noHistory);
    expect(today.week.days, hasLength(7));
    expect(today.week.days.first.date, DateTime(2026, 11, 23));
    final sundayFirst = await loadToday(db, now: now, mondayFirst: false);
    expect(sundayFirst.week.days.first.date, DateTime(2026, 11, 22));
  });

  test(
    'Today has the plan, the week, the goal and recent activities',
    () async {
      await activity('mon', 'running', DateTime(2026, 11, 23, 7), km: 10);
      await activity('last', 'cycling', DateTime(2026, 11, 20, 7));
      await session('s1', DateTime(2026, 11, 23), 'completed');
      await session('s2', DateTime(2026, 11, 25), 'planned');
      await session('s3', DateTime(2026, 11, 25), 'skipped');
      await session('s4', DateTime(2026, 11, 30), 'planned'); // next week
      await db
          .into(db.raceGoals)
          .insert(
            RaceGoalsCompanion.insert(
              id: 'g',
              athleteId: 'self',
              name: 'Hannover Marathon',
              primarySport: 'running',
              distanceM: 42195,
              raceDate: DateTime(2027, 4, 10),
              priority: 'A',
              source: 'athlete',
              createdAt: now,
              targetFinishSeconds: const Value(12600),
            ),
          );
      await db
          .into(db.dailyReadinessRecords)
          .insert(
            DailyReadinessRecordsCompanion.insert(
              id: 'r',
              athleteId: 'self',
              date: DateTime(now.year, now.month, now.day),
              level: 'yellow',
              computedAt: DateTime(2026, 11, 25, 6, 52),
              flagHrv: const Value(true),
              hrvToday: const Value(58),
            ),
          );

      final today = await loadToday(db, now: now);
      expect(today.today.map((s) => s.id), ['s2']);
      expect(today.week.planned, const Duration(minutes: 110));
      expect(today.week.plannedLoad, 148);
      expect(today.week.done, const Duration(hours: 1));
      expect(today.week.days.first.activities.single.id, 'mon');
      expect(today.recent.map((a) => a.id), ['mon', 'last']);
      expect(today.nextGoal?.name, 'Hannover Marathon');
      expect(today.nextGoal?.daysToGo, 136);
      expect(today.readiness?.level, ReadinessLevel.yellow);
      expect(today.readiness?.flags, {ReadinessFlag.hrv});
      expect(today.load.hasHistory, isTrue);
    },
  );

  test('the list groups by month and filters by sport', () async {
    await activity('a', 'running', DateTime(2026, 11, 22));
    await activity('b', 'virtual_ride', DateTime(2026, 11, 21));
    await activity('c', 'trail_running', DateTime(2026, 10, 3));
    final all = await loadActivityList(db);
    expect(all.total, 3);
    expect(all.months.map((m) => m.month), [
      DateTime(2026, 11),
      DateTime(2026, 10),
    ]);
    final runs = await loadActivityList(db, filter: SportFilter.run);
    expect(runs.total, 3);
    expect(runs.months.expand((m) => m.items).map((a) => a.id), ['a', 'c']);
    final rides = await loadActivityList(db, filter: SportFilter.ride);
    expect(rides.months.single.items.single.id, 'b');
  });

  test('a run shows pace, a ride speed and power', () async {
    await activity('run', 'running', DateTime(2026, 11, 22), km: 10, hr: 150);
    await activity(
      'ride',
      'cycling',
      DateTime(2026, 11, 21),
      minutes: 120,
      km: 60,
      watts: 210,
    );
    final run = (await loadActivityDetail(db, 'run'))!;
    final stats = {for (final (k, v) in run.stats) k: v};
    expect(stats[ActivityStat.pace], 360); // 6:00 per km
    expect(stats.containsKey(ActivityStat.speed), isFalse);
    expect(stats[ActivityStat.avgHeartRate], 150);
    final ride = (await loadActivityDetail(db, 'ride'))!;
    final rideStats = {for (final (k, v) in ride.stats) k: v};
    expect(rideStats[ActivityStat.speed], closeTo(8.33, 0.01));
    expect(rideStats[ActivityStat.avgPower], 210);
    expect(rideStats.containsKey(ActivityStat.pace), isFalse);
    expect(await loadActivityDetail(db, 'missing'), isNull);
  });

  test('a run graphs pace, a ride speed, and only what was measured', () {
    final start = DateTime(2026, 11, 22, 8);
    final samples = [
      for (var i = 0; i < 2000; i++)
        ActivitySample(
          timestamp: start.add(Duration(seconds: i)),
          distanceMeters: i * 3.0,
          heartRate: 140,
          speed: 3,
          elevation: 50,
        ),
    ];
    final run = activitySeries(ActivityKind.running, samples, start);
    expect(run.keys, [
      ActivitySeries.heartRate,
      ActivitySeries.pace,
      ActivitySeries.elevation,
    ]);
    expect(run[ActivitySeries.pace]!.first.$2, closeTo(333.3, 0.1));
    expect(
      run[ActivitySeries.heartRate]!.length,
      lessThanOrEqualTo(ActivityDetail.maxSeriesPoints),
    );
    final ride = activitySeries(ActivityKind.cycling, samples, start);
    expect(ride.containsKey(ActivitySeries.speed), isTrue);
    expect(ride.containsKey(ActivitySeries.pace), isFalse);
    expect(ride.containsKey(ActivitySeries.power), isFalse);
  });
}
