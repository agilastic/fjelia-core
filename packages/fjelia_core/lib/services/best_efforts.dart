/// Best efforts inside one activity: the fastest stretch over a distance,
/// and the highest average power over a duration.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../models/heart_rate.dart';
import 'sample_series.dart';

/// The distances with running records.
const runEffortDistances = [
  ('400m', 400.0),
  ('1K', 1000.0),
  ('5K', 5000.0),
  ('10K', 10000.0),
  ('15K', 15000.0),
  ('10 mile', 16093.4),
  ('20K', 20000.0),
  ('Half-Marathon', 21097.5),
  ('Marathon', 42195.0),
  ('50K', 50000.0),
];

/// The distances with riding records.
const rideEffortDistances = [
  ('10K', 10000.0),
  ('30K', 30000.0),
  ('80K', 80000.0),
  ('100K', 100000.0),
  ('180K', 180000.0),
];

/// The durations of the power curve, seconds.
const powerCurveDurations = [
  5,
  15,
  30,
  60,
  180,
  300,
  600,
  1200,
  1800,
  3600,
  7200,
  10800,
];

List<Map>? _samples(String metricsJson) {
  if (metricsJson.isEmpty) return null;
  try {
    final decoded = jsonDecode(metricsJson);
    return decoded is List ? decoded.whereType<Map>().toList() : null;
  } catch (_) {
    return null;
  }
}

/// The fastest moving time (s) over each of [targets] metres in one
/// activity's samples. Time stopped (a gap with almost no distance) does not
/// count, so a red light does not spoil a record. Distances the activity is
/// too short for are left out.
Map<double, double> bestEfforts(String metricsJson, List<double> targets) {
  final samples = _samples(metricsJson);
  if (samples == null) return const {};
  final times = <double>[];
  final dists = <double>[];
  var moving = 0.0;
  DateTime? lastAt;
  double? lastD;
  for (final s in samples) {
    final d = (s['d'] as num?)?.toDouble();
    if (d == null || !d.isFinite) continue;
    final at = heartRateTimestamp(s['t']);
    final spd = (s['spd'] as num?)?.toDouble();
    if (lastD != null) {
      final step = d - lastD;
      if (step < 0) continue;
      double dt;
      if (at != null && lastAt != null) {
        dt = at.difference(lastAt).inMilliseconds / 1000;
      } else if (spd != null && spd > .1) {
        dt = step / spd;
      } else {
        continue;
      }
      // Standing: more than 5 s with less than 0.5 m/s does not count.
      if (dt > 5 && step / dt < .5) dt = 0;
      moving += dt;
    }
    times.add(moving);
    dists.add(d);
    lastAt = at ?? lastAt;
    lastD = d;
  }
  final out = <double, double>{};
  if (dists.length < 2) return out;
  for (final target in targets) {
    if (dists.last - dists.first < target) continue;
    var best = double.infinity;
    var j = 0;
    for (var i = 0; i < dists.length; i++) {
      while (j < dists.length && dists[j] - dists[i] < target) {
        j++;
      }
      if (j >= dists.length) break;
      // The stretch may run a little past the target: scale back to it.
      final covered = dists[j] - dists[i];
      final t = (times[j] - times[i]) * target / covered;
      if (t > 0 && t < best) best = t;
    }
    if (best.isFinite) out[target] = best;
  }
  return out;
}

/// The highest average power (W) over each of [durations] seconds in one
/// activity's samples. Power is held between samples for up to 10 s; a
/// longer gap counts as zero, as on a head unit that stopped recording.
/// Durations longer than the activity are left out.
Map<int, double> meanMaxPower(
  String metricsJson, [
  List<int> durations = powerCurveDurations,
]) {
  final perSecond = SampleSeries.fromMetrics(metricsJson).power;
  if (perSecond.isEmpty) return const {};
  final prefix = List<double>.filled(perSecond.length + 1, 0);
  for (var i = 0; i < perSecond.length; i++) {
    prefix[i + 1] = prefix[i] + perSecond[i];
  }
  final out = <int, double>{};
  for (final d in durations) {
    if (d > perSecond.length) continue;
    var best = 0.0;
    for (var i = d; i <= perSecond.length; i++) {
      best = math.max(best, prefix[i] - prefix[i - d]);
    }
    if (best > 0) out[d] = best / d;
  }
  return out;
}
