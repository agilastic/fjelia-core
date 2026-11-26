import 'course.dart';
import 'race_plan.dart';

/// One leg as planned and as run.
class LegResult {
  const LegResult({
    required this.planned,
    required this.arrival,
    required this.seconds,
  });
  final PlannedLeg planned;

  /// Elapsed time on arrival at the leg's end, as recorded.
  final double arrival;

  /// Time from the leg's start to its end, stops included.
  final double seconds;

  /// Positive when slower than planned.
  double get behind => arrival - planned.arrival;
}

/// The race as planned against the race as recorded.
class RaceResult {
  const RaceResult({required this.legs, required this.seconds});
  final List<LegResult> legs;

  /// The recorded finish time.
  final double seconds;
}

/// Compares [plan] with a recorded race: [samples] with `t` (ms) and `d`
/// (m), in order. A watch measures the course a little longer or shorter
/// than the organiser's file, so each checkpoint is placed at the same
/// share of the recorded distance as of the course's. Null without
/// distance in the samples.
RaceResult? compareRace(
  Course course,
  RacePlan plan,
  List<Map<String, num>> samples,
) {
  final points = [
    for (final s in samples)
      if (s['t'] != null && s['d'] != null) s,
  ];
  if (points.length < 2 || course.distanceM <= 0) return null;
  final start = points.first['t']!.toDouble();
  final recorded = points.last['d']!.toDouble() - points.first['d']!.toDouble();
  if (recorded <= 0) return null;
  final scale = recorded / course.distanceM;

  // Elapsed seconds when the recorded distance first reaches [m].
  double elapsedAt(double m) {
    final target = points.first['d']! + m;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      if (b['d']! < target) continue;
      final span = b['d']! - a['d']!;
      final f = span <= 0 ? 0.0 : (target - a['d']!) / span;
      return (a['t']! + (b['t']! - a['t']!) * f - start) / 1000;
    }
    return (points.last['t']! - start) / 1000;
  }

  final legs = <LegResult>[];
  var km = 0.0;
  var before = 0.0;
  for (final p in plan.legs) {
    km += p.leg.km;
    final arrival = elapsedAt(km * 1000 * scale);
    legs.add(
      LegResult(planned: p, arrival: arrival, seconds: arrival - before),
    );
    before = arrival;
  }
  return RaceResult(legs: legs, seconds: (points.last['t']! - start) / 1000);
}
