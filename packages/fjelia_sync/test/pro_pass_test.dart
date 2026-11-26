import 'package:fjelia_sync/fjelia_sync.dart';
import 'package:test/test.dart';

/// Made by fjelia-service's own code (push-server/pro.py `pro_pass`) with a
/// throwaway key, so the two sides are checked against each other. Never a
/// pass from the real key: anyone could use it.
const servicePass =
    'eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJmamVsaWEiLCJhdWQiOiJmam'
    'VsaWEtY29tcHV0ZXIiLCJzdWIiOiJmZTY3NWZlN2FhZWU4MzBiNmZlZDA5YjYiLCJpYXQiOj'
    'E3MDAwMDAwMDAsImV4cCI6NDEwMjQ0NDgwMH0.rf91f-1YMyvusghqTtkMKrTOuCXMvKd_fD'
    'Z4Ge5eGhFl54u_OLDJXIWMsNsz8MWIqNW4-z5IP0Hbhzgeqg5cjQ';
const throwawayKey = '''-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE/CsLN3McYw4gB0UZdP3BUcymV66g
RM2VqE2JHB10eVU1zC3hLM4j0a2EF8enO8ZEYGURKccvTz407PPN0G6CKA==
-----END PUBLIC KEY-----''';

void main() {
  test('a pass from the service is checked offline', () {
    expect(
      verifyProPass(servicePass, publicKeyPem: throwawayKey),
      DateTime.utc(2100),
    );
  });

  test('a changed, ended or foreign pass gives no Pro', () {
    // Signed by another key: the real one built into the app.
    expect(verifyProPass(servicePass), isNull);
    // One letter of the claims changed.
    final parts = servicePass.split('.');
    final forged = '${parts[0]}.${parts[1].replaceFirst('e', 'f')}.${parts[2]}';
    expect(verifyProPass(forged, publicKeyPem: throwawayKey), isNull);
    // After it ended.
    expect(
      verifyProPass(
        servicePass,
        publicKeyPem: throwawayKey,
        now: DateTime.utc(2100, 1, 2),
      ),
      isNull,
    );
    expect(verifyProPass('not a pass'), isNull);
  });
}
