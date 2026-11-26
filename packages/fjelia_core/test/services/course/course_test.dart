import 'dart:math' as math;

import 'package:fjelia_core/services/course/course.dart';
import 'package:fjelia_core/services/course/course_prediction.dart';
import 'package:fjelia_core/services/course/course_profile.dart';
import 'package:fjelia_core/services/course/grade_pace.dart';
import 'package:test/test.dart';

/// 20 km due north: 5 km flat at 100 m, 5 km up at 8 % to 500 m, 5 km down,
/// 5 km flat; a point every 25 m with ±2 m of deterministic jitter.
String gpx({bool waypoints = true}) {
  const metresPerDegree = 111195.0;
  final b = StringBuffer('<?xml version="1.0"?><gpx version="1.1">');
  if (waypoints) {
    b.write(
      '<wpt lat="${10000 / metresPerDegree}" lon="0"><name>Summit</name></wpt>',
    );
    b.write('<wpt lat="0.5" lon="0.5"><name>Far away</name></wpt>');
  }
  b.write('<trk><name>Test Trail</name><trkseg>');
  for (var m = 0.0; m <= 20000; m += 25) {
    final base = m < 5000
        ? 100.0
        : m < 10000
        ? 100 + (m - 5000) * 0.08
        : m < 15000
        ? 500 - (m - 10000) * 0.08
        : 100.0;
    final jitter = 2 * math.sin(m * 7.3);
    b.write(
      '<trkpt lat="${m / metresPerDegree}" lon="0"><ele>${base + jitter}</ele></trkpt>',
    );
  }
  b.write('</trkseg></trk></gpx>');
  return b.toString();
}

void main() {
  test('a GPX course is read with its checkpoints on the track', () {
    final c = parseCourseGpx(gpx())!;
    expect(c.name, 'Test Trail');
    expect(c.distanceM, closeTo(20000, 20));
    // The far waypoint is a landmark, not a checkpoint.
    expect(c.checkpoints.map((p) => (p.name, p.km)), [('Summit', 10.0)]);
    expect(Course.fromJson(c.toJson())!.points, hasLength(c.points.length));
  });

  test('the profile is cleaned and described', () {
    final p = analyseCourse(parseCourseGpx(gpx())!)!;
    // 400 m up and down, without the jitter.
    expect(p.gain, closeTo(400, 20));
    expect(p.loss, closeTo(400, 20));
    expect(p.effortKm, closeTo(24, 0.3));
    expect(p.climbs, hasLength(1));
    expect(p.climbs.single.startKm, closeTo(5, 0.2));
    expect(p.climbs.single.endKm, closeTo(10, 0.2));
    expect(p.climbs.single.grade, closeTo(0.08, 0.005));
    expect(p.descents, hasLength(1));
    // Jitter left after smoothing adds a point or two on 100 m.
    expect(p.steepestUp, closeTo(0.08, 0.025));
    // About 10 km flat and 5 km each in the 3–10 % bands up and down.
    expect(p.bands[3], closeTo(10, 0.5));
    expect(p.bands[4], closeTo(5, 0.5));
    expect(p.bands[2], closeTo(5, 0.5));
  });

  test('Minetti cost: flat 3.6 J/kg/m, about 1.66 times at +10 %', () {
    expect(minettiCost(0), 3.6);
    expect(gradeEffort(0.10), closeTo(1.66, 0.01));
    // Gentle descents are cheaper than the flat.
    expect(gradeEffort(-0.10), lessThan(1));
  });

  test('an own pace table comes from recorded runs', () {
    // An hour on a 6 % hill at 7:30/km, another on the flat at 5:00/km.
    List<Map<String, num>> run(double grade, double pace) => [
      for (var s = 0; s <= 3600; s += 10)
        {'t': s * 1000, 'd': s / pace * 1000, 'ele': s / pace * 1000 * grade},
    ];
    final t = buildGradePaceTable([run(0, 300), run(0.08, 450)])!;
    expect(t.paceOn(0), closeTo(300, 1));
    expect(t.paceOn(0.08), closeTo(450, 1));
    // Not run: the formula from the flat-equivalent pace.
    expect(t.paceOn(0.25), closeTo(t.flatPace * gradeEffort(0.25), 1));
  });

  test('the course is predicted leg by leg', () {
    final c = parseCourseGpx(gpx())!;
    final p = analyseCourse(c)!;
    final r = predictCourse(c, p, flatPace: 300)!;
    expect(r.legs.map((l) => l.to), ['Summit', 'Finish']);
    // The climb costs more than the descent gives back.
    expect(r.legs.first.seconds, greaterThan(r.legs.last.seconds));
    expect(r.seconds, greaterThan(20 * 300));
    expect(r.legs.last.arrival, r.seconds);
    expect(r.slowest, greaterThan(r.seconds));
  });

  test('grades read and colour the same everywhere', () {
    expect(formatGrade(0.084), '+8 %');
    expect(formatGrade(-0.12), '−12 %');
    expect(gradeArgb(0), 0xFF34C759);
    expect(gradeArgb(0.5), 0xFFE5383B);
    // Halfway between green and orange.
    expect(gradeArgb(0.04), 0xFF9ABC4B);
  });
}
