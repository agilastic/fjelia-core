import 'package:fjelia_core/models/plan_views.dart';
import 'package:fjelia_core/services/activity_coach_context.dart';
import 'package:test/test.dart';

class _Activity implements ActivityView {
  _Activity(this.activityId, this.startDate, {this.movingDurationSeconds});
  @override
  final String activityId;
  @override
  final DateTime startDate;
  @override
  final int? movingDurationSeconds;
  @override
  String get name => 'Hike';
  @override
  String get type => 'hiking';
  @override
  int get durationSeconds => 3600;
  @override
  double? get distanceMeters => 5000;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('an activity with distance but no moving time has no pace', () {
    final hike = _Activity('a', DateTime(2026, 11, 20));
    final stopped = _Activity(
      'b',
      DateTime(2026, 11, 18),
      movingDurationSeconds: 0,
    );
    final text = ActivityCoachContext.buildFrom(hike, [hike, stopped]);
    expect(text, contains('Sport:hike,Min:60,Km:5'));
    expect(text, contains('Pace:12:00/km'));
  });
}
