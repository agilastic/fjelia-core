import 'package:fjelia_core/services/lactate_test.dart';
import 'package:test/test.dart';

void main() {
  // A typical bike step test: 50 W steps, lactate rising slowly, then fast.
  const steps = [
    LactateStep(intensity: 100, lactate: 1.1, heartRate: 112),
    LactateStep(intensity: 150, lactate: 1.0, heartRate: 124),
    LactateStep(intensity: 200, lactate: 1.3, heartRate: 137),
    LactateStep(intensity: 250, lactate: 2.0, heartRate: 151),
    LactateStep(intensity: 300, lactate: 3.6, heartRate: 166),
    LactateStep(intensity: 350, lactate: 7.2, heartRate: 180),
  ];

  test('LT1 at the first rise of 0.5 above baseline, LT2 by modified Dmax', () {
    final r = analyseLactate(steps)!;
    expect(r.baseline, 1.0);
    // 1.5 mmol/l lies between 200 W (1.3) and 250 W (2.0).
    expect(r.lt1!.intensity, closeTo(214, 1));
    expect(r.lt1!.heartRate, closeTo(141, 1));
    expect(r.lt2Method, Lt2Method.modifiedDmax);
    expect(r.lt2!.intensity, inInclusiveRange(270, 315));
    expect(r.lt2!.heartRate, greaterThan(r.lt1!.heartRate!));
  });

  test('three steps fall back to 4 mmol/l; fewer give nothing', () {
    final r = analyseLactate(const [
      LactateStep(intensity: 2.8, lactate: 1.2),
      LactateStep(intensity: 3.6, lactate: 2.4),
      LactateStep(intensity: 4.4, lactate: 6.0),
    ])!;
    expect(r.lt2Method, Lt2Method.fourMmol);
    expect(r.lt2!.intensity, closeTo(3.96, 0.01));
    expect(analyseLactate(steps.take(2).toList()), isNull);
  });

  test('steps survive JSON', () {
    final back = LactateStep.fromJson(steps.first.toJson())!;
    expect(back.intensity, 100);
    expect(back.heartRate, 112);
    expect(LactateStep.fromJson({'intensity': 'x'}), isNull);
  });
}
