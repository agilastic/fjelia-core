import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fjelia_core/models/garmin_data.dart';
import 'package:fjelia_core/services/activity_decoder.dart';
import 'package:fjelia_core/services/activity_kind.dart';
import 'package:fjelia_core/services/training_load.dart';
import 'package:fjelia_data/database.dart';

/// The sport filter above an activity list.
enum SportFilter {
  all,
  run,
  ride,
  swim,
  strength;

  bool matches(ActivityKind kind) => switch (this) {
    all => true,
    run => kind == ActivityKind.running,
    ride => kind == ActivityKind.cycling,
    swim => kind == ActivityKind.swimming,
    strength => kind == ActivityKind.strength,
  };
}

/// One row of an activity list.
class ActivityItem {
  const ActivityItem({
    required this.id,
    required this.name,
    required this.sport,
    required this.start,
    required this.duration,
    required this.load,
    this.distanceMeters,
    this.avgHeartRate,
    this.source,
  });

  final String id;
  final String name;

  /// The sport key as recorded, e.g. `running` or `virtual_ride`.
  final String sport;
  final DateTime start;
  final Duration duration;
  final double? distanceMeters;
  final double? avgHeartRate;

  /// Training load as Fjelia counts it (recorded, or estimated).
  final double load;
  final String? source;

  ActivityKind get kind => activityKind(sport);
}

/// The activities of one month, newest first.
class ActivityMonth {
  const ActivityMonth(this.month, this.items);

  /// The first day of the month.
  final DateTime month;
  final List<ActivityItem> items;

  Duration get duration =>
      items.fold(Duration.zero, (sum, a) => sum + a.duration);
  double get distanceMeters =>
      items.fold(0, (sum, a) => sum + (a.distanceMeters ?? 0));
}

class ActivityListView {
  const ActivityListView({required this.total, required this.months});

  /// All activities, whatever the filter.
  final int total;

  /// Those the filter keeps, by month, newest first.
  final List<ActivityMonth> months;

  bool get isEmpty => months.isEmpty;
}

/// Activities, newest first, without routes and samples.
Future<List<ActivityItem>> readActivityItems(
  AppDatabase db, {
  int? limit,
  DateTime? since,
}) async {
  final t = db.activityRecords;
  final query = db.selectOnly(t)
    ..addColumns([
      t.activityId,
      t.name,
      t.type,
      t.startDate,
      t.durationSeconds,
      t.distanceMeters,
      t.avgHeartRate,
      t.trainingLoad,
      t.totalElevation,
      t.hrZonesJson,
      t.source,
    ])
    ..orderBy([OrderingTerm.desc(t.startDate)]);
  if (since != null) query.where(t.startDate.isBiggerOrEqualValue(since));
  if (limit != null) query.limit(limit);
  return [
    for (final r in await query.get())
      ActivityItem(
        id: r.read(t.activityId)!,
        name: r.read(t.name)!,
        sport: r.read(t.type)!,
        start: r.read(t.startDate)!.toLocal(),
        duration: Duration(seconds: r.read(t.durationSeconds)!),
        distanceMeters: r.read(t.distanceMeters),
        avgHeartRate: r.read(t.avgHeartRate),
        source: r.read(t.source),
        load: effectiveLoadFromSummary(
          durationSeconds: r.read(t.durationSeconds)!,
          recordedLoad: r.read(t.trainingLoad),
          elevationMeters: r.read(t.totalElevation),
          hrZonesJson: r.read(t.hrZonesJson),
          averageHeartRate: r.read(t.avgHeartRate),
        ),
      ),
  ];
}

Future<ActivityListView> loadActivityList(
  AppDatabase db, {
  SportFilter filter = SportFilter.all,
}) async {
  final all = await readActivityItems(db);
  final months = <DateTime, List<ActivityItem>>{};
  for (final a in all) {
    if (!filter.matches(a.kind)) continue;
    (months[DateTime(a.start.year, a.start.month)] ??= []).add(a);
  }
  return ActivityListView(
    total: all.length,
    months: [for (final e in months.entries) ActivityMonth(e.key, e.value)],
  );
}

/// A value on an activity's summary.
enum ActivityStat {
  distance,
  duration,
  movingTime,
  pace,
  speed,
  avgPower,
  avgHeartRate,
  maxHeartRate,
  elevationGain,
  cadence,
  load,
  calories,
}

/// A measured value over an activity's time.
enum ActivitySeries { heartRate, pace, speed, elevation, power, cadence }

/// What an activity's page shows.
class ActivityDetail {
  const ActivityDetail({
    required this.item,
    required this.activity,
    required this.stats,
    required this.zoneSeconds,
    required this.series,
    this.note,
    this.description,
  });

  final ActivityItem item;

  /// The decoded activity: route, samples, planned steps.
  final GarminActivity activity;

  /// The summary values that apply to this sport, in display order. Pace
  /// is seconds per kilometre (per 100 m for swimming), speed metres per
  /// second.
  final List<(ActivityStat, double)> stats;

  /// Seconds in heart-rate zones 1 to 5, empty without heart rate.
  final List<double> zoneSeconds;

  /// The graphs that apply to this sport and that the file has, as elapsed
  /// seconds and value: pace in seconds per km (per 100 m for swimming),
  /// speed in m/s. At most [maxSeriesPoints] points each.
  final Map<ActivitySeries, List<(double, double)>> series;

