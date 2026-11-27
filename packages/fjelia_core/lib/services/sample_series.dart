/// One activity's samples as one value per second: the common ground of the
/// power curve, critical power and W′ balance, aerobic decoupling and
/// efficiency, and interval detection.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../models/heart_rate.dart';

/// Values per second from the start of the recording. A value is held
/// between samples for up to [maxHold] seconds; across a longer gap (the
/// recording paused) power counts as zero and the others as missing (NaN).
class SampleSeries {
  SampleSeries._(this.power, this.heartRate, this.speed, this.distance);

  static const maxHold = 10;

  /// Watts; zero where nothing was recorded. Empty without a power meter.
  final List<double> power;

  /// Beats per minute, NaN where missing. Empty without heart rate.
  final List<double> heartRate;

  /// Metres per second, NaN where missing. Empty without speed.
  final List<double> speed;

  /// Metres from the start, NaN where missing. Empty without distance.
  final List<double> distance;

  int get length => math.max(
    math.max(power.length, heartRate.length),
    math.max(speed.length, distance.length),
  );

  bool get hasPower => power.any((w) => w > 0);
  bool get hasHeartRate => heartRate.any((h) => !h.isNaN);
  bool get hasSpeed => speed.any((v) => !v.isNaN && v > 0);

  /// From an activity's stored samples (`metrics_json`: `t`, `w`, `hr`,
  /// `spd`, `d`); empty for anything unreadable. At most six hours.
  factory SampleSeries.fromMetrics(String? metricsJson) {
    final empty = SampleSeries._(const [], const [], const [], const []);
    if (metricsJson == null || metricsJson.isEmpty) return empty;
    final Object? decoded;
    try {
      decoded = jsonDecode(metricsJson);
    } on FormatException {
      return empty;
    }
    if (decoded is! List) return empty;
    final timed = <(DateTime, Map)>[
      for (final s in decoded.whereType<Map>())
        if (heartRateTimestamp(s['t']) case final at?) (at, s),
    ];
    if (timed.length < 2) return empty;
    timed.sort((a, b) => a.$1.compareTo(b.$1));
    final origin = timed.first.$1;
    // Each channel follows the samples that carry it, as the power curve
    // always did: a sample without power does not stop the power held.
    List<double> channel(
      String key, {
      required bool zeroInGaps,
      double max = double.infinity,
    }) {
      final points = [
        for (final (at, s) in timed)
          if (s[key] case final num v when v.isFinite && v >= 0 && v < max)
            (at.difference(origin).inSeconds, v.toDouble()),
      ];
      if (points.length < 2) return const [];
      const limit = 6 * 3600;
      final gone = zeroInGaps ? 0.0 : double.nan;
      final out = <double>[
        for (var s = 0; s < math.min(points.first.$1, limit); s++) gone,
      ];
      for (var i = 0; i < points.length - 1 && out.length < limit; i++) {
        final gap = points[i + 1].$1 - points[i].$1;
        if (gap <= 0) continue;
        for (var s = 0; s < gap && out.length < limit; s++) {
          out.add(s == 0 || gap <= maxHold ? points[i].$2 : gone);
        }
      }
      return out;
    }

    return SampleSeries._(
      channel('w', zeroInGaps: true, max: 3000),
      channel('hr', zeroInGaps: false, max: 260),
      channel('spd', zeroInGaps: false, max: 40),
      channel('d', zeroInGaps: false),
    );
  }

  /// A series made directly, for tests and imported files.
  SampleSeries.of({
    this.power = const [],
    this.heartRate = const [],
    this.speed = const [],
    this.distance = const [],
  });
}

/// The mean of [values] over [window] seconds ending at each second (the
/// first ones over what there is so far); NaN values count as gaps.
List<double> rollingMean(List<double> values, int window) {
  final out = List<double>.filled(values.length, double.nan);
  var sum = 0.0, n = 0;
  for (var i = 0; i < values.length; i++) {
    if (!values[i].isNaN) {
      sum += values[i];
      n++;
    }
    if (i >= window && !values[i - window].isNaN) {
      sum -= values[i - window];
      n--;
    }
    if (n > 0) out[i] = sum / n;
  }
  return out;
}

/// Normalized power (Coggan): the fourth-power mean of the 30-second rolling
/// average, to the fourth root. Null for less than a minute.
double? normalizedPower(List<double> power) {
  if (power.length < 60) return null;
  final rolled = rollingMean(power, 30).skip(29);
  var sum = 0.0, n = 0;
  for (final p in rolled) {
    sum += math.pow(p, 4);
    n++;
  }
  return n == 0 ? null : math.pow(sum / n, .25).toDouble();
}
