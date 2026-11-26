import 'package:fjelia_core/utils/days.dart';
import 'package:fjelia_core/utils/stats.dart';
import 'package:test/test.dart';

void main() {
  test('days', () {
    expect(dayOf(DateTime(2026, 11, 27, 23, 59)), DateTime(2026, 11, 27));
    expect(
      isSameDay(DateTime(2026, 3, 29, 1), DateTime(2026, 3, 29, 23)),
      isTrue,
    );
    expect(isSameDay(DateTime(2026, 3, 29), DateTime(2026, 3, 30)), isFalse);
    expect(isoDay(DateTime(2026, 1, 5, 18)), '2026-01-05');
  });

  test('median and percentile leave the values as they are', () {
    final v = [5.0, 1.0, 3.0, 2.0];
    expect(median(v), 2.5);
    expect(median([4.0, 1.0, 9.0]), 4);
    expect(median(const []), isNull);
    expect(percentile(v, 0.95), 5);
    expect(percentile(v, 0), 1);
    expect(v, [5.0, 1.0, 3.0, 2.0]);
  });
}
