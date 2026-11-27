import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:fjelia_core/services/activity_kind.dart';
import 'package:fjelia_core/services/best_efforts.dart';
import 'package:fjelia_core/services/training_form.dart';
import 'package:fjelia_core/utils/week.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_core/utils/days.dart';

import 'sport_stats.dart';
import 'today.dart' show plannedSessionStates;
import 'training_load.dart';

/// How far back Analysis looks. [all] starts at the first day with training
/// load; a period of the athlete's own choosing is given to [loadAnalysis]
/// as from and to instead.
enum AnalysisRange {
  sixWeeks(42),
  threeMonths(91),
  sixMonths(182),
  year(365),
  twoYears(730),
  fiveYears(1826),
  all(0);

  const AnalysisRange(this.days);
  final int days;
}

/// The best average power per duration, this year and last.
class PowerCurve {
  const PowerCurve({required this.thisYear, required this.lastYear});

  /// Watts by duration in seconds ([powerCurveDurations]).
  final Map<int, double> thisYear;
  final Map<int, double> lastYear;

  bool get isEmpty => thisYear.isEmpty && lastYear.isEmpty;
}

/// Time in heart-rate zones 1–5 in one week.
class ZoneWeek {
  const ZoneWeek(this.start, this.seconds);
  final DateTime start;
  final List<double> seconds;

  double get total => seconds.fold(0, (a, b) => a + b);

  /// Share of zones 1 and 2, 0–1; null without heart rate.
  double? get easyShare =>
      total == 0 ? null : (seconds[0] + seconds[1]) / total;
}

/// A threshold as measured or estimated on a day.
class ThresholdPoint {
  const ThresholdPoint({
    required this.date,
    required this.source,
    this.lt1Bpm,
    this.lt2Bpm,
    this.lt2PaceSec,
    this.ftpWatts,
  });
  final DateTime date;
  final String source;
  final int? lt1Bpm;
  final int? lt2Bpm;

  /// Seconds per km.
  final int? lt2PaceSec;
  final int? ftpWatts;
}

/// Everything the Analysis screen shows.
class AnalysisView {
  const AnalysisView({
    required this.range,
    required this.today,
    required this.from,
    required this.to,
    this.custom = false,
    required this.form,
    required this.forecast,
    required this.load,
    required this.powerCurve,
    required this.zoneWeeks,
    required this.records,
    required this.thresholds,
  });

  final AnalysisRange range;
  final DateTime today;

  /// The days shown, both included. [to] is [today] unless a past period was
  /// chosen; only then is there no forecast.
  final DateTime from, to;

  /// A period the athlete chose rather than one of the [AnalysisRange]s.
  final bool custom;

  /// Fitness, fatigue and form over [range], through today; each point's
  /// load is the day's.
  final List<FormPoint> form;

  /// The next [forecastDays] with the planned sessions and rest otherwise.
  final List<FormPoint> forecast;
  final TrainingLoadSummary load;
  final PowerCurve powerCurve;

  /// The last [zoneWeeksShown] weeks, oldest first.
  final List<ZoneWeek> zoneWeeks;

  /// Totals, best efforts and longest activities, for running and riding.
  final Map<StatsSport, SportStats> records;

  /// Oldest first.
  final List<ThresholdPoint> thresholds;

  static const forecastDays = 45;
  static const zoneWeeksShown = 12;

  bool get isEmpty =>
      !load.hasHistory && records.values.every((s) => s.allTime.count == 0);

  /// Share of easy time over [zoneWeeks], 0–1; null without heart rate.
  double? get easyShare {
    final total = zoneWeeks.fold(0.0, (s, w) => s + w.total);
    if (total == 0) return null;
    return zoneWeeks.fold(0.0, (s, w) => s + w.seconds[0] + w.seconds[1]) /
        total;
  }
}

/// Analysis over [range], or over the athlete's own period from [from] to
/// [to] (both days included; [to] at most today). Fitness, fatigue and form
/// are always worked out from the whole history, so any period shows them
/// right from its first day.
Future<AnalysisView> loadAnalysis(
  AppDatabase db, {
  AnalysisRange range = AnalysisRange.sixMonths,
  DateTime? from,
  DateTime? to,
  bool mondayFirst = true,
  DateTime? now,
}) async {
  final today = dayOf(now ?? DateTime.now());
  final history = await readTrainingLoadHistory(db, now: today);
  final custom = from != null;
  final last = to == null || dayOf(to).isAfter(today) ? today : dayOf(to);
  final first = custom
      ? dayOf(from)
      : range == AnalysisRange.all
      ? (history.points.isEmpty ? today : dayOf(history.points.first.date))
      : DateTime(today.year, today.month, today.day - range.days + 1);
  final form = [
    for (final p in history.points)
      if (!p.date.isBefore(first) && !p.date.isAfter(last)) p,
  ];

  // The plan ahead, for the forecast.
  final s = db.trainingSessions;
  final until = DateTime(
    today.year,
    today.month,
    today.day + AnalysisView.forecastDays + 1,
  );
  final planned = <DateTime, double>{};
  for (final x
      in await (db.select(s)..where(
            (t) =>
                t.athleteId.equals('self') &
                t.sessionDate.isBiggerThanValue(today) &
                t.sessionDate.isSmallerThanValue(until) &
                t.status.isIn(plannedSessionStates),
          ))
          .get()) {
    final d = dayOf(x.sessionDate.toLocal());
    planned[d] = (planned[d] ?? 0) + x.plannedTrimp;
  }
  // Only a period that ends today goes on into the plan ahead.
  final forecast = history.points.isEmpty || last != today
      ? const <FormPoint>[]
      : projectTrainingForm(
          history.points.last,
          planned: planned,
          days: AnalysisView.forecastDays,
        );

  return AnalysisView(
    range: range,
    today: today,
    from: first,
    to: last,
    custom: custom,
    form: form,
    forecast: forecast,
    load: TrainingLoadSummary.of(history),
    powerCurve: await _powerCurve(db, today),
    zoneWeeks: await _zoneWeeks(db, today, mondayFirst),
    records: await loadSportStats(db, today),
    thresholds: [
      for (final r in await (db.select(
        db.thresholdRecords,
      )..orderBy([(t) => OrderingTerm(expression: t.date)])).get())
        ThresholdPoint(
          date: dayOf(r.date.toLocal()),
          source: r.source,
          lt1Bpm: r.lt1Bpm,
          lt2Bpm: r.lt2Bpm,
          lt2PaceSec: r.lt2PaceSec,
          ftpWatts: r.ftpWatts,
        ),
    ],
  );
}

