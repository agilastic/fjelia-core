import 'package:drift/drift.dart';
import 'package:fjelia_core/services/training_form.dart';
import 'package:fjelia_core/services/training_load.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_core/utils/days.dart';

/// Every day's load and the fitness, fatigue and form it adds up to.
class TrainingLoadHistory {
  const TrainingLoadHistory(this.daily, this.points);

  /// Load per local day.
  final Map<DateTime, double> daily;

  /// Fitness (CTL), fatigue (ATL) and form (TSB) per day through today.
  final List<FormPoint> points;
}

/// The load history for charts and summaries. Days with activities use
/// them; days known only from the daily score cache keep that load.
Future<TrainingLoadHistory> readTrainingLoadHistory(
  AppDatabase db, {
  DateTime? now,
}) async {
  final today = dayOf(now ?? DateTime.now());
  final daily = <DateTime, double>{};
  for (final score in await db.getAllScores()) {
    // Scores use UTC calendar keys, rather than activity timestamps.
    final d = dayOf(score.date.toUtc());
    final load = score.strainScore;
    if (d.isAfter(today) || load == null || !load.isFinite || load < 0) {
      continue;
    }
    daily[d] = load.clamp(0.0, 2000.0);
  }
  // Only the load inputs: routes and sample arrays can be large.
  final t = db.activityRecords;
  final activities =
      await (db.selectOnly(t)
            ..addColumns([
              t.startDate,
              t.durationSeconds,
              t.trainingLoad,
              t.totalElevation,
              t.hrZonesJson,
              t.avgHeartRate,
            ])
            ..where(
              t.startDate.isSmallerThanValue(
                DateTime(today.year, today.month, today.day + 1),
              ),
            ))
          .get();
  final activityDaily = <DateTime, double>{};
  for (final activity in activities) {
    final d = dayOf(activity.read(t.startDate)!.toLocal());
    final load = effectiveLoadFromSummary(
      durationSeconds: activity.read(t.durationSeconds)!,
      recordedLoad: activity.read(t.trainingLoad),
      elevationMeters: activity.read(t.totalElevation),
      hrZonesJson: activity.read(t.hrZonesJson),
      averageHeartRate: activity.read(t.avgHeartRate),
    );
    if (!load.isFinite || load < 0) continue;
    activityDaily[d] = (activityDaily[d] ?? 0) + load;
  }
  daily.addAll(activityDaily);
  return TrainingLoadHistory(
    daily,
    buildTrainingFormSeries(dailyLoads: daily, through: today),
  );
}

/// Today's fitness, fatigue and form, and the band of daily load that
/// builds fitness without overreaching.
class TrainingLoadSummary {
  const TrainingLoadSummary({
    required this.ctl,
    required this.atl,
    required this.optimalLow,
    required this.optimalHigh,
    required this.peak,
  });

  factory TrainingLoadSummary.of(TrainingLoadHistory history) {
    final latest = history.points.isEmpty ? null : history.points.last;
    if (latest == null) return empty;
    final ctl = latest.ctl, atl = latest.atl;
    final sorted = history.daily.values.where((v) => v > 0).toList()..sort();
    final peak = sorted.isEmpty
        ? ctl * 1.1
        : sorted[((sorted.length - 1) * 0.9).round()];
    return TrainingLoadSummary(
      ctl: ctl,
      atl: atl,
      optimalLow: ctl * 0.8,
      optimalHigh: (ctl * 1.1).clamp(ctl * 0.8, ctl * 2),
      peak: peak * 1.1,
    );
  }

  static const empty = TrainingLoadSummary(
    ctl: 0,
    atl: 0,
    optimalLow: 0,
    optimalHigh: 0,
    peak: 0,
  );

  /// Fitness.
  final double ctl;

  /// Fatigue.
  final double atl;

  /// Productive daily-load band around fitness.
  final double optimalLow;
  final double optimalHigh;

  /// 90th percentile of daily load, with headroom.
  final double peak;

  /// Form.
  double get tsb => ctl - atl;

  bool get hasHistory => ctl > 0 || atl > 0;
  FormStatus get status =>
      hasHistory ? FormStatus.of(tsb) : FormStatus.noHistory;
}
