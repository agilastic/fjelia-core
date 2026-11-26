import 'package:fjelia_core/utils/label_rows.dart';
import 'package:test/test.dart';

void main() {
  test('labels share two rows without meeting', () {
    final p = placeLabels(
      [
        (centre: 10, width: 40), // first row, kept inside the left edge
        (centre: 100, width: 60), // first row
        (centre: 120, width: 60), // meets the one before: second row
        (centre: 125, width: 60), // both rows taken: first row, moved right
      ],
      left: 0,
      right: 400,
    );
    expect(p, [
      (x: 0.0, row: 0),
      (x: 70.0, row: 0),
      (x: 90.0, row: 1),
      (x: 136.0, row: 0),
    ]);
  });

  test('a label at the right end stays on the chart', () {
    expect(
      placeLabels([(centre: 398, width: 40)], left: 0, right: 400).single.x,
      360,
    );
  });
}
