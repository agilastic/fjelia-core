import 'package:fjelia_core/services/course/sun.dart';
import 'package:test/test.dart';

void main() {
  test('sunrise and sunset in Chamonix at the UTMB start', () {
    // 28 August 2026, 45.92 N 6.87 E: about 06:52 and 20:23 CEST (UTC+2);
    // within a few minutes, which is all the plan needs.
    final s = sunTimes(DateTime.utc(2026, 8, 28), 45.92, 6.87);
    expect(
      s.rise!.difference(DateTime.utc(2026, 8, 28, 4, 52)).inMinutes.abs(),
      lessThanOrEqualTo(4),
    );
    expect(
      s.set!.difference(DateTime.utc(2026, 8, 28, 18, 23)).inMinutes.abs(),
      lessThanOrEqualTo(4),
    );
  });

  test('the midnight sun and the polar night are named', () {
    expect(sunTimes(DateTime.utc(2026, 6, 21), 78.2, 15.6).polar, Polar.day);
    expect(sunTimes(DateTime.utc(2026, 12, 21), 78.2, 15.6).polar, Polar.night);
  });

  test('darkness during a night stage', () {
    // 18:00 to 06:00 UTC in Chamonix at the end of August: dark from about
    // 18:23 to 04:52, roughly ten and a half of twelve hours.
    final h = darkHours(
      DateTime.utc(2026, 8, 28, 18),
      DateTime.utc(2026, 8, 29, 6),
      45.92,
      6.87,
    );
    expect(h, closeTo(10.5, 0.2));
    expect(isDark(DateTime.utc(2026, 8, 28, 12), 45.92, 6.87), isFalse);
  });
}
