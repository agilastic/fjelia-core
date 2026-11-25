/// Lactate thresholds from a step test: blood lactate measured at the end
/// of each step of rising intensity.
library;

import 'dart:math' as math;

/// One step of the test. [intensity] is watts on a bike, metres per
/// second running.
class LactateStep {
  const LactateStep({
    required this.intensity,
    required this.lactate,
    this.heartRate,
  });

  final double intensity;

  /// mmol/l.
  final double lactate;
  final double? heartRate;

  Map<String, Object?> toJson() => {
    'intensity': intensity,
    'lactate': lactate,
    'hr': ?heartRate,
  };

  static LactateStep? fromJson(Object? j) {
    if (j is! Map) return null;
    double? number(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    final i = number(j['intensity']), l = number(j['lactate']);
    if (i == null || l == null) return null;
    return LactateStep(intensity: i, lactate: l, heartRate: number(j['hr']));
  }
}

/// A threshold: the intensity, and the heart rate and lactate there.
class LactatePoint {
  const LactatePoint(this.intensity, this.lactate, this.heartRate);
  final double intensity;
  final double lactate;
  final double? heartRate;
}

/// How LT2 was found.
enum Lt2Method {
  /// Modified Dmax: the point of the fitted curve farthest from the line
  /// between the first rise and the last step.
  modifiedDmax,

  /// Fixed 4 mmol/l, with too few steps for a curve.
  fourMmol,
}

class LactateResult {
  const LactateResult({
    required this.baseline,
    this.lt1,
    this.lt2,
    this.lt2Method,
  });

  /// The lowest lactate of the easy steps, mmol/l.
  final double baseline;

  /// Aerobic threshold: lactate first 0.5 mmol/l above [baseline].
  final LactatePoint? lt1;

  /// Anaerobic threshold.
  final LactatePoint? lt2;
  final Lt2Method? lt2Method;
}

/// The thresholds of a test, or null with fewer than three usable steps.
LactateResult? analyseLactate(List<LactateStep> raw) {
  final steps = [
    for (final s in raw)
      if (s.intensity > 0 && s.lactate >= 0) s,
  ]..sort((a, b) => a.intensity.compareTo(b.intensity));
  if (steps.length < 3) return null;
  final baseline = steps
      .take(math.max(2, steps.length ~/ 3))
      .map((s) => s.lactate)
      .reduce(math.min);

  LactatePoint? at(double intensity) {
    for (var i = 0; i < steps.length - 1; i++) {
      final a = steps[i], b = steps[i + 1];
      if (intensity < a.intensity || intensity > b.intensity) continue;
      final f = b.intensity == a.intensity
          ? 0.0
          : (intensity - a.intensity) / (b.intensity - a.intensity);
      double lerp(double x, double y) => x + (y - x) * f;
      return LactatePoint(
        intensity,
        lerp(a.lactate, b.lactate),
        a.heartRate == null || b.heartRate == null
            ? null
            : lerp(a.heartRate!, b.heartRate!),
      );
    }
    return null;
  }

  /// The intensity where lactate first reaches [level], between steps.
  double? crossing(double level) {
    for (var i = 0; i < steps.length - 1; i++) {
      final a = steps[i], b = steps[i + 1];
      if (a.lactate < level && b.lactate >= level) {
        return a.intensity +
            (b.intensity - a.intensity) *
                (level - a.lactate) /
                (b.lactate - a.lactate);
      }
    }
    return null;
  }

  final lt1At = crossing(baseline + 0.5);
  final lt1 = lt1At == null ? null : at(lt1At);

  // Modified Dmax needs a curve: four steps or more.
  if (steps.length >= 4) {
    // The first rise: the step before lactate goes up by 0.4 or more.
    var start = 0;
    for (var i = 0; i < steps.length - 1; i++) {
      if (steps[i + 1].lactate - steps[i].lactate >= 0.4) {
        start = i;
        break;
      }
    }
    final coef = _cubicFit(steps);
    if (coef != null && start < steps.length - 1) {
      double curve(double x) =>
          coef[0] + coef[1] * x + coef[2] * x * x + coef[3] * x * x * x;
      final x0 = steps[start].intensity, y0 = steps[start].lactate;
      final x1 = steps.last.intensity, y1 = steps.last.lactate;
      final dx = x1 - x0, dy = y1 - y0;
      final norm = math.sqrt(dx * dx + dy * dy);
      var best = x0;
      var bestDistance = -1.0;
      for (var k = 0; k <= 400; k++) {
        final x = x0 + dx * k / 400;
        // Distance of the curve's point from the line, on the side under it.
        final d = (dy * x - dx * curve(x) + x1 * y0 - y1 * x0) / norm;
        if (d > bestDistance) {
          bestDistance = d;
          best = x;
        }
      }
      if (bestDistance > 0) {
        return LactateResult(
          baseline: baseline,
          lt1: lt1,
          lt2: at(best),
          lt2Method: Lt2Method.modifiedDmax,
        );
      }
    }
  }
  final four = crossing(4);
  return LactateResult(
    baseline: baseline,
    lt1: lt1,
    lt2: four == null ? null : at(four),
    lt2Method: four == null ? null : Lt2Method.fourMmol,
  );
}

/// Least-squares cubic through the steps: [a, b, c, d] of
/// a + b·x + c·x² + d·x³, or null when it cannot be solved.
List<double>? _cubicFit(List<LactateStep> steps) {
  // Scale x to keep the normal equations well-conditioned.
  final scale = steps.last.intensity;
  final m = List.generate(4, (_) => List<double>.filled(5, 0));
  for (final s in steps) {
    final x = s.intensity / scale;
    final powers = [1, x, x * x, x * x * x];
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        m[r][c] += powers[r] * powers[c];
      }
      m[r][4] += powers[r] * s.lactate;
    }
  }
  // Gaussian elimination with partial pivoting.
  for (var col = 0; col < 4; col++) {
    var pivot = col;
    for (var r = col + 1; r < 4; r++) {
      if (m[r][col].abs() > m[pivot][col].abs()) pivot = r;
    }
    if (m[pivot][col].abs() < 1e-12) return null;
    final tmp = m[col];
    m[col] = m[pivot];
    m[pivot] = tmp;
    for (var r = 0; r < 4; r++) {
      if (r == col) continue;
      final f = m[r][col] / m[col][col];
      for (var c = col; c < 5; c++) {
        m[r][c] -= f * m[col][c];
      }
    }
  }
  final scaled = [for (var r = 0; r < 4; r++) m[r][4] / m[r][r]];
  // Back to unscaled x.
  return [
    scaled[0],
    scaled[1] / scale,
    scaled[2] / (scale * scale),
    scaled[3] / (scale * scale * scale),
  ];
}
