import 'package:fjelia_core/services/readiness.dart';
import 'package:test/test.dart';

void main() {
  final day = DateTime(2026, 9, 10);

  ReadinessHrvDay hrv(int daysBefore, {double? value, int? restingHr}) =>
      ReadinessHrvDay(
        date: day.subtract(Duration(days: daysBefore)),
        hrvLastNight: value,
        restingHeartRate: restingHr,
      );

  ReadinessEvaluation evaluate({
    List<ReadinessHrvDay> hrv7 = const [],
    ReadinessHrvDay? today,
    double? tsb,
    double? composite,
    TrainingSeverity severity = TrainingSeverity.normal,
  }) => Readiness.evaluate(
    hrv7: hrv7,
    hrvToday: today,
    sleep: null,
    wellness: null,
    sleepHistory: const [],
    tsb: tsb,
    composite: composite,
    severity: TrainingSeverityResult(severity),
  );

  group('formBefore', () {
    test('a past date does not see the load that came after it', () {
      final load = {
        for (var d = 0; d < 20; d++) DateTime(2026, 8, 1 + d): 40.0,
      };
      final before = Readiness.formBefore(load, DateTime(2026, 8, 21));
      load.addAll({
        for (var d = 0; d < 30; d++) DateTime(2026, 8, 21 + d): 300.0,
      });
      expect(Readiness.formBefore(load, DateTime(2026, 8, 21)), before);
      expect(
        Readiness.formBefore(load, DateTime(2026, 9, 15)),
        lessThan(before!),
      );
    });

    test('no load means no form', () {
      expect(Readiness.formBefore(const {}, day), isNull);
    });
  });

  group('evaluate', () {
    test('an HRV more than 8 % under the weekly mean raises one flag', () {
      final e = evaluate(
        hrv7: [for (var i = 1; i <= 7; i++) hrv(i, value: 60)],
        today: hrv(0, value: 54),
      );
      expect(e.result.hrvLow, isTrue);
      expect(e.result.flagCount, 1);
      expect(e.result.level, ReadinessLevel.yellow);
      expect(e.hrvDrop, closeTo(0.1, 1e-9));
    });

    test('one flag with a strong composite stays green', () {
      final e = evaluate(
        hrv7: [for (var i = 1; i <= 7; i++) hrv(i, value: 60)],
        today: hrv(0, value: 54),
        composite: 7.5,
      );
      expect(e.result.level, ReadinessLevel.green);
    });

    test('a rest severity turns the day red without flags', () {
      final e = evaluate(severity: TrainingSeverity.rest);
      expect(e.result.flagCount, 0);
      expect(e.result.level, ReadinessLevel.red);
    });

    test('deep negative form counts as fatigue', () {
      final e = evaluate(tsb: -25);
      expect(e.result.fatigue, isTrue);
      expect(e.result.adaptationReason, 'accumulated fatigue');
    });
  });

  group('severity', () {
    test('follows the composite thresholds', () {
      expect(
        Readiness.severity(composite: 3.0, tsb: null).severity,
        TrainingSeverity.rest,
      );
      expect(
        Readiness.severity(composite: 5.0, tsb: null).severity,
        TrainingSeverity.tierDown,
      );
      expect(
        Readiness.severity(composite: 6.0, tsb: 0).severity,
        TrainingSeverity.normal,
      );
    });

    test('falls back to form when the composite is missing', () {
      expect(
        Readiness.severity(composite: null, tsb: -21).severity,
        TrainingSeverity.tierDown,
      );
      expect(Readiness.severity(composite: null, tsb: 0).reason, isNull);
    });
  });

  test('the composite needs 40 % of the weight', () {
    expect(
      Readiness.compositeScore(
        history: const [],
        today: hrv(0, value: 60),
        sleep: null,
        sleepHistory: const [],
        wellness: null,
      ),
      isNull,
    );
  });
}
