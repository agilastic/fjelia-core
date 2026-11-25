import 'dart:convert';
import 'dart:math' as math;

import '../models/plan_views.dart';

/// Shared visual scale; TRIMP has no fixed 250-point upper limit.
double trainingLoadScale(num? load, [num? optimalHigh]) =>
    (math.max(250, math.max(load ?? 0, optimalHigh ?? 0)) / 50).ceil() * 50.0;

const _zoneKeys = ['zone1', 'zone2', 'zone3', 'zone4', 'zone5'];
const _zoneWeights = [1.0, 1.1, 1.2, 3.1, 8.0];

/// Prefer recorded activity load; otherwise use zone-weighted minutes when HR zones are
/// stored, otherwise Banister TRIMP (rest 55, max 190 bpm); climbing adds
/// one point per 10 m.
double effectiveLoad(ActivityView a) => effectiveLoadFromSummary(
  durationSeconds: a.durationSeconds,
  recordedLoad: a.trainingLoad,
  elevationMeters: a.totalElevation,
  hrZonesJson: a.hrZonesJson,
  averageHeartRate: a.avgHeartRate,
);

/// The same calculation using only the scalar activity summary, so historical
/// initialization does not need years of GPS tracks and sample arrays.
double effectiveLoadFromSummary({
  required int durationSeconds,
  double? recordedLoad,
  double? elevationMeters,
  String? hrZonesJson,
  double? averageHeartRate,
}) {
  final recorded = recordedLoad;
  if (recorded != null && recorded.isFinite && recorded >= 0) return recorded;
  final minutes = durationSeconds / 60;
  if (minutes <= 0) return 0.0;
  final elevation = elevationMeters ?? 0.0;
  final climbBonus = elevation > 0 ? elevation / 10 : 0.0;

  final zonesJson = hrZonesJson;
  if (zonesJson != null) {
    final zones = jsonDecode(zonesJson) as Map<String, dynamic>;
    var load = 0.0;
    for (var i = 0; i < 5; i++) {
      final pct = (zones[_zoneKeys[i]] as num?)?.toDouble() ?? 0.0;
      load += minutes * (pct / 100) * _zoneWeights[i];
    }
    if (load > 0) return load + climbBonus;
  }

  final avgHr = averageHeartRate;
  if (avgHr != null && avgHr > 0) {
    final x = ((avgHr - 55) / 135).clamp(0.0, 1.0);
    return minutes * x * math.exp(1.92 * x) + climbBonus;
  }
  return recordedLoad ?? 0.0;
}

/// One sport's load this week vs last week.
class SportWeekLoad {
  SportWeekLoad(this.sport, [this.currentLoad = 0, this.previousLoad = 0]);

  final String sport;
  double currentLoad;
  double previousLoad;
}

typedef WeekLoad = ({
  String label,
  double load,
  double durationHours,
  double distanceKm,
  bool isCurrent,
});

/// The last 12 weeks of load, with this week's budget (previous week + 10 %).
class WeeklyLoadSummary {
  const WeeklyLoadSummary({
    required this.weeks,
    required this.currentLoad,
    required this.previousLoad,
    required this.sports,
  });

  final List<WeekLoad> weeks;
  final double currentLoad;
  final double previousLoad;
  final List<SportWeekLoad> sports;

  /// Share of the 10 %-progression limit used this week.
  double get usedFraction {
    final limit = previousLoad * 1.1;
    return limit <= 0 ? 0.0 : currentLoad / limit;
  }

  double get remaining =>
      (previousLoad * 1.1 - currentLoad).clamp(0.0, double.infinity);

  bool get nearLimit => usedFraction >= 0.9 && usedFraction < 1.0;
  bool get overLimit => usedFraction >= 1.0;
}
