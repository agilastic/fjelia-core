import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';
import 'package:fjelia_sync/src/identity/crypto.dart'
    show canonicalJson, recoveryBytes, recoveryCode;
import 'package:test/test.dart';

/// docs/identity-and-sync-security.md, checked against vectors made by an
/// independent implementation (tools/make_identity_vectors.py): the
/// primitives Fjelia's Dart code has (pointycastle, crypto) give the same
/// bytes. Phase 0 only: no Fjelia code uses these formats yet.
void main() {
  final v = jsonDecode(
    File('../fjelia_core/test/vectors/identity_v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  Uint8List hex(String s) => Uint8List.fromList([
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);
  String toHex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  final curve = ECCurve_secp256r1();
  ECPrivateKey private(String name) => ECPrivateKey(
    BigInt.parse(v['keys'][name]['private'] as String, radix: 16),
    curve,
  );
  ECPublicKey publicOf(String name) => CryptoUtils.ecPublicKeyFromDerBytes(
    base64Decode(v['keys'][name]['spki'] as String),
  );

  Uint8List hkdf(List<int> secret, String salt, String info) {
    final d = HKDFKeyDerivator(SHA256Digest())
      ..init(
        HkdfParameters(
          Uint8List.fromList(secret),
          32,
          Uint8List.fromList(utf8.encode(salt)),
          Uint8List.fromList(utf8.encode(info)),
        ),
      );
    final out = Uint8List(32);
    d.deriveKey(null, 0, out, 0);
    return out;
  }

  Uint8List gcm(
    bool encrypt,
    List<int> key,
    List<int> nonce,
    List<int> data, [
    List<int>? aad,
  ]) {
    final c = GCMBlockCipher(AESEngine())
      ..init(
        encrypt,
        AEADParameters(
          KeyParameter(Uint8List.fromList(key)),
          128,
          Uint8List.fromList(nonce),
          Uint8List.fromList(aad ?? const []),
        ),
      );
    return c.process(Uint8List.fromList(data));
  }

  test('keys: ids are the hash of the public key', () {
    for (final name in (v['keys'] as Map).keys) {
      final k = v['keys'][name] as Map;
      final der = base64Decode(k['spki'] as String);
      expect(toHex(crypto.sha256.convert(der).bytes).substring(0, 32), k['id']);
      // The private scalar gives that public key.
      final q = curve.G * private(name as String).d;
      expect(q, publicOf(name).Q);
    }
  });

  test('canonical JSON sorts keys by UTF-16 code units', () {
    final c = v['canonical_json'] as Map;
    expect(canonicalJson(c['input']), c['output']);
  });

  test(
    'a device list signed by the person key is accepted, a changed one not',
    () {
      final d = v['device_list'] as Map;
      final text = canonicalJson(d['list']);
      expect(text, d['canonical']);
      bool verify(String s) {
        final sig = base64Decode(d['sig'] as String);
        return CryptoUtils.ecVerify(
          publicOf('person'),
          Uint8List.fromList(utf8.encode(s)),
          ECSignature(
            BigInt.parse(toHex(sig.sublist(0, 32)), radix: 16),
            BigInt.parse(toHex(sig.sublist(32)), radix: 16),
          ),
          algorithm: 'SHA-256/ECDSA',
        );
      }

      expect(verify(text), isTrue);
      expect(verify(text.replaceFirst('"version":1', '"version":2')), isFalse);
    },
  );

  test('a data key is wrapped for a device: ECDH, HKDF, AES-GCM', () {
    final w = v['key_wrap'] as Map;
    final agreement = ECDHBasicAgreement()..init(private('ephemeral'));
    final shared = agreement.calculateAgreement(publicOf('recipient_enc'));
    final secret = hex(shared.toRadixString(16).padLeft(64, '0'));
    expect(toHex(secret), w['shared_secret']);
    final wrapKey = hkdf(
      secret,
      w['recipient_device'] as String,
      'fjelia wrap v1',
    );
    expect(toHex(wrapKey), w['wrap_key']);
    final wrapped = gcm(
      true,
      wrapKey,
      hex(w['nonce'] as String),
      hex(w['data_key'] as String),
      utf8.encode(w['sender_device'] as String),
    );
    expect(toHex(wrapped), w['wrapped']);
    // And back, as the recipient does it with its own key.
    final back = ECDHBasicAgreement()..init(private('recipient_enc'));
    expect(back.calculateAgreement(publicOf('ephemeral')), shared);
  });

  test('an envelope body is AES-256-GCM over the header', () {
    final b = v['body'] as Map;
    final aad = canonicalJson(b['header']);
    expect(aad, b['aad']);
    expect(
      toHex(
        gcm(
          true,
          hex(b['data_key'] as String),
          hex(b['nonce'] as String),
          utf8.encode(b['plaintext'] as String),
          utf8.encode(aad),
        ),
      ),
      b['ciphertext'],
    );
    // A changed header does not open.
    expect(
      () => gcm(
        false,
        hex(b['data_key'] as String),
        hex(b['nonce'] as String),
        hex(b['ciphertext'] as String),
        utf8.encode(aad.replaceFirst('1234', '1235')),
      ),
      throwsA(anything),
    );
  });

  test('the recovery code opens the recovery blob', () {
    final r = v['recovery'] as Map;
    final bytes = recoveryBytes(r['code'] as String)!;
    expect(toHex(bytes), r['code_bytes']);
    // And written back the same way.
    expect(recoveryCode(bytes), r['code']);
    final key = hkdf(bytes, r['person'] as String, 'fjelia recovery v1');
    expect(toHex(key), r['key']);
    expect(
      toHex(
        gcm(false, key, hex(r['nonce'] as String), hex(r['blob'] as String)),
      ),
      r['person_key_pkcs8'],
    );
  });

  test('both screens show the same six-digit code', () {
    final s = v['six_digit_code'] as Map;
    final ids = [s['device_a'] as String, s['device_b'] as String]..sort();
    final mac = crypto.Hmac(
      crypto.sha256,
      hex(s['token'] as String),
    ).convert(utf8.encode(ids.join())).bytes;
    final n = ByteData.sublistView(Uint8List.fromList(mac), 0, 4).getUint32(0);
    expect((n % 1000000).toString().padLeft(6, '0'), s['code']);
  });
}
