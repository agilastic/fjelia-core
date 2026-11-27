import 'dart:isolate';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:fjelia_core/services/activity_kind.dart';
import 'package:fjelia_core/services/activity_metrics.dart';
import 'package:fjelia_core/services/sample_series.dart';
import 'package:fjelia_core/utils/days.dart';
import 'package:fjelia_core/utils/week.dart';
import 'package:fjelia_data/database.dart';

import 'activities.dart';
import 'analysis.dart' show bestOf, rideCurvesSince;
import 'today.dart' show plannedSessionStates;

export 'package:fjelia_core/services/activity_metrics.dart'
    show AerobicEfficiency, CriticalPower, DetectedInterval, fitCriticalPower;

// --- One activity ----------------------------------------------------------

/// What one activity shows a coach beyond its totals.
class ActivityInsights {
  const ActivityInsights({
    this.aerobic,
    this.intervals = const [],
    this.byPower = false,
    this.criticalPower,
    this.wPrimeBalance = const [],
    this.lowestWPrime,
  });

  final AerobicEfficiency? aerobic;

  /// The hard stretches, in order.
  final List<DetectedInterval> intervals;

  /// Whether [intervals] are in watts (else in metres per second).
  final bool byPower;

  /// The athlete's model from the 90 days before the activity.
  final CriticalPower? criticalPower;

  /// (seconds, kJ left), at most [maxPoints] points; empty without power
  /// or a model.
  final List<(double, double)> wPrimeBalance;

  /// The least W′ left, J: how deep the hardest part went.
  final double? lowestWPrime;

  static const maxPoints = 600;

  /// How much each interval fell short of the first, percent (positive is a
  /// fade).
  List<double> get fade => intervals.isEmpty
      ? const []
      : [
          for (final i in intervals)
            (intervals.first.mean - i.mean) / intervals.first.mean * 100,
        ];
}

Future<ActivityInsights> loadActivityInsights(AppDatabase db, String id) async {
  final row = await db.getActivityById(id);
  if (row == null) return const ActivityInsights();
  final start = row.startDate.toLocal();
  final model = activityKind(row.type) == ActivityKind.cycling
      ? fitCriticalPower(
          bestOf([
            for (final (rid, at, c) in await rideCurvesSince(
              db,
              start.subtract(const Duration(days: 90)),
            ))
              if (rid != id && at.isBefore(start)) c,
          ]),
        )
      : null;
  final json = row.metricsJson;
  return Isolate.run(() => _insights(json, model));
}

ActivityInsights _insights(String? json, CriticalPower? model) {
  final s = SampleSeries.fromMetrics(json);
  final byPower = s.hasPower;
  final values = byPower ? s.power : s.speed;
  List<(double, double)> balance = const [];
  double? lowest;
  if (byPower && model != null) {
    final bal = wPrimeBalance(s.power, model);
    lowest = bal.fold<double>(model.wPrime, math.min);
    final step = math.max(1, (bal.length / ActivityInsights.maxPoints).ceil());
    balance = [
      for (var i = 0; i < bal.length; i += step) (i.toDouble(), bal[i] / 1000),
    ];
  }
  return ActivityInsights(
    aerobic: aerobicEfficiency(s),
    intervals: detectIntervals(
      values,
      heartRate: s.heartRate,
      // With a model, hard means above CP.
      threshold: byPower && model != null ? model.cp : null,
    ),
    byPower: byPower,
    criticalPower: model,
    wPrimeBalance: balance,
    lowestWPrime: lowest,
  );
}

// --- Trends ---------------------------------------------------------------

enum TrendMetric {
  efficiencyFactor,
  decoupling,
  load,
  weeklyHours,
  weeklyDistance,
  weeklyLoad,
}

/// Which activities a trend counts.
class TrendFilter {
  const TrendFilter({this.sport, this.minMinutes = 0});

  /// An [ActivityKind], or null for all.
  final ActivityKind? sport;

  /// "Only long runs": at least this long.
  final int minMinutes;

  bool takes(ActivityItem a) =>
      (sport == null || activityKind(a.sport) == sport) &&
      a.duration.inMinutes >= minMinutes;
}

class TrendPoint {
  const TrendPoint(this.date, this.value, {this.activityId});
  final DateTime date;
  final double value;

