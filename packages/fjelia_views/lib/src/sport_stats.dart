import 'dart:isolate';
import 'dart:math' as math;

import 'package:fjelia_core/services/activity_kind.dart';
import 'package:fjelia_core/services/best_efforts.dart';
import 'package:fjelia_data/database.dart';

/// The two sports with records: running and riding.
enum StatsSport { run, ride }

/// One best effort: the fastest stretch of [meters] inside any activity,
/// all time and this year, each with its day.
class BestEffort {
  const BestEffort(
    this.label,
    this.meters, {
    this.allTime,
    this.allTimeDate,
    this.year,
    this.yearDate,
  });
  final String label;
  final double meters;
  final double? allTime, year;
  final DateTime? allTimeDate, yearDate;
}

/// Totals over a span: activities, distance, moving time, elevation.
class StatsTotals {
  const StatsTotals(this.count, this.meters, this.seconds, this.elevation);

  /// A whole number for a span, an average (one decimal) per week.
  final double count;
  final double meters, seconds, elevation;
}

/// A sport's numbers, like a training log's overview: the last four weeks
/// per week, this year, all time, and the best efforts.
class SportStats {
  const SportStats({
    required this.sport,
    required this.last4PerWeek,
    required this.year,
    required this.allTime,
    required this.efforts,
    this.longest,
    this.longestDate,
    this.mostElevation,
    this.mostElevationDate,
  });
  final StatsSport sport;

  /// The last 28 days divided by four.
  final StatsTotals last4PerWeek;
  final StatsTotals year, allTime;
  final List<BestEffort> efforts;

  /// The longest single activity (metres) and the most climbing in one.
  final double? longest, mostElevation;
  final DateTime? longestDate, mostElevationDate;
}

StatsSport? statsSportOf(String type) => switch (activityKind(type)) {
  ActivityKind.running => StatsSport.run,
  ActivityKind.cycling => StatsSport.ride,
  _ => null,
};

/// Best efforts already worked out, by activity id: a stored activity does
/// not change, so each is read once per app run.
final _effortCache = <String, Map<double, double>>{};

/// Works out the numbers for both sports from the stored activities.
Future<Map<StatsSport, SportStats>> loadSportStats(
  AppDatabase db,
  DateTime now,
) async {
  final a = db.activityRecords;
  final rows =
      await (db.selectOnly(a)..addColumns([
            a.activityId,
            a.type,
            a.startDate,
            a.durationSeconds,
            a.distanceMeters,
            a.totalElevation,
          ]))
          .get();
  final yearStart = DateTime(now.year);
  final last4 = DateTime(now.year, now.month, now.day - 27);
  final out = <StatsSport, SportStats>{};
  for (final sport in StatsSport.values) {
    final mine = [
      for (final r in rows)
        if (statsSportOf(r.read(a.type)!) == sport) r,
    ];
    StatsTotals totals(bool Function(DateTime) inSpan, [double divide = 1]) {
      var count = 0;
      var meters = 0.0, seconds = 0.0, elevation = 0.0;
      for (final r in mine) {
        if (!inSpan(r.read(a.startDate)!)) continue;
        count++;
        meters += r.read(a.distanceMeters) ?? 0;
        seconds += r.read(a.durationSeconds)!.toDouble();
        elevation += r.read(a.totalElevation) ?? 0;
      }
      return StatsTotals(
        count / divide,
        meters / divide,
        seconds / divide,
        elevation / divide,
      );
    }

    double? longest, mostElevation;
    DateTime? longestDate, mostElevationDate;
    for (final r in mine) {
      final d = r.read(a.distanceMeters) ?? 0;
      final e = r.read(a.totalElevation) ?? 0;
      if (d > (longest ?? 0)) {
        longest = d;
        longestDate = r.read(a.startDate);
      }
      if (e > (mostElevation ?? 0)) {
        mostElevation = e;
        mostElevationDate = r.read(a.startDate);
      }
    }

    // Best efforts from the samples of every activity long enough for the
    // shortest distance; worked out off the main isolate in batches.
    final distances = sport == StatsSport.run
        ? runEffortDistances
        : rideEffortDistances;
    final targets = [for (final d in distances) d.$2];
    final todo = [
      for (final r in mine)
        if ((r.read(a.distanceMeters) ?? 0) >= targets.first &&
            !_effortCache.containsKey(r.read(a.activityId)))
          r.read(a.activityId)!,
    ];
    for (var i = 0; i < todo.length; i += 20) {
      final ids = todo.sublist(i, math.min(todo.length, i + 20));
      final samples =
          await (db.selectOnly(a)
                ..addColumns([a.activityId, a.metricsJson])
                ..where(a.activityId.isIn(ids)))
              .get();
      final batch = [
        for (final s in samples)
          (s.read(a.activityId)!, s.read(a.metricsJson) ?? ''),
      ];
      final results = await _effortsApart(batch, targets);
      for (final (id, efforts) in results) {
        _effortCache[id] = efforts;
      }
    }
    final dates = {
      for (final r in mine) r.read(a.activityId)!: r.read(a.startDate)!,
    };
    final efforts = [
      for (final (label, meters) in distances)
        () {
          double? all, year;
          DateTime? allDate, yearDate;
          for (final id in dates.keys) {
            final t = _effortCache[id]?[meters];
            if (t == null) continue;
            final date = dates[id]!;
            if (all == null || t < all) {
              all = t;
              allDate = date;
            }
            if (!date.isBefore(yearStart) && (year == null || t < year)) {
              year = t;
              yearDate = date;
            }
          }
          return BestEffort(
            label,
            meters,
            allTime: all,
            allTimeDate: allDate,
            year: year,
            yearDate: yearDate,
          );
        }(),
    ];
    out[sport] = SportStats(
      sport: sport,
      last4PerWeek: totals((d) => !d.isBefore(last4), 4),
      year: totals((d) => !d.isBefore(yearStart)),
      allTime: totals((_) => true),
      efforts: efforts,
      longest: longest,
      longestDate: longestDate,
      mostElevation: mostElevation,
      mostElevationDate: mostElevationDate,
    );
  }
  return out;
}

/// [bestEfforts] for a batch of activities on another isolate. Its own
/// function, so the closure carries only the samples, not the database.
Future<List<(String, Map<double, double>)>> _effortsApart(
  List<(String, String)> batch,
  List<double> targets,
) => Isolate.run(
  () => [for (final (id, json) in batch) (id, bestEfforts(json, targets))],
);