  static const maxSeriesPoints = 600;
  final String? note;
  final String? description;

  bool get hasRoute => activity.route.length > 1;
  bool get hasSamples => activity.samples.length > 1;
}

Future<ActivityDetail?> loadActivityDetail(AppDatabase db, String id) async {
  final row = await db.getActivityById(id);
  if (row == null) return null;
  final activity = decodeActivityRecord(row);
  final item = ActivityItem(
    id: row.activityId,
    name: row.name,
    sport: row.type,
    start: row.startDate.toLocal(),
    duration: Duration(seconds: row.durationSeconds),
    distanceMeters: row.distanceMeters,
    avgHeartRate: row.avgHeartRate,
    source: row.source,
    load: effectiveLoad(row),
  );
  final summary = await (db.select(
    db.hrZoneSummaries,
  )..where((z) => z.activityId.equals(id))).getSingleOrNull();
  return ActivityDetail(
    item: item,
    activity: activity,
    stats: activityStats(item.kind, row),
    zoneSeconds: _zones(summary?.zoneSecondsJson, activity.hrZoneSeconds),
    series: activitySeries(item.kind, activity.samples, item.start),
    note: row.athleteNote,
    description: row.description,
  );
}

/// The summary of [row] for its sport [kind].
List<(ActivityStat, double)> activityStats(
  ActivityKind kind,
  ActivityRecord row,
) {
  final seconds = row.durationSeconds.toDouble();
  final meters = row.distanceMeters;
  final moving = row.movingDurationSeconds?.toDouble();
  final pacedOver = moving ?? seconds;
  final paced = switch (kind) {
    ActivityKind.running || ActivityKind.walking || ActivityKind.hiking => 1000,
    ActivityKind.swimming => 100,
    _ => null,
  };
  return [
    if (meters != null && meters > 0) (ActivityStat.distance, meters),
    (ActivityStat.duration, seconds),
    if (moving != null && moving < seconds - 30)
      (ActivityStat.movingTime, moving),
    if (meters != null && meters > 0 && paced != null)
      (ActivityStat.pace, pacedOver / meters * paced),
    if (meters != null && meters > 0 && kind == ActivityKind.cycling)
      (ActivityStat.speed, meters / pacedOver),
    if (row.avgWatts case final w? when w > 0) (ActivityStat.avgPower, w),
    if (row.avgHeartRate case final hr? when hr > 0)
      (ActivityStat.avgHeartRate, hr),
    if (row.maxHeartRate case final hr? when hr > 0)
      (ActivityStat.maxHeartRate, hr),
    if (row.totalElevation case final e? when e > 0)
      (ActivityStat.elevationGain, e),
    if (row.avgRunCadence case final c? when c > 0) (ActivityStat.cadence, c),
    (ActivityStat.load, effectiveLoad(row)),
    if (row.calories case final c? when c > 0) (ActivityStat.calories, c),
  ];
}

List<double> _zones(String? summaryJson, Map<String, double> fromFile) {
  if (summaryJson != null) {
    try {
      final list = (jsonDecode(summaryJson) as List).cast<num>();
      if (list.length >= 5 && list.any((s) => s > 0)) {
        return [for (final s in list.take(5)) s.toDouble()];
      }
    } on Object {
      // The activity's own zones below.
    }
  }
  final zones = [for (var z = 1; z <= 5; z++) fromFile['zone$z'] ?? 0.0];
  return zones.any((s) => s > 0) ? zones : const [];
}

/// The graphs of [samples] for an activity of [kind] that started at
/// [start].
Map<ActivitySeries, List<(double, double)>> activitySeries(
  ActivityKind kind,
  List<ActivitySample> samples,
  DateTime start,
) {
  final timed = [
    for (final s in samples)
      if (s.timestamp != null) s,
  ];
  if (timed.length < 2) return const {};
  final step = (timed.length / ActivityDetail.maxSeriesPoints).ceil();
  final paced = switch (kind) {
    ActivityKind.running || ActivityKind.walking || ActivityKind.hiking => 1000,
    ActivityKind.swimming => 100,
    _ => null,
  };
  final origin = timed.first.timestamp!;
  final series = <ActivitySeries, List<(double, double)>>{};
  void add(ActivitySeries key, double x, double? v) {
    if (v == null || !v.isFinite) return;
    (series[key] ??= []).add((x, v));
  }

  for (var i = 0; i < timed.length; i += step) {
    final s = timed[i];
    final x = s.timestamp!.difference(origin).inMilliseconds / 1000;
    add(ActivitySeries.heartRate, x, s.heartRate);
    final speed = s.speed;
    if (speed != null && speed > 0.3) {
      if (paced != null) {
        add(ActivitySeries.pace, x, paced / speed);
      } else if (kind == ActivityKind.cycling) {
        add(ActivitySeries.speed, x, speed);
      }
    }
    add(ActivitySeries.elevation, x, s.elevation);
    if (s.power case final w? when w > 0) add(ActivitySeries.power, x, w);
    if (s.cadence case final c? when c > 0) add(ActivitySeries.cadence, x, c);
  }
  series.removeWhere((_, points) => points.length < 2);
  return {
    for (final key in ActivitySeries.values)
      if (series[key] case final points?) key: points,
  };
}
