import 'package:fjelia_core/services/course/course.dart';
import 'package:fjelia_core/services/course/course_profile.dart';
import 'package:fjelia_core/services/course/race_readiness.dart';
import 'package:test/test.dart';

/// Up [up] m over [km] km at an even grade, then back down.
List<Map<String, num>> hill(double km, double up, int seconds) => [
  for (var i = 0; i <= 200; i++)
    {
      't': seconds * 1000 * i ~/ 200,
      'd': km * 1000 * i / 200,
      'ele': 500 + up * (i <= 100 ? i / 100 : (200 - i) / 100),
    },
];

void main() {
  test('training next to what the course asks for', () {
    final course = analyseCourse(
      Course(
        points: [
          for (final s in hill(20, 1200, 0))
            CoursePoint(0, 0, s['ele']!.toDouble(), s['d']!.toDouble()),
        ],
      ),
    )!;
    final runs = [
      TrainingRun(
        start: DateTime(2026, 11, 2),
        seconds: 5400,
        gain: 600,
        samples: hill(12, 600, 5400),
      ),
      TrainingRun(start: DateTime(2026, 11, 4), seconds: 3600, gain: 300),
      TrainingRun(start: DateTime(2026, 11, 10), seconds: 7200, gain: 200),
    ];
    final r = raceReadiness(runs, course, 4 * 3600);
    expect(r.runs, 3);
    expect(r.longestRun, 7200);
    // 2 and 4 November share a week.
    expect(r.bestWeekClimb, 900);
    expect(r.longestClimb, closeTo(600, 15));
    expect(r.longestDescent, closeTo(600, 15));
    expect(r.courseLongestClimb, closeTo(1200, 20));
    expect(r.courseClimb, closeTo(1200, 20));
  });
}
