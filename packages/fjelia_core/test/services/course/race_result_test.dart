import 'package:fjelia_core/services/course/course.dart';
import 'package:fjelia_core/services/course/course_prediction.dart';
import 'package:fjelia_core/services/course/course_profile.dart';
import 'package:fjelia_core/services/course/race_plan.dart';
import 'package:fjelia_core/services/course/race_result.dart';
import 'package:test/test.dart';

void main() {
  test('each checkpoint as planned and as run', () {
    const perDegree = 111195.0;
    final course = Course(
      points: [
        for (var m = 0.0; m <= 10000; m += 50)
          CoursePoint(45 + m / perDegree, 7, 1000, m),
      ],
      checkpoints: const [CourseCheckpoint(name: 'Half', km: 5)],
    );
    final plan = planRace(
      course,
      predictCourse(course, analyseCourse(course)!, flatPace: 360)!,
    );
    // Run: the watch measured 10.2 km; 5:30/km to halfway, then 6:30/km.
    final samples = <Map<String, num>>[];
    for (var s = 0; s <= 4000; s += 1) {
      final d = s <= 1683 ? s / 330 * 1000 : 5100 + (s - 1683) / 390 * 1000;
      if (d > 10200) break;
      samples.add({'t': s * 1000, 'd': d});
    }
    final r = compareRace(course, plan, samples)!;
    expect(r.legs.map((l) => l.planned.leg.to), ['Half', 'Finish']);
    // Halfway is at 5.1 km of the watch's 10.2 km: 1683 s.
    expect(r.legs.first.arrival, closeTo(1683, 6));
    expect(r.legs.first.behind, lessThan(0)); // ahead of the 6:00/km plan
    expect(r.legs.last.behind, greaterThan(0));
    expect(r.seconds, closeTo(r.legs.last.arrival, 6));
  });

  test('no distance, no comparison', () {
    final course = Course(
      points: const [CoursePoint(45, 7, 0, 0), CoursePoint(45.01, 7, 0, 1100)],
    );
    final plan = planRace(
      course,
      predictCourse(course, analyseCourse(course)!, flatPace: 360)!,
    );
    expect(
      compareRace(course, plan, const [
        {'t': 0},
        {'t': 1000},
      ]),
      isNull,
    );
  });
}