/// Power curves worked out, by activity id; a stored activity does not
/// change, so each is read once per run.
final _curveCache = <String, Map<int, double>>{};

/// Each ride since [from] with its power curve (watts by seconds), worked
/// out once per activity in a background isolate.
Future<List<(String, DateTime, Map<int, double>)>> rideCurvesSince(
  AppDatabase db,
  DateTime from,
) async {
  final a = db.activityRecords;
  final rides = [
    for (final r
        in await (db.selectOnly(a)
              ..addColumns([a.activityId, a.type, a.startDate])
              ..where(
                a.avgWatts.isBiggerThanValue(0) &
                    a.startDate.isBiggerOrEqualValue(from),
              ))
            .get())
      if (activityKind(r.read(a.type)!) == ActivityKind.cycling)
        (r.read(a.activityId)!, r.read(a.startDate)!.toLocal()),
  ];
  final todo = [
    for (final (id, _) in rides)
      if (!_curveCache.containsKey(id)) id,
  ];
  for (var i = 0; i < todo.length; i += 20) {
    final ids = todo.sublist(i, math.min(todo.length, i + 20));
    final batch = [
      for (final r
          in await (db.selectOnly(a)
                ..addColumns([a.activityId, a.metricsJson])
                ..where(a.activityId.isIn(ids)))
              .get())
        (r.read(a.activityId)!, r.read(a.metricsJson) ?? ''),
    ];
    for (final (id, curve) in await Isolate.run(
      () => [for (final (id, json) in batch) (id, meanMaxPower(json))],
    )) {
      _curveCache[id] = curve;
    }
  }
  return [for (final (id, start) in rides) (id, start, _curveCache[id] ?? {})];
}

/// The best of [curves] at each duration.
Map<int, double> bestOf(Iterable<Map<int, double>> curves) {
  final best = <int, double>{};
  for (final curve in curves) {
    for (final MapEntry(key: d, value: w) in curve.entries) {
      if (w > (best[d] ?? 0)) best[d] = w;
    }
  }
  return best;
}

Future<PowerCurve> _powerCurve(AppDatabase db, DateTime today) async {
  final rides = await rideCurvesSince(db, DateTime(today.year - 1));
  return PowerCurve(
    thisYear: bestOf([
      for (final (_, start, c) in rides)
        if (start.year == today.year) c,
    ]),
    lastYear: bestOf([
      for (final (_, start, c) in rides)
        if (start.year != today.year) c,
    ]),
  );
}

Future<List<ZoneWeek>> _zoneWeeks(
  AppDatabase db,
  DateTime today,
  bool mondayFirst,
) async {
  final thisWeek = weekStartOf(today, mondayFirst: mondayFirst);
  final first = DateTime(
    thisWeek.year,
    thisWeek.month,
    thisWeek.day - 7 * (AnalysisView.zoneWeeksShown - 1),
  );
  final weeks = {
    for (var i = 0; i < AnalysisView.zoneWeeksShown; i++)
      DateTime(first.year, first.month, first.day + 7 * i): List<double>.filled(
        5,
        0,
      ),
  };
  final z = db.hrZoneSummaries;
  for (final r
      in await (db.select(z)..where(
            (t) => t.startDate.isBiggerOrEqualValue(first) & t.duplicate.not(),
          ))
          .get()) {
    final week = weekStartOf(r.startDate.toLocal(), mondayFirst: mondayFirst);
    final into = weeks[week];
    if (into == null) continue;
    try {
      final secs = (jsonDecode(r.zoneSecondsJson) as List).cast<num>();
      for (var i = 0; i < 5 && i < secs.length; i++) {
        into[i] += secs[i].toDouble();
      }
    } on Object {
      // A summary that does not read is left out.
    }
  }
  return [for (final e in weeks.entries) ZoneWeek(e.key, e.value)];
}
