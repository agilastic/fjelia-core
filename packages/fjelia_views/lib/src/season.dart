import 'package:drift/drift.dart';
import 'package:fjelia_core/services/season/goal_set.dart';
import 'package:fjelia_core/services/season/season_report.dart';
import 'package:fjelia_core/services/training_form.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_core/utils/days.dart';

import 'today.dart' show PlannedSession, plannedSessionStates;
import 'training_load.dart';

/// A goal the season is planned for.
class SeasonGoal {
  const SeasonGoal({
    required this.id,
    required this.name,
    required this.priority,
    required this.sport,
    this.date,
  });
  final String id;
  final String name;

  /// `A`, `B` or `C`.
  final String priority;
  final String sport;
  final DateTime? date;
}

/// A problem between goals, in the planner's words.
class SeasonConflict {
  const SeasonConflict(this.severity, this.message, this.alternatives);
  final ConflictSeverity severity;
  final String message;
  final List<String> alternatives;
}

/// One week of the season.
class SeasonWeek {
  const SeasonWeek({
    required this.start,
    required this.phase,
    required this.minutesBySport,
    required this.budgetMin,
    required this.sessions,
    required this.tradeoffs,
    required this.unmet,
    required this.intents,
    this.form,
  });

  final DateTime start;

  /// `base`, `build`, `peak`, `taper`, `race`, `recovery` or `unload`.
  final String phase;

  /// Planned minutes per sport, from the stored sessions.
  final Map<String, int> minutesBySport;

  /// The time the athlete made available.
  final int budgetMin;

  /// The week's planned sessions, in order.
  final List<PlannedSession> sessions;

  /// What the planner gave up, as codes, and what it could not fit.
  final List<String> tradeoffs;
  final List<String> unmet;

  /// Goal name to what the week does for it (`build`, `taper`, ...).
  final Map<String, String> intents;

  /// Projected fitness, fatigue and form at the end of the week.
  final FormPoint? form;

  int get plannedMin => minutesBySport.values.fold(0, (a, b) => a + b);
  int get load => sessions.fold(0, (a, s) => a + s.load);

  /// The three sessions that carry the week: the longest and hardest.
  List<PlannedSession> get keySessions {
    final sorted = [...sessions]
      ..sort(
        (a, b) => (b.load + b.durationMin).compareTo(a.load + a.durationMin),
      );
    return sorted.take(3).toList()..sort((a, b) => a.date.compareTo(b.date));
  }
}

/// Everything the Season screen shows.
class SeasonView {
  const SeasonView({
    required this.outcome,
    required this.goals,
    required this.conflicts,
    required this.summary,
    required this.weeks,
    required this.absences,
    required this.fitnessNow,
    this.planStart,
    this.planEnd,
  });

  final FeasibilityOutcome outcome;
  final List<SeasonGoal> goals;
  final List<SeasonConflict> conflicts;

  /// The planner's sentences about the season's trade-offs.
  final List<String> summary;
  final List<SeasonWeek> weeks;

  /// Times away inside the season: kind, first and last day.
  final List<(String, DateTime, DateTime)> absences;
  final double fitnessNow;
  final DateTime? planStart;
  final DateTime? planEnd;

  bool get isEmpty => weeks.isEmpty;

  /// Projected fitness on the last week of the season.
  double? get fitnessAtEnd => weeks.isEmpty
      ? null
      : weeks
            .lastWhere((w) => w.form != null, orElse: () => weeks.last)
            .form
            ?.ctl;

  /// The week that contains [day], or null.
  SeasonWeek? weekOf(DateTime day) {
    final d = dayOf(day);
    for (final w in weeks) {
      if (!d.isBefore(w.start) &&
          d.isBefore(w.start.add(const Duration(days: 7)))) {
        return w;
      }
    }
    return null;
  }
}

