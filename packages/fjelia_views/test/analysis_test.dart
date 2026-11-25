import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 25, 9);
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  String watts(DateTime start, int seconds, int w) => jsonEncode([
    for (var i = 0; i <= seconds; i++)
      {'t': start.toUtc().millisecondsSinceEpoch + i * 1000, 'w': w},
  ]);

  Future<void> ride(String id, DateTime start, int w) => db
      .into(db.activityRecords)
      .insert(
        ActivityRecordsCompanion.insert(
          activityId: id,
          name: 'Ride',
          type: 'cycling',
          startDate: start,
          durationSeconds: 1800,
          avgWatts: Value(w.toDouble()),
          trainingLoad: const Value(40),
          metricsJson: Value(watts(start, 1800, w)),
        ),
      );

  test('an empty database gives an empty analysis', () async {
    final view = await loadAnalysis(db, now: now);
    expect(view.isEmpty, isTrue);
    expect(view.forecast, isEmpty);
    expect(view.zoneWeeks, hasLength(AnalysisView.zoneWeeksShown));
    expect(view.easyShare, isNull);
    expect(view.powerCurve.isEmpty, isTrue);
  });

  test('history, forecast, power, zones and thresholds', () async {
    await ride('this', DateTime(2026, 11, 20, 8), 250);
    await ride('last', DateTime(2025, 6, 1, 8), 280);
    await ride('older', DateTime(2024, 6, 1, 8), 400); // before last year
    await db
        .into(db.trainingSessions)
        .insert(
          TrainingSessionsCompanion.insert(
            id: 's',
            planId: 'p',
            athleteId: 'self',
            sessionDate: DateTime(2026, 11, 27),
            sessionNumber: 1,
            weekNumber: 1,
            sport: 'running',
            sessionType: 'x',
            phase: 'base',
            primaryZone: 2,
            title: 'Run',
            plannedDurationMin: 60,
            plannedTrimp: 300,
            sessionLevel: 2,
          ),
        );
    await db
        .into(db.hrZoneSummaries)
        .insert(
          HrZoneSummariesCompanion.insert(
            activityId: 'this',
            definitionId: 1,
            algorithmVersion: 1,
            sport: 'cycling',
            startDate: DateTime(2026, 11, 20, 8),
            elapsedSeconds: 1800,
            coveredSeconds: 1800,
            zoneSecondsJson: '[600,600,300,200,100]',
            computedAt: now,
          ),
        );
    await db
        .into(db.thresholdRecords)
        .insert(
          ThresholdRecordsCompanion.insert(
            date: DateTime(2026, 10, 1),
            activityId: 'this',
            source: 'eftp',
            ftpWatts: const Value(265),
          ),
        );

    final view = await loadAnalysis(
      db,
      range: AnalysisRange.sixWeeks,
      now: now,
    );
    expect(view.form, hasLength(42));
    expect(view.form.last.date, DateTime(2026, 11, 25));
    expect(view.forecast, hasLength(AnalysisView.forecastDays));
    final planned = view.forecast.firstWhere(
      (p) => p.date == DateTime(2026, 11, 27),
    );
    expect(planned.load, 300);
    expect(view.powerCurve.thisYear[1200], 250);
    expect(view.powerCurve.lastYear[1200], 280);
    expect(view.powerCurve.thisYear.containsKey(3600), isFalse);
    final week = view.zoneWeeks.firstWhere(
      (w) => w.start == DateTime(2026, 11, 16),
    );
    expect(week.total, 1800);
    expect(week.easyShare, closeTo(2 / 3, 0.001));
    expect(view.easyShare, closeTo(2 / 3, 0.001));
    expect(view.thresholds.single.ftpWatts, 265);
    expect(view.records[StatsSport.ride]!.allTime.count, 3);
  });
}
