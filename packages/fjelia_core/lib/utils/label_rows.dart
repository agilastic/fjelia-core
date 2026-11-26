import 'dart:math' as math;

/// Places labels, sorted left to right, over a chart in [rows] rows: each
/// centred on its point where it fits, in the first row where it does; when
/// no row is free, in the row free soonest, moved right of the label
/// before it. Every label stays between [left] and [right]. Returns the left
/// edge and row of each, in the order given.
List<({double x, int row})> placeLabels(
  List<({double centre, double width})> labels, {
  required double left,
  required double right,
  double gap = 6,
  int rows = 2,
}) {
  final ends = List<double>.filled(rows, left);
  return [
    for (final l in labels)
      () {
        final want = (l.centre - l.width / 2).clamp(
          left,
          math.max(left, right - l.width),
        );
        var row = ends.indexWhere((e) => e <= want);
        if (row < 0) {
          row = 0;
          for (var r = 1; r < rows; r++) {
            if (ends[r] < ends[row]) row = r;
          }
        }
        final x = math.max(want, ends[row]).toDouble();
        ends[row] = x + l.width + gap;
        return (x: x, row: row);
      }(),
  ];
}
