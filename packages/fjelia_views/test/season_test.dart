import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_core/services/season/goal_set.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 25, 9);
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('no active plan, no season', () async {
    final view = await loadSeason(db, now: now);
    expect(view.isEmpty, isTrue);
  });

  test('the season as the phone planned it, with fitness ahead', () async {
    final season = {
      'outcome': 'feasibleWithTradeoffs',
      'goals': {
        'm': {
          'name': 'Hannover Marathon',
          'priority': 'A',
          'sport': 'running',
          'date': '2027-04-10',
        },
        'b': {
          'name': 'Brevet 200',
          'priority': 'B',
          'sport': 'cycling',
          'date': '2027-03-20',
        },
      },
      'conflicts': [
        {
          'kind': 'tooClose',
          'severity': 'warning',
          'goals': ['b', 'm'],
          'message': 'The brevet is three weeks before the marathon.',
          'alternatives': ['Ride it easy'],
        },
      ],
      'summary': ['Cycling stays at two rides a week.'],
      'weeks': [
        for (var w = 0; w < 3; w++)
          {
            'week':
                '2026-11-${(23 + w * 7) > 30 ? '0${23 + w * 7 - 30}' : 23 + w * 7}',
            'phase': w == 2 ? 'unload' : 'base',
            'intents': {'m': 'build', 'b': 'base'},
            'allocation': {
              'budgetMin': 480,
              'plannedMin': 420,
              'minutesBySport': {},
              if (w == 1) 'tradeoffs': ['shortLongRide'],
            },
          },
      ],
    };
    await db
        .into(db.trainingPlans)
        .insert(
          TrainingPlansCompanion.insert(
            id: 'p',
            athleteId: 'self',
            startDate: DateTime(2026, 11, 23),
            endDate: DateTime(2027, 4, 10),
            version: const Value(1),
            status: 'active',
            generatedAt: now,
            daysPerWeek: const Value(5),
            restDaysJson: const Value('[]'),
            strengthDaysJson: const Value('[]'),
            hoursPerWeek: const Value(8),
            seasonJson: Value(jsonEncode(season)),
          ),
        );
    for (var d = 0; d < 21; d++) {
      if (d % 2 == 1) continue;
      await db
          .into(db.trainingSessions)
          .insert(
            TrainingSessionsCompanion.insert(
              id: 's$d',
              planId: 'p',
              athleteId: 'self',
              sessionDate: DateTime(2026, 11, 23 + d),
              sessionNumber: 1,
              weekNumber: 1 + d ~/ 7,
              sport: d % 4 == 0 ? 'running' : 'cycling',
              sessionType: 'x',
              phase: 'base',
              primaryZone: 2,
              title: 'Session $d',
              plannedDurationMin: 60 + d,
              plannedTrimp: 70 + d,
              sessionLevel: 2,
            ),
          );
    }
    final view = await loadSeason(db, now: now);
    expect(view.outcome, FeasibilityOutcome.feasibleWithTradeoffs);
    expect(view.goals.map((g) => g.name), ['Brevet 200', 'Hannover Marathon']);
    expect(view.conflicts.single.severity, ConflictSeverity.warning);
    expect(view.summary.single, contains('Cycling'));
    expect(view.weeks, hasLength(3));
    final first = view.weeks.first;
    expect(first.minutesBySport.keys.toSet(), {'running', 'cycling'});
    expect(first.intents['Hannover Marathon'], 'build');
    expect(first.keySessions, hasLength(3));
    expect(view.weeks[1].tradeoffs, ['shortLongRide']);
    expect(view.weeks.last.form, isNotNull);
    expect(view.weekOf(DateTime(2026, 12, 1))?.start, DateTime(2026, 11, 30));
  });
}
