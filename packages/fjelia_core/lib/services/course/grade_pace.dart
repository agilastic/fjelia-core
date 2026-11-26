import 'dart:math' as math;

/// Energy cost of running on a grade, in J per kg per metre, from Minetti
/// et al. (2002), "Energy cost of walking and running at extreme uphill and
/// downhill slopes", J Appl Physiol 93:1039–1046. [grade] is a fraction;
/// the fit holds from -0.45 to +0.45 and is clamped there.
double minettiCost(double grade) {
  final i = grade.clamp(-0.45, 0.45);
  return 155.4 * math.pow(i, 5) -
      30.4 * math.pow(i, 4) -
      43.3 * math.pow(i, 3) +
      46.3 * i * i +
      19.5 * i +
      3.6;
}

/// How much harder a metre on [grade] is than on the flat: 1 on the flat,
/// about 1.7 at +10 %.
double gradeEffort(double grade) => minettiCost(grade) / minettiCost(0);

/// The grades of a personal pace table, as fractions: each band runs from
/// one edge to the next.
const gradeTableEdges = [
  -0.30,
  -0.20,
  -0.12,
  -0.06,
  -0.02,
  0.02,
  0.06,
  0.12,
  0.20,
  0.30,
];

/// What an athlete actually ran on one band of grades.
class GradeBand {
  const GradeBand({
    required this.from,
    required this.to,
    required this.metres,
    required this.seconds,
  });
  final double from, to;

  /// Distance and time run on it.
  final double metres, seconds;

  double get grade => (from + to) / 2;

  /// Seconds per kilometre.
  double get pace => seconds / metres * 1000;

  /// Climbing (or descending) metres per hour.
  double get verticalSpeed => metres * grade / seconds * 3600;
}

/// The athlete's own pace on each grade band, and the flat pace they hold
/// when the cost of the hills is taken out.
class GradePaceTable {
  const GradePaceTable({required this.bands, required this.flatPace});

  /// Bands with enough distance to say something, steepest descent first.
  final List<GradeBand> bands;

  /// Seconds per km on the flat for the same effort (grade-adjusted pace).
  final double flatPace;

  /// Minimum distance on a band before it is used instead of the formula.
  static const enoughMetres = 2000.0;

  /// Expected seconds per km on [grade]: the athlete's own band where it has
  /// [enoughMetres], else the flat pace scaled by [gradeEffort].
  double paceOn(double grade) {
    for (final b in bands) {
      if (grade >= b.from && grade < b.to && b.metres >= enoughMetres) {
        return b.pace;
      }
    }
    return flatPace * gradeEffort(grade);
  }
}

/// Builds the table from recorded runs: each a list of samples with `t`
/// (ms), `d` (m) and `ele` (m). Stretches of [stepM] are put in their grade
/// band; standing still (slower than 30 min/km) is left out, so aid-station
/// stops do not count as hiking. Null with too little hilly running.
GradePaceTable? buildGradePaceTable(
  Iterable<List<Map<String, num>>> runs, {
  double stepM = 50,
}) {
  final metres = List<double>.filled(gradeTableEdges.length - 1, 0);
  final seconds = List<double>.filled(gradeTableEdges.length - 1, 0);
  var flatEquivalentM = 0.0, movingS = 0.0;
  for (final samples in runs) {
    Map<String, num>? from;
    for (final s in samples) {
      if (s['d'] == null || s['t'] == null || s['ele'] == null) continue;
      if (from == null) {
        from = s;
        continue;
      }
      final dm = (s['d']! - from['d']!).toDouble();
      if (dm < stepM) continue;
      final ds = (s['t']! - from['t']!) / 1000;
      final grade = (s['ele']! - from['ele']!) / dm;
      from = s;
      if (ds <= 0 || ds / dm * 1000 > 1800 || grade.abs() > 0.45) continue;
      final band = _band(grade);
      if (band != null) {
        metres[band] += dm;
        seconds[band] += ds;
      }
      flatEquivalentM += dm * gradeEffort(grade);
      movingS += ds;
    }
  }
  if (flatEquivalentM < 5000) return null;
  return GradePaceTable(
    flatPace: movingS / flatEquivalentM * 1000,
    bands: [
      for (var i = 0; i < metres.length; i++)
        if (metres[i] > 0)
          GradeBand(
            from: gradeTableEdges[i],
            to: gradeTableEdges[i + 1],
            metres: metres[i],
            seconds: seconds[i],
          ),
    ],
  );
}

int? _band(double g) {
  for (var i = 0; i < gradeTableEdges.length - 1; i++) {
    if (g >= gradeTableEdges[i] && g < gradeTableEdges[i + 1]) return i;
  }
  return null;
}
