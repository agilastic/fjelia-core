import 'dart:math' as math;

import 'course.dart';
import 'course_prediction.dart';
import 'sun.dart';

/// Slowing per °C of the day's high above [heatFromC], from Wegelin and
/// Hoffman (2011), "Variables associated with odds of finishing and finish
/// time in a 161-km ultramarathon" (Western States: 0.34–0.77 % per °C).
/// The midpoint plans the time; the ends widen its range.
const heatPerC = (low: 0.0034, mid: 0.00555, high: 0.0077);

/// Below this high the plan adds no heat.
const heatFromC = 15.0;

/// What the athlete expects of race day, kept with the course.
class RacePlanSettings {
  const RacePlanSettings({
    this.highTempC,
    this.nightSlowdown = 0,
    this.stopMinutes = 0,
  });

  /// The day's expected high in °C; null when unknown (no heat added).
  final double? highTempC;

  /// How much slower the athlete is in the dark, as a fraction (0.1 = 10 %
  /// slower). The athlete's own estimate: no study gives a figure for
  /// trail running that holds for everyone.
  final double nightSlowdown;

  /// Minutes spent at each aid station.
  final int stopMinutes;

  RacePlanSettings copyWith({
    double? Function()? highTempC,
    double? nightSlowdown,
    int? stopMinutes,
  }) => RacePlanSettings(
    highTempC: highTempC == null ? this.highTempC : highTempC(),
    nightSlowdown: nightSlowdown ?? this.nightSlowdown,
    stopMinutes: stopMinutes ?? this.stopMinutes,
  );

  Map<String, Object?> toJson() => {
    'high_c': ?highTempC,
    if (nightSlowdown > 0) 'night': nightSlowdown,
    if (stopMinutes > 0) 'stop_min': stopMinutes,
  };

  static RacePlanSettings fromJson(Object? j) => j is Map
      ? RacePlanSettings(
          highTempC: (j['high_c'] as num?)?.toDouble(),
          nightSlowdown: ((j['night'] as num?) ?? 0).toDouble().clamp(0, 0.5),
          stopMinutes: ((j['stop_min'] as num?) ?? 0).round().clamp(0, 120),
        )
      : const RacePlanSettings();
}

/// One leg with race-day conditions: the moving time slowed for the dark
/// and the heat, and the stop at its end.
class PlannedLeg {
  const PlannedLeg({
    required this.leg,
    required this.seconds,
    required this.stopSeconds,
    required this.arrival,
    required this.darkHours,
    required this.heat,
  });
  final CourseLeg leg;

  /// Moving time on the leg.
  final double seconds;

  /// Time at the aid station at its end.
  final double stopSeconds;

  /// Elapsed time on arrival at its end, stops before it included.
  final double arrival;

  /// Hours of it in the dark; 0 while the start time is unknown.
  final double darkHours;

  /// How much the heat slowed it, as a fraction.
  final double heat;
}

/// The race as planned: moving times, stops, night and heat.
class RacePlan {
  const RacePlan({
    required this.legs,
    required this.seconds,
    required this.fastest,
    required this.slowest,
  });
  final List<PlannedLeg> legs;

  /// Finish time in seconds, and the range around it.
  final double seconds, fastest, slowest;

  double get darkHours => legs.fold(0, (s, l) => s + l.darkHours);
  double get stopSeconds => legs.fold(0, (s, l) => s + l.stopSeconds);
}

/// Applies race-day conditions to [prediction], leg by leg along the
/// clock from [start]: darkness at the course's start point slows by
/// [RacePlanSettings.nightSlowdown], the day's heat by [heatPerC] on the
/// daylight part, and each aid station adds its stop. Without a start the
/// clock is unknown: no darkness, and heat on all of it.
RacePlan planRace(
  Course course,
  CoursePrediction prediction, {
  DateTime? start,
  RacePlanSettings settings = const RacePlanSettings(),
}) {
  final first = course.points.first;
  final aid = {
    for (final c in course.checkpoints)
      if (c.aid) c.name,
  };
  ({List<PlannedLeg> legs, double seconds}) run(double heatRate) {
    final legs = <PlannedLeg>[];
    var t = 0.0;
    for (final (i, leg) in prediction.legs.indexed) {
      final base = leg.seconds;
      var dark = 0.0;
      if (start != null && base > 0) {
        final from = start.add(Duration(seconds: t.round()));
        dark = darkHours(
          from,
          from.add(Duration(seconds: base.round())),
          first.lat,
          first.lng,
        );
      }
      final darkShare = base <= 0 ? 0.0 : math.min(1.0, dark * 3600 / base);
      final high = settings.highTempC;
      final heat = high == null || high <= heatFromC
          ? 0.0
          : heatRate * (high - heatFromC) * (1 - darkShare);
      final seconds = base * (1 + darkShare * settings.nightSlowdown + heat);
      final last = i == prediction.legs.length - 1;
      final stop = !last && aid.contains(leg.to)
          ? settings.stopMinutes * 60.0
          : 0.0;
      legs.add(
        PlannedLeg(
          leg: leg,
          seconds: seconds,
          stopSeconds: stop,
          arrival: t + seconds,
          darkHours: dark * (seconds / math.max(base, 1)),
          heat: heat,
        ),
      );
      t += seconds + stop;
    }
    return (legs: legs, seconds: legs.isEmpty ? 0 : legs.last.arrival);
  }

  final mid = run(heatPerC.mid);
  return RacePlan(
    legs: mid.legs,
    seconds: mid.seconds,
    fastest: run(heatPerC.low).seconds * (1 - predictionFaster),
    slowest: run(heatPerC.high).seconds * (1 + predictionSlower),
  );
}
