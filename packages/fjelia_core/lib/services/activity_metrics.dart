/// What a coach reads from one activity beyond its totals: efficiency
/// factor and aerobic decoupling, critical power and W′ balance, and the
/// intervals in it.
library;

import 'dart:math' as math;

import 'sample_series.dart';

// --- Efficiency factor and aerobic decoupling ----------------------------

/// Output per heartbeat over a steady activity, and how much it fell from
/// the first half to the second (Friel's Pa:Hr).
class AerobicEfficiency {
  const AerobicEfficiency({
    required this.efficiencyFactor,
    required this.decouplingPercent,
    required this.byPower,
  });

  /// Normalized power per beat (W/bpm) when [byPower], else metres per
  /// minute per beat.
  final double efficiencyFactor;

  /// How much output per beat fell in the second half, percent; under 5 %
  /// is the usual sign of a sound aerobic base for that effort.
  final double decouplingPercent;
  final bool byPower;
}

/// Efficiency of [s]: by power when it has power, else by moving speed.
/// Null for less than 20 minutes or too little heart rate. The first ten
/// minutes (the warm-up) do not count when the activity is long enough.
AerobicEfficiency? aerobicEfficiency(SampleSeries s) {
  if (!s.hasHeartRate || s.heartRate.length < 20 * 60) return null;
  final byPower = s.hasPower;
  if (!byPower && !s.hasSpeed) return null;
  final skip = s.heartRate.length >= 50 * 60 ? 10 * 60 : 0;
  final n = math.min(s.heartRate.length, (byPower ? s.power : s.speed).length);
  if (n - skip < 20 * 60) return null;

  double? ef(int from, int to) {
    final hr = <double>[], out = <double>[];
    for (var i = from; i < to; i++) {
      final h = s.heartRate[i];
      final o = byPower ? s.power[i] : s.speed[i];
      if (h.isNaN || o.isNaN) continue;
      // Standing still is not running slowly.
      if (!byPower && o < .5) continue;
      hr.add(h);
      out.add(o);
    }
    if (hr.length < (to - from) * .6) return null;
    final meanHr = hr.reduce((a, b) => a + b) / hr.length;
    if (meanHr < 40) return null;
    final output = byPower
        ? normalizedPower(out)
        : out.reduce((a, b) => a + b) / out.length * 60;
    return output == null ? null : output / meanHr;
  }

  final whole = ef(skip, n);
  final mid = skip + (n - skip) ~/ 2;
  final first = ef(skip, mid), second = ef(mid, n);
  if (whole == null || first == null || second == null || first == 0) {
    return null;
  }
  return AerobicEfficiency(
    efficiencyFactor: whole,
    decouplingPercent: (first - second) / first * 100,
    byPower: byPower,
  );
}

// --- Critical power and W′ ------------------------------------------------

/// The two-parameter critical power model: the power that can be held for a
/// long time ([cp], W) and the work above it that can be spent before
/// exhaustion ([wPrime], J).
class CriticalPower {
  const CriticalPower(this.cp, this.wPrime);
  final double cp;
  final double wPrime;

  /// The power the model expects for [seconds].
  double powerFor(int seconds) => cp + wPrime / seconds;
}

/// The model fitted to the best efforts of 2 to 20 minutes in [curve]
/// (watts by seconds): work against time is a straight line whose slope is
/// CP and intercept W′ (Monod and Scherrer). Null with fewer than three such
/// efforts or a fit outside what people produce.
CriticalPower? fitCriticalPower(Map<int, double> curve) {
  final points = [
    for (final MapEntry(key: t, value: w) in curve.entries)
      if (t >= 120 && t <= 1200 && w > 0) (t.toDouble(), w * t),
  ];
  if (points.length < 3) return null;
  final n = points.length;
  final mt = points.fold(0.0, (s, p) => s + p.$1) / n;
  final mw = points.fold(0.0, (s, p) => s + p.$2) / n;
  var sxy = 0.0, sxx = 0.0;
  for (final (t, w) in points) {
    sxy += (t - mt) * (w - mw);
    sxx += (t - mt) * (t - mt);
  }
  if (sxx == 0) return null;
  final cp = sxy / sxx;
  final wPrime = mw - cp * mt;
  if (cp < 50 || cp > 600 || wPrime < 2000 || wPrime > 60000) return null;
  return CriticalPower(cp, wPrime);
}

/// W′ left at each second of [power] (J), by the differential model of
/// Froncioni, Clarke and Skiba: above CP it is spent watt for watt, below
/// it comes back the faster the further below CP and the emptier it is.
List<double> wPrimeBalance(List<double> power, CriticalPower model) {
  final out = List<double>.filled(power.length, model.wPrime);
  var balance = model.wPrime;
  for (var i = 0; i < power.length; i++) {
    final p = power[i];
    if (p > model.cp) {
      balance -= p - model.cp;
    } else {
      balance += (model.wPrime - balance) * (model.cp - p) / model.wPrime;
    }
    out[i] = balance;
  }
  return out;
}

// --- Intervals -----------------------------------------------------------

/// A stretch of hard work found in an activity.
class DetectedInterval {
  const DetectedInterval({
    required this.start,
    required this.seconds,
    required this.mean,
    this.heartRate,
  });

  /// Seconds from the start of the recording.
  final int start;
  final int seconds;

  /// Mean power (W) or speed (m/s) over it, as the activity was measured.
  final double mean;
  final double? heartRate;
}

/// The intervals in [values] (power, or speed for a run): stretches of at
/// least [minSeconds] whose 10-second average stays above [threshold] (by
/// default 115 % of the activity's moving average), joined across dips of
/// up to 10 seconds. At most [max] of them, in order.
List<DetectedInterval> detectIntervals(
  List<double> values, {
  List<double> heartRate = const [],
  double? threshold,
  int minSeconds = 30,
  int max = 40,
}) {
  final moving = [
    for (final v in values)
      if (!v.isNaN && v > 0) v,
  ];
  if (moving.length < 120) return const [];
  final level =
      threshold ?? moving.reduce((a, b) => a + b) / moving.length * 1.15;
  final smooth = rollingMean(values, 10);
  final spans = <(int, int)>[];
  int? from;
  var below = 0;
  for (var i = 0; i <= smooth.length; i++) {
    final hard = i < smooth.length && !smooth[i].isNaN && smooth[i] >= level;
    if (hard) {
      from ??= i;
      below = 0;
    } else if (from != null) {
      below++;
      if (below > 10 || i == smooth.length) {
        // The 10-second average trails the effort: shift back by half of it.
        final start = math.max(0, from - 5);
        final end = math.max(start, i - below - 5);
        if (end - start >= minSeconds) spans.add((start, end));
        from = null;
        below = 0;
      }
    }
  }
  double? mean(List<double> xs, int a, int b) {
    final v = [
      for (var i = a; i < math.min(b, xs.length); i++)
        if (!xs[i].isNaN) xs[i],
    ];
    return v.isEmpty ? null : v.reduce((x, y) => x + y) / v.length;
  }

  return [
    for (final (a, b) in spans.take(max))
      DetectedInterval(
        start: a,
        seconds: b - a,
        mean: mean(values, a, b) ?? 0,
        heartRate: heartRate.isEmpty ? null : mean(heartRate, a, b),
      ),
  ];
}
