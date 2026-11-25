import 'package:fjelia_core/services/training_form.dart';
import 'package:test/test.dart';

void main() {
  test('form status bands', () {
    expect(FormStatus.of(null), FormStatus.noHistory);
    expect(FormStatus.of(16), FormStatus.fresh);
    expect(FormStatus.of(15), FormStatus.optimal);
    expect(FormStatus.of(6), FormStatus.optimal);
    expect(FormStatus.of(5), FormStatus.neutral);
    expect(FormStatus.of(-9), FormStatus.neutral);
    expect(FormStatus.of(-10), FormStatus.tired);
    expect(FormStatus.of(-20), FormStatus.veryFatigued);
    expect(FormStatus.of(6).tone, FormTone.good);
    expect(FormStatus.of(0).tone, FormTone.caution);
    expect(FormStatus.of(-15).tone, FormTone.strained);
  });
}
