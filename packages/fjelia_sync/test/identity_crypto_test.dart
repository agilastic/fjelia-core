import 'dart:convert';

import 'package:fjelia_sync/src/identity/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('a key signs; only its own signature over the same bytes verifies', () {
    final a = KeyPair.generate(), b = KeyPair.generate();
    final data = utf8.encode('{"v":1}');
    final sig = a.sign(data);
    expect(sig, hasLength(64));
    expect(verify(a.spki, data, sig), isTrue);
    expect(verify(b.spki, data, sig), isFalse);
    expect(verify(a.spki, utf8.encode('{"v":2}'), sig), isFalse);
    // Stored and read back as its scalar.
    expect(KeyPair.fromScalar(a.scalarHex).id, a.id);
    expect(a.id, hasLength(32));
  });

  test('a data key wrapped for a device opens only with that device', () {
    final device = KeyPair.generate(), other = KeyPair.generate();
    final ephemeral = KeyPair.generate();
    final wrapKey = hkdf(
      sharedSecret(ephemeral.private, device.spki),
      device.id,
      'fjelia wrap v1',
    );
    final dataKey = randomBytes(32), nonce = randomBytes(12);
    final wrapped = seal(wrapKey, nonce, dataKey, utf8.encode('sender'));
    final again = hkdf(
      sharedSecret(device.private, ephemeral.spki),
      device.id,
      'fjelia wrap v1',
    );
    expect(open(again, nonce, wrapped, utf8.encode('sender')), dataKey);
    final wrong = hkdf(
      sharedSecret(other.private, ephemeral.spki),
      device.id,
      'fjelia wrap v1',
    );
    expect(
      () => open(wrong, nonce, wrapped, utf8.encode('sender')),
      throwsA(anything),
    );
  });

  test('recovery codes survive the way people type them', () {
    final bytes = randomBytes(20);
    final code = recoveryCode(bytes);
    expect(
      code,
      matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}$')),
    );
    expect(recoveryBytes(code.toLowerCase().replaceAll('-', ' ')), bytes);
    expect(recoveryBytes('too short'), isNull);
  });

  test('canonical JSON refuses fractions in signed data', () {
    expect(
      canonicalJson({
        'b': 1,
        'a': [true, null],
      }),
      '{"a":[true,null],"b":1}',
    );
    expect(() => canonicalJson({'x': 1.5}), throwsArgumentError);
  });
}
