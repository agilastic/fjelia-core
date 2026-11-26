import 'dart:math' as math;

import 'course.dart';
import 'course_profile.dart';
import 'grade_pace.dart';

/// Riegel's fatigue exponent (Riegel 1981, "Athletic records and human
/// endurance"): time grows with distance to the power 1.06, so the pace of
/// a race of time T is that of a one-hour effort times (T / 1 h)^0.06.
const riegelExponent = 1.06;

/// The share by which the finish may be faster or slower than predicted.
/// Training runs say little about stops, night and bad days, so the slow
/// side is wider.
const predictionFaster = 0.05, predictionSlower = 0.12;

/// One leg between checkpoints.
class CourseLeg {
  const CourseLeg({
    required this.from,
    required this.to,
    required this.km,
    required this.gain,
    required this.loss,
    required this.seconds,
    required this.arrival,
  });
  final String from, to;
  final double km, gain, loss;

  /// Moving time on the leg and the elapsed time at its end.
  final double seconds, arrival;

  /// The cut-off at [to], when it has one.
  DateTime? cutoff(Course c) =>
      c.checkpoints.where((p) => p.name == to).firstOrNull?.cutoff;
}

/// The predicted finish and the time to each checkpoint.
class CoursePrediction {
  const CoursePrediction({
    required this.seconds,
    required this.legs,
    required this.fatigue,
  });

  /// Predicted finish time in seconds.
  final double seconds;
  final List<CourseLeg> legs;

  /// How much slower than a one-hour effort, from [riegelExponent].
  final double fatigue;

  double get fastest => seconds * (1 - predictionFaster);
  double get slowest => seconds * (1 + predictionSlower);
}

/// Predicts the course from the athlete's [table]: every 100 m of the
/// cleaned profile at the athlete's pace on its grade, slowed for the
/// length of the race by [riegelExponent]. Without a table, [flatPace]
/// (seconds per km) with the Minetti cost stands in.
CoursePrediction? predictCourse(
  Course course,
  CourseProfile profile, {
  GradePaceTable? table,
  double? flatPace,
}) {
  final t =
      table ??
      (flatPace == null
          ? null
          : GradePaceTable(bands: const [], flatPace: flatPace));
  if (t == null || profile.profile.length < 2) return null;
  // Time per profile step at a one-hour effort.
  final step = <double>[];
  for (var i = 1; i < profile.profile.length; i++) {
    final a = profile.profile[i - 1], b = profile.profile[i];
    final km = b.km - a.km;
    final grade = km <= 0 ? 0.0 : (b.ele - a.ele) / (km * 1000);
    step.add(t.paceOn(grade) * km);
  }
  final base = step.fold(0.0, (s, x) => s + x);
  final fatigue = math
      .pow(math.max(1.0, base / 3600), riegelExponent - 1)
      .toDouble();
  // Legs between the start, the checkpoints and the finish.
  final stops = [
    for (final c in course.checkpoints)
      if (c.km > 0 && c.km < profile.distanceKm - 0.05) c,
  ];
  final names = ['Start', for (final c in stops) c.name, 'Finish'];
  final edges = [0.0, for (final c in stops) c.km, profile.distanceKm];
  final legs = <CourseLeg>[];
  var elapsed = 0.0;
  for (var l = 0; l < edges.length - 1; l++) {
    var seconds = 0.0, gain = 0.0, loss = 0.0;
    for (var i = 1; i < profile.profile.length; i++) {
      final km = profile.profile[i].km;
      if (km <= edges[l] || km > edges[l + 1]) continue;
      seconds += step[i - 1] * fatigue;
      final de = profile.profile[i].ele - profile.profile[i - 1].ele;
      de > 0 ? gain += de : loss -= de;
    }
    elapsed += seconds;
    legs.add(
      CourseLeg(
        from: names[l],
        to: names[l + 1],
        km: edges[l + 1] - edges[l],
        gain: gain,
        loss: loss,
        seconds: seconds,
        arrival: elapsed,
      ),
    );
  }
  return CoursePrediction(seconds: elapsed, legs: legs, fatigue: fatigue);
}