  /// The activity it comes from, for a per-activity metric.
  final String? activityId;
}

bool isWeekly(TrendMetric m) => switch (m) {
  TrendMetric.weeklyHours ||
  TrendMetric.weeklyDistance ||
  TrendMetric.weeklyLoad => true,
  _ => false,
};

final _aerobicCache = <String, AerobicEfficiency?>{};

/// [metric] from [from] to [to] (both days included), oldest first: one
/// point per activity, or per week for the weekly ones (empty weeks count
/// as zero).
Future<List<TrendPoint>> loadTrend(
  AppDatabase db,
  TrendMetric metric, {
  required DateTime from,
  required DateTime to,
  TrendFilter filter = const TrendFilter(),
  bool mondayFirst = true,
}) async {
  final last = DateTime(to.year, to.month, to.day + 1);
  final items = [
    for (final a in (await readActivityItems(db, since: dayOf(from))).reversed)
      if (a.start.isBefore(last) && filter.takes(a)) a,
  ];
  switch (metric) {
    case TrendMetric.load:
      return [
        for (final a in items) TrendPoint(a.start, a.load, activityId: a.id),
      ];
    case TrendMetric.efficiencyFactor:
    case TrendMetric.decoupling:
      await _aerobicFor(db, [
        for (final a in items)
          if (a.duration.inMinutes >= 20) a.id,
      ]);
      return [
        for (final a in items)
          if (_aerobicCache[a.id] case final e?)
            TrendPoint(
              a.start,
              metric == TrendMetric.efficiencyFactor
                  ? e.efficiencyFactor
                  : e.decouplingPercent,
              activityId: a.id,
            ),
      ];
    case TrendMetric.weeklyHours:
    case TrendMetric.weeklyDistance:
    case TrendMetric.weeklyLoad:
      final weeks = <DateTime, double>{};
      for (
        var w = weekStartOf(from, mondayFirst: mondayFirst);
        !w.isAfter(to);
        w = DateTime(w.year, w.month, w.day + 7)
      ) {
        weeks[w] = 0;
      }
      for (final a in items) {
        final w = weekStartOf(a.start, mondayFirst: mondayFirst);
        weeks[w] =
            (weeks[w] ?? 0) +
            switch (metric) {
              TrendMetric.weeklyHours => a.duration.inSeconds / 3600,
              TrendMetric.weeklyDistance => (a.distanceMeters ?? 0) / 1000,
              _ => a.load,
            };
      }
      return [for (final e in weeks.entries) TrendPoint(e.key, e.value)];
  }
}

Future<void> _aerobicFor(AppDatabase db, List<String> ids) async {
  final a = db.activityRecords;
  final todo = [
    for (final id in ids)
      if (!_aerobicCache.containsKey(id)) id,
  ];
  for (var i = 0; i < todo.length; i += 20) {
    final part = todo.sublist(i, math.min(todo.length, i + 20));
    final batch = [
      for (final r
          in await (db.selectOnly(a)
                ..addColumns([a.activityId, a.metricsJson])
                ..where(a.activityId.isIn(part)))
              .get())
        (r.read(a.activityId)!, r.read(a.metricsJson)),
    ];
    for (final (id, e) in await Isolate.run(
      () => [
        for (final (id, json) in batch)
          (id, aerobicEfficiency(SampleSeries.fromMetrics(json))),
      ],
    )) {
      _aerobicCache[id] = e;
    }
  }
}

// --- Planned against done, the whole roster ---------------------------------

/// One athlete's week: what the plan asked and what was done.
class RosterWeek {
  const RosterWeek({
    required this.start,
    required this.plannedLoad,
    required this.doneLoad,
    required this.plannedMinutes,
    required this.doneMinutes,
    required this.plannedSessions,
    required this.completedSessions,
  });

  final DateTime start;
  final double plannedLoad, doneLoad;
  final int plannedMinutes, doneMinutes;
  final int plannedSessions, completedSessions;

  /// Done against planned load, percent; null without a plan.
  double? get compliance =>
      plannedLoad <= 0 ? null : doneLoad / plannedLoad * 100;
}

