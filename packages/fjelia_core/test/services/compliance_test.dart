import 'package:fjelia_core/services/compliance.dart';
import 'package:test/test.dart';

void main() {
  test('a session reads as the phone scored it', () {
    Compliance of(String status, {bool past = true, String? verdict}) =>
        Compliance.ofSession(status: status, isPast: past, verdict: verdict);
    expect(of('completed', verdict: 'on_target'), Compliance.onTarget);
    expect(of('completed'), Compliance.onTarget);
    expect(of('completed', verdict: 'under'), Compliance.partly);
    expect(of('completed', verdict: 'over'), Compliance.partly);
    expect(of('completed', verdict: 'off_plan'), Compliance.offPlan);
    expect(of('skipped'), Compliance.missed);
    expect(of('planned'), Compliance.missed);
    expect(of('adapted', past: false), Compliance.upcoming);
  });
}
