import 'dart:convert';

import 'package:fjelia_core/services/best_efforts.dart';
import 'package:fjelia_core/services/training_form.dart';
import 'package:test/test.dart';

void main() {
  test('the power curve holds the best average per duration', () {
    final start = DateTime.utc(2026, 5, 1, 7).millisecondsSinceEpoch;
    // 10 min at 200 W, 5 min at 300 W, 10 min at 150 W, one sample a second.
    final watts = [
      for (var i = 0; i < 600; i++) 200,
      for (var i = 0; i < 300; i++) 300,
      for (var i = 0; i < 600; i++) 150,
    ];
    final json = jsonEncode([
      for (var i = 0; i < watts.length; i++)
        {'t': start + i * 1000, 'w': watts[i]},
    ]);
    final curve = meanMaxPower(json, [5, 300, 600, 3600]);
    expect(curve[5], 300);
    expect(curve[300], 300);
    expect(curve[600], closeTo(250, 0.5)); // 5 min at 300 + 5 min at 200
    expect(curve.containsKey(3600), isFalse);
    expect(meanMaxPower('nope'), isEmpty);
  });

  test('a long stop counts as zero power', () {
    final start = DateTime.utc(2026, 5, 1, 7).millisecondsSinceEpoch;
    final json = jsonEncode([
      {'t': start, 'w': 300},
      {'t': start + 60000, 'w': 300}, // a minute without samples
      {'t': start + 61000, 'w': 300},
    ]);
    expect(meanMaxPower(json, [30])[30], lessThan(20));
  });

  test('the forecast continues the chart with the planned load', () {
    final series = buildTrainingFormSeries(
      dailyLoads: {for (var i = 0; i < 60; i++) DateTime(2026, 9, 1 + i): 60},
      through: DateTime(2026, 10, 30),
    );
    final last = series.last;
    final rest = projectTrainingForm(last, days: 10);
    expect(rest, hasLength(10));
    expect(rest.first.date, DateTime(2026, 10, 31));
    expect(rest.last.tsb, greaterThan(last.tsb)); // rest freshens up
    final train = projectTrainingForm(
      last,
      planned: {for (var i = 1; i <= 10; i++) DateTime(2026, 10, 30 + i): 120},
      days: 10,
    );
    expect(train.last.ctl, greaterThan(rest.last.ctl));
    expect(train.last.tsb, lessThan(rest.last.tsb));
  });
}
