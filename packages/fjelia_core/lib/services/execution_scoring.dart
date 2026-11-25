import 'dart:convert';
import 'dart:math' as math;

import '../models/plan_views.dart';

/// How a completed workout matches its planned session: duration, zones and
/// intensity.
abstract final class ExecutionScoring {
  /// Seconds in each of six zones: from the activity's own zone split, else
  /// from its heart-rate samples against the zone [floors]. All zero when
  /// neither is known.
  static List<double> zoneSeconds(ActivityView activity, List<int>? floors) {
    final durationSec = activity.durationSeconds.toDouble();
    var zoneSec = zoneSecFromSplit(activity.hrZonesJson, durationSec);
    if (zoneSec == null && activity.metricsJson != null && floors != null) {
      zoneSec = zoneSecFromSamples(activity.metricsJson!, floors, durationSec);
    }
    return zoneSec ?? List<double>.filled(6, 0.0);
  }

  /// `off_plan` (< 40 % of planned), `under` (< 80 %), `over` (> 125 %)
  /// or `on_target`.
  static String verdict(
    double durationRatio,
    List<double> zoneSec,
    List<double>? planned,
  ) {
    if (durationRatio < 0.4) return 'off_plan';
    if (durationRatio < 0.8) return 'under';
    if (durationRatio > 1.25) return 'over';
    return 'on_target';
  }

  /// Treff polarization index: log10((Z1/Z2) × Z3 × 100) on a 3-zone model.
  static double? polarizationIndex(List<double> zoneSec) {
    final total = zoneSec.fold<double>(0.0, (a, b) => a + b);
    if (total < 300) return null;
    final z1 = (zoneSec[0] + zoneSec[1]) / total;
    final z2 = zoneSec[2] / total;
    final z3 = zoneSec.skip(3).fold<double>(0.0, (a, b) => a + b) / total;
    if (z2 <= 0 || z3 <= 0) return null;
    final pi = math.log((z1 / z2) * z3 * 100) / math.ln10;
    return double.parse(pi.toStringAsFixed(2));
  }

  /// Duration (30 %), zone distribution (30 %) and intensity (40 %), 0–100.
  static int? score3Axis(
    PlannedSessionView session,
    double actualMin,
    List<double> zoneSec,
    List<double>? planned,
  ) {
    if (session.plannedDurationMin <= 0) return null;
    final durationAxis =
        (1 - (actualMin / session.plannedDurationMin - 1).abs()).clamp(
          0.0,
          1.0,
        );

    final total = zoneSec.reduce((a, b) => a + b);
    double? zoneAxis;
    if (planned != null && total > 0) {
      var diff = 0.0;
      for (var i = 0; i < 6 && i < planned.length; i++) {
        diff += (zoneSec[i] / total - planned[i]).abs();
      }
      zoneAxis = (1 - diff / 2).clamp(0.0, 1.0);
    }

    double? intensityAxis;
    if (total > 0) {
      final target = session.primaryZone.clamp(1, 6);
      final weighted =
          [for (var i = 0; i < 6; i++) zoneSec[i] * (i + 1)]
              .reduce((a, b) => a + b) /
          total;
      intensityAxis = (1 - (weighted - target).abs() / 3).clamp(0.0, 1.0);
    }

    var score = 0.0, weight = 0.0;
    score += durationAxis * 0.3;
    weight += 0.3;
    if (zoneAxis != null) {
      score += zoneAxis * 0.3;
      weight += 0.3;
    }
    if (intensityAxis != null) {
      score += intensityAxis * 0.4;
      weight += 0.4;
    }
    return (score / weight * 100).round();
  }

  /// Seconds per zone from per-sample HR against the athlete's zone floors.
  static List<double> zoneSecFromSamples(
    String metricsJson,
    List<int> floors,
    double durationSec,
  ) {
    final hrs = (jsonDecode(metricsJson) as List)
        .whereType<Map<String, dynamic>>()
        .map((s) => (s['hr'] as num?)?.toDouble())
        .where((hr) => hr != null && hr > 0)
        .cast<double>()
        .toList();
    final zones = List<double>.filled(6, 0.0);
    if (hrs.isEmpty) return zones;
    final perSample = durationSec / hrs.length;
    for (final hr in hrs) {
      var z = 0;
      for (var i = 0; i < floors.length; i++) {
        if (hr >= floors[i]) z = i;
      }
      zones[z] += perSample;
    }
    return zones;
  }

  /// `{zone1: %, …}` → seconds per zone.
  static List<double>? zoneSecFromSplit(String? json, double durationSec) {
    if (json == null) return null;
    final m = jsonDecode(json) as Map<String, dynamic>;
    final zones = List<double>.filled(6, 0.0);
    var any = false;
    for (var i = 1; i <= 5; i++) {
      final pct = (m['zone$i'] as num?)?.toDouble() ?? 0.0;
      if (pct > 0) any = true;
      zones[i - 1] = durationSec * pct / 100;
    }
    return any ? zones : null;
  }

  /// Whether an activity of [activityType] can be the planned [sport]. A sport
  /// without a family of its own matches only an activity of that name, never
  /// everything.
  static bool sportFamilyMatches(String sport, String activityType) {
    final t = activityType.toLowerCase();
    bool any(List<String> keys) => keys.any(t.contains);
    switch (sport) {
      case 'running' || 'trail_running':
        return any(['run', 'trail', 'treadmill']);
      case 'cycling_road' || 'cycling_gravel' || 'cycling_mtb':
        return any(['cycl', 'bike', 'biking', 'ride', 'virtual']);
      case 'swimming':
        return any(['swim']);
      case 'strength':
        return any(['strength', 'gym', 'weight']);
      case 'indoor_rowing':
        return any(['row']);
      case 'hiking' || 'walking':
        return any(['hik', 'walk']);
      case 'inline_skating':
        return any(['skat', 'inline']);
      case 'nordic_skiing' || 'skate_skiing' || 'skiing':
        return any(['ski']);
      case 'yoga' || 'pilates' || 'stretching':
        return any(['yoga', 'pilates', 'stretch', 'mobility', 'flexib']);
      case 'triathlon':
        return any(['run', 'cycl', 'bike', 'swim']);
      default:
        final name = sport.replaceAll('_', '');
        return name.isNotEmpty && t.replaceAll('_', '').contains(name);
    }
  }
}