/// The season of the active plan, as the phone's planner stored it, with
/// the stored sessions per week and the fitness they lead to.
Future<SeasonView> loadSeason(AppDatabase db, {DateTime? now}) async {
  final today = dayOf(now ?? DateTime.now());
  final plan =
      await (db.select(db.trainingPlans)
            ..where(
              (p) => p.athleteId.equals('self') & p.status.equals('active'),
            )
            ..orderBy([(p) => OrderingTerm.desc(p.generatedAt)])
            ..limit(1))
          .getSingleOrNull();
  final history = await readTrainingLoadHistory(db, now: today);
  final fitnessNow = history.points.isEmpty ? 0.0 : history.points.last.ctl;
  final report = SeasonReport.decode(plan?.seasonJson);
  if (plan == null || report == null) {
    return SeasonView(
      outcome: FeasibilityOutcome.insufficientData,
      goals: const [],
      conflicts: const [],
      summary: const [],
      weeks: const [],
      absences: const [],
      fitnessNow: fitnessNow,
    );
  }

  final sessions =
      await (db.select(db.trainingSessions)
            ..where(
              (s) =>
                  s.planId.equals(plan.id) &
                  s.status.isIn([...plannedSessionStates, 'skipped']),
            )
            ..orderBy([
              (s) => OrderingTerm(expression: s.sessionDate),
              (s) => OrderingTerm(expression: s.sessionNumber),
            ]))
          .get();
  final planned = [
    for (final s in sessions)
      PlannedSession(
        id: s.id,
        title: s.title,
        sport: s.sport,
        date: dayOf(s.sessionDate.toLocal()),
        durationMin: s.plannedDurationMin,
        zone: s.primaryZone,
        load: s.plannedTrimp,
        done: s.status == 'completed',
      ),
  ];

  // Fitness ahead: the planned load from tomorrow to the season's end.
  final ahead = <DateTime, double>{
    for (final p in planned)
      if (p.date.isAfter(today)) p.date: 0,
  };
  for (final p in planned) {
    if (p.date.isAfter(today)) ahead[p.date] = ahead[p.date]! + p.load;
  }
  final lastDay = planned.isEmpty ? today : planned.last.date;
  // Without any history the projection starts from nothing today.
  final projected = projectTrainingForm(
    history.points.isEmpty
        ? FormPoint(date: today, ctl: 0, atl: 0, load: 0)
        : history.points.last,
    planned: ahead,
    days: lastDay.difference(today).inDays.clamp(0, 400) + 7,
  );
  final form = {
    for (final p in history.points) dayOf(p.date): p,
    for (final p in projected) dayOf(p.date): p,
  };

  final goalsJson = (report['goals'] as Map?)?.cast<String, Object?>() ?? {};
  final goals =
      [
        for (final MapEntry(:key, :value) in goalsJson.entries)
          if (value is Map)
            SeasonGoal(
              id: key,
              name: '${value['name'] ?? key}',
              priority: '${value['priority'] ?? ''}',
              sport: '${value['sport'] ?? ''}',
              date: DateTime.tryParse('${value['date'] ?? ''}'),
            ),
      ]..sort(
        (a, b) =>
            (a.date ?? DateTime(9999)).compareTo(b.date ?? DateTime(9999)),
      );
  final goalNames = {for (final g in goals) g.id: g.name};

  final weeks = <SeasonWeek>[];
  for (final w in (report['weeks'] as List? ?? const [])) {
    if (w is! Map) continue;
    final start = DateTime.tryParse('${w['week']}');
    if (start == null) continue;
    final end = start.add(const Duration(days: 7));
    final inWeek = [
      for (final p in planned)
        if (!p.date.isBefore(start) && p.date.isBefore(end)) p,
    ];
    final bySport = <String, int>{};
    for (final p in inWeek) {
      bySport[p.sport] = (bySport[p.sport] ?? 0) + p.durationMin;
    }
    final allocation = (w['allocation'] as Map?) ?? const {};
    final intents = (w['intents'] as Map?) ?? const {};
    weeks.add(
      SeasonWeek(
        start: start,
        phase: '${w['phase'] ?? ''}',
        minutesBySport: bySport,
        budgetMin: (allocation['budgetMin'] as num?)?.round() ?? 0,
        sessions: inWeek,
        tradeoffs: [
          for (final t in (allocation['tradeoffs'] as List? ?? const [])) '$t',
        ],
        unmet: [
          for (final t in (allocation['unmet'] as List? ?? const [])) '$t',
        ],
        intents: {
          for (final MapEntry(:key, :value) in intents.entries)
            goalNames['$key'] ?? '$key': '$value',
        },
        form: form[dayOf(end.subtract(const Duration(days: 1)))],
      ),
    );
  }

  final seasonStart = weeks.isEmpty ? plan.startDate : weeks.first.start;
  final seasonEnd = weeks.isEmpty
      ? plan.endDate
      : weeks.last.start.add(const Duration(days: 6));
  final absences = [
    for (final a in await db.absencesBetween(seasonStart, seasonEnd))
      (a.kind, dayOf(a.startDay.toLocal()), dayOf(a.endDay.toLocal())),
  ];

  return SeasonView(
    outcome:
        FeasibilityOutcome.values.asNameMap()['${report['outcome']}'] ??
        FeasibilityOutcome.insufficientData,
    goals: goals,
    conflicts: [
      for (final c in (report['conflicts'] as List? ?? const []))
        if (c is Map)
          SeasonConflict(
            ConflictSeverity.values.asNameMap()['${c['severity']}'] ??
                ConflictSeverity.info,
            '${c['message'] ?? ''}',
            [for (final a in (c['alternatives'] as List? ?? const [])) '$a'],
          ),
    ],
    summary: [for (final s in (report['summary'] as List? ?? const [])) '$s'],
    weeks: weeks,
    absences: absences,
    fitnessNow: fitnessNow,
    planStart: plan.startDate.toLocal(),
    planEnd: plan.endDate.toLocal(),
  );
}
