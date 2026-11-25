import 'dart:math' as math;

import '../models/plan_views.dart';

/// Race-time prediction from the athlete's best recent run (Riegel).
abstract final class RacePrediction {
  /// Fastest of [runs] up to 10 km, corrected for fitness change since then:
  /// by the VO2max trend in [vo2max] (oldest first) when there are two or
  /// more values, otherwise 1 %/week of detraining (max 30 %) up to [now].
  static ({double distM, String label, int timeSec})? bestRunAnchor(
    Iterable<ActivityView> runs,
    List<({DateTime date, double vo2max})> vo2max, {
    required DateTime now,
  }) {
    // A list literal, not runs.where: a caller's List<ActivityRecord> would
    // make reduce demand a closure over records and fail at runtime.
    final short = [
      for (final a in runs)
        if ((a.distanceMeters ?? 0) <= 10000.0) a,
    ];
    if (short.isEmpty) return null;
    final best = short.reduce((a, b) {
      final paceA = a.durationSeconds / a.distanceMeters!;
      final paceB = b.durationSeconds / b.distanceMeters!;
      return paceA <= paceB ? a : b;
    });

    final dist = best.distanceMeters!;
    final distLabel = '${(dist / 1000).toStringAsFixed(1)} km';

    final wellness = vo2max.where((w) => w.vo2max > 0).toList();

    double factor;
    String label;
    if (wellness.length >= 2) {
      final then = wellness.reduce(
        (a, b) =>
            a.date.difference(best.startDate).abs() <=
                b.date.difference(best.startDate).abs()
            ? a
            : b,
      );
      final latest = wellness.last;
      factor = then.vo2max / latest.vo2max;
      final pct = ((latest.vo2max / then.vo2max - 1) * 100).round();
      label = pct != 0
          ? 'best $distLabel · VO2max ${pct > 0 ? '+' : ''}$pct% adj'
          : 'best $distLabel';
    } else {
      final weeks = now.difference(best.startDate).inDays / 7;
      final decay = (weeks * 0.01).clamp(0.0, 0.3);
      factor = 1 + decay;
      label = weeks > 4
          ? 'best $distLabel · ${weeks.round()}w decay'
          : 'best $distLabel';
    }

    return (
      distM: dist,
      label: label,
      timeSec: (best.durationSeconds * factor).round(),
    );
  }

  /// What [anchor] predicts for [goal]; null for other sports than running.
  static int? estimateFinish(
    RaceGoalView goal,
    ({double distM, String label, int timeSec})? anchor,
  ) {
    if (!isPredictable(goal)) return null;
    if (anchor == null || anchor.distM <= 0) return null;
    return predict(
      anchor.timeSec,
      anchor.distM,
      goal.distanceM,
      elevationGainM: goal.elevationM,
    );
  }

  /// Only running goals with a distance have a prediction.
  static bool isPredictable(RaceGoalView goal) =>
      {'running', 'trail_running'}.contains(goal.primarySport) &&
      goal.distanceM > 0;

  /// 5 km time implied by a VO2max (inverse of Daniels' oxygen-cost curve).
  static int vo2maxToAnchor5kSec(double vo2max) {
    final metersPerMin = 29.54 + 5.000663 * vo2max - 0.007546 * vo2max * vo2max;
    return (5000 / metersPerMin * 60).round();
  }

  /// How much longer a course with [elevationGainM] over [distM] runs than a
  /// flat one: the course counts as that many times its distance.
  static double hillFactor(double distM, double? elevationGainM) {
    var grade = 0.0;
    if (elevationGainM != null && elevationGainM > 0 && distM > 0) {
      grade = (elevationGainM / distM * 100).clamp(0.0, 30.0);
    }
    return 1 + 0.033 * grade + 0.00185 * grade * grade;
  }

  /// Riegel prediction with an uphill penalty for hilly courses.
  static int predict(
    int anchorSec,
    double anchorDistM,
    double targetDistM, {
    double? elevationGainM,
  }) {
    final effective = targetDistM * hillFactor(targetDistM, elevationGainM);
    return (anchorSec * math.pow(effective / anchorDistM, 1.06)).round();
  }

  static String formatTime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
