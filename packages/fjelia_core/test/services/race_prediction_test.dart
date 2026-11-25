import 'package:fjelia_core/models/plan_views.dart';
import 'package:fjelia_core/services/race_prediction.dart';
import 'package:test/test.dart';

/// Stands for the app's database row, a subtype of [ActivityView].
class _Run implements ActivityView {
  _Run(this.distanceMeters, this.durationSeconds, this.startDate);
  @override
  final double? distanceMeters;
  @override
  final int durationSeconds;
  @override
  final DateTime startDate;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('takes a list of a subtype of ActivityView', () {
    final now = DateTime(2026, 11, 25);
    final runs = <_Run>[
      _Run(5000, 1500, now),
      _Run(10000, 2700, now),
      _Run(21100, 6000, now),
    ];
    final anchor = RacePrediction.bestRunAnchor(runs, const [], now: now);
    expect(anchor?.distM, 10000);
    expect(anchor?.timeSec, 2700);
  });
}
