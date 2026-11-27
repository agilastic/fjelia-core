import 'dart:convert';

import 'package:fjelia_core/services/activity_metrics.dart';
import 'package:fjelia_core/services/activity_series.dart';
import 'package:test/test.dart';

List<double> repeat(double v, int n) => List.filled(n, v);

void main() {
  test('samples become one value per second; long pauses are gaps', () {
    final t0 = DateTime.utc(2026, 11, 27, 8).millisecondsSinceEpoch;
    final json = jsonEncode([
      {'t': t0, 'w': 200, 'hr': 120},
      {'t': t0 + 5000, 'w': 210, 'hr': 121},
      {'t': t0 + 65000, 'hr': 125}, // a minute's pause; no power
      {'t': t0 + 70000, 'w': 220, 'hr': 126},
      {'t': t0 + 71000, 'w': 220},
    ]);
    final s = ActivitySeries.fromMetrics(json);
    expect(s.power.take(6), [200, 200, 200, 200, 200, 210]);
    // Across the pause power counts as zero, heart rate as missing.
    expect(s.power[30], 0);
    expect(s.heartRate[30].isNaN, isTrue);
    expect(s.heartRate.length, 70);
    expect(ActivitySeries.fromMetrics('not json').length, 0);
  });

  test('normalized power of a steady ride is its power', () {
    expect(normalizedPower(repeat(200, 600)), closeTo(200, .001));
    final surges = [
      for (var i = 0; i < 1200; i++) i % 120 < 60 ? 300.0 : 100.0,
    ];
    expect(normalizedPower(surges)!, greaterThan(200));
  });

  test('efficiency factor and decoupling of a steady ride', () {
    final s = ActivitySeries.of(
      power: repeat(200, 3600),
      heartRate: [...repeat(140, 2100), ...repeat(150, 1500)],
    );
    final e = aerobicEfficiency(s)!;
    expect(e.byPower, isTrue);
    // Warm-up left out: halves are 10–35 and 35–60 minutes.
    expect(
      e.decouplingPercent,
      closeTo((200 / 140 - 200 / 150) / (200 / 140) * 100, 0.01),
    );
    // A run by speed: stops do not count.
    final run = ActivitySeries.of(
      speed: [for (var i = 0; i < 1800; i++) i % 300 == 0 ? 0.0 : 3.0],
      heartRate: repeat(150, 1800),
    );
    final r = aerobicEfficiency(run)!;
    expect(r.byPower, isFalse);
    expect(r.efficiencyFactor, closeTo(180 / 150, .001));
    expect(r.decouplingPercent, closeTo(0, .001));
    expect(
      aerobicEfficiency(
        ActivitySeries.of(power: repeat(200, 600), heartRate: repeat(140, 600)),
      ),
      isNull,
    );
  });

  test('critical power and W′ from the best efforts', () {
    final curve = {
      for (final t in [60, 180, 300, 600, 1200, 3600]) t: 250 + 20000 / t,
    };
    final m = fitCriticalPower(curve)!;
    expect(m.cp, closeTo(250, .01));
    expect(m.wPrime, closeTo(20000, 1));
    expect(m.powerFor(300), closeTo(250 + 20000 / 300, .1));
    expect(fitCriticalPower({60: 400, 300: 300}), isNull);
  });

  test('W′ balance falls above CP and comes back below it', () {
    const m = CriticalPower(250, 20000);
    final bal = wPrimeBalance([...repeat(300, 200), ...repeat(100, 600)], m);
    expect(bal[199], closeTo(10000, .01));
    expect(bal.last, greaterThan(19000));
    expect(bal.last, lessThanOrEqualTo(20000));
  });

  test('intervals are found where they were ridden', () {
    final ride = [
      ...repeat(150, 600),
      for (var r = 0; r < 6; r++) ...[...repeat(320, 180), ...repeat(140, 120)],
      ...repeat(150, 300),
    ];
    final found = detectIntervals(ride, heartRate: repeat(150, ride.length));
    expect(found, hasLength(6));
    for (final (i, x) in found.indexed) {
      expect(x.seconds, inInclusiveRange(170, 190));
      expect((x.start - (600 + i * 300)).abs(), lessThanOrEqualTo(6));
      expect(x.mean, greaterThan(300));
      expect(x.heartRate, 150);
    }
    expect(detectIntervals(repeat(200, 3600)), isEmpty);
  });
}
