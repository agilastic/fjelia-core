import 'dart:math' as math;

import 'course.dart';
import 'course_profile.dart';

/// A recorded run, as race readiness needs it.
class TrainingRun {
  const TrainingRun({
    required this.start,
    required this.seconds,
    this.gain,
    this.samples = const [],
  });
  final DateTime start;
  final int seconds;

  /// Metres climbed, as the watch counted them.
  final double? gain;

  /// `t` (ms), `d` (m) and `ele` (m), when recorded.
  final List<Map<String, num>> samples;
}

/// What the course asks for next to what recent training did: facts to
/// compare, not a score. Each pair is (training, course).
class RaceReadiness {
  const RaceReadiness({
    required this.runs,
    required this.longestRun,
    required this.raceTime,
    required this.bestWeekClimb,
    required this.courseClimb,
    required this.longestClimb,
    required this.courseLongestClimb,
    required this.longestDescent,
    required this.courseLongestDescent,
  });

  /// Runs looked at.
  final int runs;

  /// Seconds: the longest run, and the planned race time.
  final double longestRun, raceTime;

  /// Metres: the most climbed in one week (Monday to Sunday), and the
  /// course's whole climb.
  final double bestWeekClimb, courseClimb;

  /// Metres: the biggest single climb run in training, and the course's.
  final double longestClimb, courseLongestClimb;

  /// Metres: the biggest single descent run in training, and the course's.
  final double longestDescent, courseLongestDescent;
}

/// Compares [runs] (the last weeks of running) with [course] and its
/// planned [raceSeconds]. Climbs and descents of the runs are found the
/// same way as the course's ([analyseCourse]).
RaceReadiness raceReadiness(
  List<TrainingRun> runs,
  CourseProfile course,
  double raceSeconds,
) {
  var longestRun = 0.0;
  var longestClimb = 0.0, longestDescent = 0.0;
  final weeks = <DateTime, double>{};
  for (final r in runs) {
    longestRun = math.max(longestRun, r.seconds.toDouble());
    final day = DateTime(r.start.year, r.start.month, r.start.day);
    final monday = day.subtract(Duration(days: day.weekday - 1));
    weeks[monday] = (weeks[monday] ?? 0) + (r.gain ?? 0);
    final points = [
      for (final s in r.samples)
        if (s['d'] != null && s['ele'] != null)
          CoursePoint(0, 0, s['ele']!.toDouble(), s['d']!.toDouble()),
    ];
    if (points.length < 2) continue;
    final p = analyseCourse(Course(points: points));
    if (p == null) continue;
    for (final c in p.climbs) {
      longestClimb = math.max(longestClimb, c.metres);
    }
    for (final d in p.descents) {
      longestDescent = math.max(longestDescent, d.metres);
    }
  }
  double biggest(List<CourseClimb> c) =>
      c.fold(0.0, (m, x) => math.max(m, x.metres));
  return RaceReadiness(
    runs: runs.length,
    longestRun: longestRun,
    raceTime: raceSeconds,
    bestWeekClimb: weeks.values.fold(0.0, math.max),
    courseClimb: course.gain,
    longestClimb: longestClimb,
    courseLongestClimb: biggest(course.climbs),
    longestDescent: longestDescent,
    courseLongestDescent: biggest(course.descents),
  );
}
