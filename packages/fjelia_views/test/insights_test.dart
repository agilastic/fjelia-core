import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_core/services/activity_kind.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

/// Samples every second: [power] and [hr] by second.
String samples(DateTime start, List<double> power, double Function(int) hr) =>
    jsonEncode([
      for (var i = 0; i < power.length; i++)
        {
          't': start.add(Duration(seconds: i)).millisecondsSinceEpoch,
          'w': power[i],
          'hr': hr(i),
        },
    ]);

List<double> repeat(double v, int n) => List.filled(n, v);

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 27, 9);
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> ride(
    String id,
    DateTime start,
    List<double> power, {
    double Function(int)? hr,
  }) => db
      .into(db.activityRecords)
      .insert(
        ActivityRecordsCompanion.insert(
          activityId: id,
          name: 'Ride',
          type: 'cycling',
          startDate: start,
          durationSeconds: power.length,
          avgWatts: Value(power.reduce((a, b) => a + b) / power.length),
          trainingLoad: const Value(50),
          distanceMeters: Value(power.length * 8.0),
          metricsJson: Value(samples(start, power, hr ?? (_) => 140)),
        ),
      );

  test(
    'a ride\'s intervals, W′ balance against the model, and decoupling',
    () async {
      // Earlier best efforts made by a rider with CP 250 W and W′ 20 kJ.
      for (final (i, t) in [180, 300, 600, 1200].indexed) {
        await ride('test$i', DateTime(2026, 11, 1 + i, 8), [
          ...repeat(150, 300),
          ...repeat(250 + 20000 / t, t),
          ...repeat(150, 300),
        ]);
      }
      final intervals = [
        ...repeat(180, 900),
        for (var r = 0; r < 5; r++) ...[
          ...repeat(300, 240),
          ...repeat(150, 180),
        ],
        ...repeat(180, 1200),
      ];
      await ride(
        'vo2',
        DateTime(2026, 11, 20, 8),
        intervals,
        hr: (i) => i < intervals.length / 2 ? 140 : 150,
      );
      final x = await loadActivityInsights(db, 'vo2');
      expect(x.criticalPower!.cp, closeTo(250, 1));
      expect(x.criticalPower!.wPrime, closeTo(20000, 300));
      expect(x.byPower, isTrue);
      expect(x.intervals, hasLength(5));
      expect(x.fade.first, 0);
      // Each 4 minutes at 330 W spends 80 × 240 J of the 20 kJ, partly back
      // between them: the fifth goes deepest.
      expect(x.lowestWPrime!, lessThan(10000));
      expect(x.lowestWPrime!, greaterThan(0));
      expect(
        x.wPrimeBalance.length,
        lessThanOrEqualTo(ActivityInsights.maxPoints + 1),
      );
      expect(x.aerobic!.decouplingPercent, greaterThan(5));
    },
  );

  test(
    'trends: efficiency per activity, weekly hours with empty weeks',
    () async {
      await ride('a', DateTime(2026, 11, 2, 8), repeat(200, 3600));
      await ride(
        'b',
        DateTime(2026, 11, 16, 8),
        repeat(210, 3600),
        hr: (_) => 135,
      );
      await ride('short', DateTime(2026, 11, 17, 8), repeat(200, 900));
      final ef = await loadTrend(
        db,
        TrendMetric.efficiencyFactor,
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 11, 30),
      );
      expect(ef.map((p) => p.activityId), ['a', 'b']);
      expect(ef.last.value, greaterThan(ef.first.value));
      final weekly = await loadTrend(
        db,
        TrendMetric.weeklyHours,
        from: DateTime(2026, 11, 2),
        to: DateTime(2026, 11, 22),
      );
      expect(weekly.map((p) => p.value), [1, 0, 1.25]);
      final long = await loadTrend(
        db,
        TrendMetric.load,
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 11, 30),
        filter: const TrendFilter(sport: ActivityKind.cycling, minMinutes: 30),
      );
      expect(long, hasLength(2));
    },
  );

  test('planned against done, week by week', () async {
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
            sport: 'cycling',
            sessionType: 'x',
            phase: 'base',
            primaryZone: 2,
            title: 'Ride',
            plannedDurationMin: 60,
            plannedTrimp: 100,
            sessionLevel: 2,
            status: Value(status),
          ),
        );
    await session('s1', DateTime(2026, 11, 24), 'completed');
    await session('s2', DateTime(2026, 11, 26), 'missed');
    await ride('r', DateTime(2026, 11, 24, 8), repeat(200, 3600));
    final weeks = await loadPlannedVsDone(db, weeks: 2, now: now);
    expect(weeks, hasLength(2));
    final w = weeks.last;
    expect((w.plannedSessions, w.completedSessions), (2, 1));
    expect((w.plannedMinutes, w.doneMinutes), (120, 60));
    expect(w.compliance, closeTo(w.doneLoad / 200 * 100, .001));
    expect(weeks.first.compliance, isNull);
  });

  test('a period in numbers, to compare with another', () async {
    await ride('a', DateTime(2026, 11, 2, 8), repeat(200, 3600));
    await ride('b', DateTime(2026, 11, 16, 8), repeat(300, 1800));
    final p = await loadPeriodSummary(
      db,
      from: DateTime(2026, 11, 1),
      to: DateTime(2026, 11, 10),
    );
    expect((p.activities, p.hours), (1, 1));
    expect(p.bySport[ActivityKind.cycling], 1);
    expect(p.bestPower[1200], closeTo(200, .01));
    expect(p.efficiencyFactor, closeTo(200 / 140, .01));
  });
}
