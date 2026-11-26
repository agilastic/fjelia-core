import 'package:fjelia_core/services/course/course.dart';
import 'package:fjelia_core/services/course/course_prediction.dart';
import 'package:fjelia_core/services/course/course_profile.dart';
import 'package:fjelia_core/services/course/race_plan.dart';
import 'package:test/test.dart';

/// 10 km flat near Chamonix with an aid station at 5 km, at 6:00/km.
(Course, CoursePrediction) flat() {
  const perDegree = 111195.0;
  final course = Course(
    points: [
      for (var m = 0.0; m <= 10000; m += 50)
        CoursePoint(45.92 + m / perDegree, 6.87, 1000, m),
    ],
    checkpoints: const [CourseCheckpoint(name: 'Aid', km: 5)],
  );
  final p = predictCourse(course, analyseCourse(course)!, flatPace: 360)!;
  return (course, p);
}

void main() {
  test('stops at aid stations, no night or heat by default', () {
    final (c, p) = flat();
    final plan = planRace(
      c,
      p,
      settings: const RacePlanSettings(stopMinutes: 5),
    );
    expect(plan.seconds, closeTo(p.seconds + 300, 1));
    expect(plan.legs.first.stopSeconds, 300);
    expect(plan.legs.last.stopSeconds, 0); // none at the finish
  });

  test('the dark slows by the athlete\'s own share', () {
    final (c, p) = flat();
    // 20:30 UTC, two hours after sunset: all of it in the dark.
    final plan = planRace(
      c,
      p,
      start: DateTime.utc(2026, 8, 28, 20, 30),
      settings: const RacePlanSettings(nightSlowdown: 0.2, highTempC: 30),
    );
    expect(plan.seconds, closeTo(p.seconds * 1.2, 5));
    expect(plan.darkHours, closeTo(plan.seconds / 3600, 0.05));
  });

  test('a hot day slows the daylight by Wegelin and Hoffman', () {
    final (c, p) = flat();
    final plan = planRace(
      c,
      p,
      start: DateTime.utc(2026, 8, 28, 9),
      settings: const RacePlanSettings(highTempC: 25),
    );
    // 10 °C above 15: 5.55 % slower, 3.4–7.7 % at the ends of the range.
    expect(plan.seconds, closeTo(p.seconds * 1.0555, 2));
    expect(plan.slowest, greaterThan(p.seconds * 1.077));
    expect(plan.darkHours, 0);
  });

  test('settings travel with the course', () {
    final (c, _) = flat();
    final s = c.withSettings(
      const RacePlanSettings(highTempC: 28, nightSlowdown: 0.1, stopMinutes: 4),
    );
    final back = Course.fromJson(s.toJson())!;
    expect(back.settings.highTempC, 28);
    expect(back.settings.nightSlowdown, 0.1);
    expect(back.settings.stopMinutes, 4);
    expect(back.checkpoints.single.name, 'Aid');
  });
}