/// The last [weeks] weeks (this one last) for one athlete's database.
Future<List<RosterWeek>> loadPlannedVsDone(
  AppDatabase db, {
  int weeks = 8,
  bool mondayFirst = true,
  DateTime? now,
}) async {
  final today = dayOf(now ?? DateTime.now());
  final thisWeek = weekStartOf(today, mondayFirst: mondayFirst);
  final first = DateTime(
    thisWeek.year,
    thisWeek.month,
    thisWeek.day - 7 * (weeks - 1),
  );
  final end = DateTime(thisWeek.year, thisWeek.month, thisWeek.day + 7);
  final s = db.trainingSessions;
  final sessions =
      await (db.select(s)..where(
            (t) =>
                t.athleteId.equals('self') &
                t.sessionDate.isBiggerOrEqualValue(first) &
                t.sessionDate.isSmallerThanValue(end) &
                t.status.isIn([...plannedSessionStates, 'missed', 'skipped']),
          ))
          .get();
  final done = await readActivityItems(db, since: first);
  return [
    for (var w = 0; w < weeks; w++)
      () {
        final start = DateTime(first.year, first.month, first.day + 7 * w);
        final stop = DateTime(start.year, start.month, start.day + 7);
        bool inWeek(DateTime d) => !d.isBefore(start) && d.isBefore(stop);
        final planned = [
          for (final x in sessions)
            if (inWeek(x.sessionDate.toLocal())) x,
        ];
        final did = [
          for (final a in done)
            if (inWeek(a.start)) a,
        ];
        return RosterWeek(
          start: start,
          plannedLoad: planned.fold(0.0, (n, x) => n + x.plannedTrimp),
          doneLoad: did.fold(0.0, (n, a) => n + a.load),
          plannedMinutes: planned.fold(0, (n, x) => n + x.plannedDurationMin),
          doneMinutes: did.fold(0, (n, a) => n + a.duration.inMinutes),
          plannedSessions: planned.length,
          completedSessions: planned
              .where((x) => x.status == 'completed')
              .length,
        );
      }(),
  ];
}

// --- Periods, for comparing -------------------------------------------------

/// What one period held: to set two periods, or two athletes, side by side.
class PeriodSummary {
  const PeriodSummary({
    required this.from,
    required this.to,
    required this.activities,
    required this.hours,
    required this.distanceKm,
    required this.load,
    required this.bySport,
    this.efficiencyFactor,
    this.decoupling,
    this.bestPower = const {},
  });

  final DateTime from, to;
  final int activities;
  final double hours, distanceKm, load;

  /// Hours by [ActivityKind].
  final Map<ActivityKind, double> bySport;

  /// Means over the steady activities that had them.
  final double? efficiencyFactor, decoupling;

  /// Best power by seconds in the period.
  final Map<int, double> bestPower;
}

Future<PeriodSummary> loadPeriodSummary(
  AppDatabase db, {
  required DateTime from,
  required DateTime to,
}) async {
  final last = DateTime(to.year, to.month, to.day + 1);
  final items = [
    for (final a in await readActivityItems(db, since: dayOf(from)))
      if (a.start.isBefore(last)) a,
  ];
  await _aerobicFor(db, [
    for (final a in items)
      if (a.duration.inMinutes >= 20) a.id,
  ]);
  final aerobic = [for (final a in items) ?_aerobicCache[a.id]];
  double? mean(Iterable<double> xs) =>
      xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
  final bySport = <ActivityKind, double>{};
  for (final a in items) {
    final k = activityKind(a.sport);
    bySport[k] = (bySport[k] ?? 0) + a.duration.inSeconds / 3600;
  }
  return PeriodSummary(
    from: dayOf(from),
    to: dayOf(to),
    activities: items.length,
    hours: items.fold(0.0, (n, a) => n + a.duration.inSeconds / 3600),
    distanceKm: items.fold(0.0, (n, a) => n + (a.distanceMeters ?? 0) / 1000),
    load: items.fold(0.0, (n, a) => n + a.load),
    bySport: bySport,
    efficiencyFactor: mean([
      for (final e in aerobic)
        if (e.byPower) e.efficiencyFactor,
    ]),
    decoupling: mean(aerobic.map((e) => e.decouplingPercent)),
    bestPower: bestOf([
      for (final (_, at, c) in await rideCurvesSince(db, dayOf(from)))
        if (at.isBefore(last)) c,
    ]),
  );
}
