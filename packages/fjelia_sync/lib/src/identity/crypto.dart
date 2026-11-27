/// The cryptography of docs/identity-and-sync-security.md, version 1: P-256
/// keys, ECDSA with SHA-256 written as 64 bytes r||s, ECDH with HKDF-SHA256
/// and AES-256-GCM, canonical JSON, the recovery code. Checked against the
/// test vectors made by an independent implementation
/// (fjelia_core/test/vectors/identity_v1.json).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:pointycastle/export.dart';

// P-256 under the name basic_utils writes into SPKI (secp256r1 is the same curve).
final _curve = ECCurve_prime256v1();
final _random = () {
  final r = Random.secure();
  return FortunaRandom()..seed(
    KeyParameter(
      Uint8List.fromList([for (var i = 0; i < 32; i++) r.nextInt(256)]),
    ),
  );
}();

/// Random bytes from the system's secure source.
Uint8List randomBytes(int n) => _random.nextBytes(n);

/// A P-256 key pair. [private] is the scalar; [spki] the public key as
/// SubjectPublicKeyInfo DER, the form every format uses.
class KeyPair {
  KeyPair(this.private) : public = ECPublicKey(_curve.G * private.d, _curve);

  /// A new key from the secure source.
  factory KeyPair.generate() {
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), _random));
    return KeyPair(generator.generateKeyPair().privateKey as ECPrivateKey);
  }

  /// From the scalar as 64 hex digits, as [scalarHex] writes it.
  factory KeyPair.fromScalar(String hex) =>
      KeyPair(ECPrivateKey(BigInt.parse(hex, radix: 16), _curve));

  final ECPrivateKey private;
  final ECPublicKey public;

  String get scalarHex => private.d!.toRadixString(16).padLeft(64, '0');
  Uint8List get spki => spkiOf(public);

  /// `sha256(spki)` as hex, first 32 characters: a device or person id.
  String get id => idOf(spki);

  /// ECDSA with SHA-256 (deterministic, RFC 6979) over [data], as r||s.
  Uint8List sign(List<int> data) {
    final s = CryptoUtils.ecSign(
      private,
      Uint8List.fromList(data),
      algorithmName: 'SHA-256/DET-ECDSA',
    );
    return Uint8List.fromList([..._fixed(s.r), ..._fixed(s.s)]);
  }
}

Uint8List spkiOf(ECPublicKey key) =>
    _pemBody(CryptoUtils.encodeEcPublicKeyToPem(key));

ECPublicKey publicFromSpki(List<int> spki) =>
    CryptoUtils.ecPublicKeyFromDerBytes(Uint8List.fromList(spki));

String idOf(List<int> spki) =>
    hash.sha256.convert(spki).toString().substring(0, 32);

/// Whether [signature] (r||s) by the key [spki] covers [data].
bool verify(List<int> spki, List<int> data, List<int> signature) {
  if (signature.length != 64) return false;
  try {
    return CryptoUtils.ecVerify(
      publicFromSpki(spki),
      Uint8List.fromList(data),
      ECSignature(
        _number(signature.sublist(0, 32)),
        _number(signature.sublist(32)),
      ),
      algorithm: 'SHA-256/ECDSA',
    );
  } on Object {
    return false;
  }
}

/// HKDF-SHA256 to 32 bytes.
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

/// AES-256-GCM with a 128-bit tag appended; [aad] is authenticated, not
/// encrypted. Opening something changed throws.
Uint8List seal(
  List<int> key,
  List<int> nonce,
  List<int> data, [
  List<int>? aad,
]) => _gcm(true, key, nonce, data, aad);
Uint8List open(
  List<int> key,
  List<int> nonce,
  List<int> data, [
  List<int>? aad,
]) => _gcm(false, key, nonce, data, aad);

Uint8List _gcm(
  bool encrypt,
  List<int> key,
  List<int> nonce,
  List<int> data,
  List<int>? aad,
) {
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

/// The ECDH shared secret of [own] and the public key [spki], 32 bytes.
Uint8List sharedSecret(ECPrivateKey own, List<int> spki) {
  final agreement = ECDHBasicAgreement()..init(own);
  return _fixed(agreement.calculateAgreement(publicFromSpki(spki)));
}

/// JSON with keys sorted by UTF-16 code units and no white space (section
/// 10): what is signed and authenticated. Numbers must be integers.
String canonicalJson(Object? value) => switch (value) {
  final Map m =>
    '{${([...m.keys.cast<String>()]..sort()).map((k) => '${jsonEncode(k)}:${canonicalJson(m[k])}').join(',')}}',
  final List l => '[${l.map(canonicalJson).join(',')}]',
  final double d when d != d.roundToDouble() => throw ArgumentError.value(
    d,
    'value',
    'no fractions in signed data',
  ),
  final double d => d.round().toString(),
  _ => jsonEncode(value),
};

const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// 20 bytes as 32 Crockford base32 characters in groups of four.
String recoveryCode(List<int> bytes) {
  final bits = bytes.map((b) => b.toRadixString(2).padLeft(8, '0')).join();
  final chars = [
    for (var i = 0; i + 5 <= bits.length; i += 5)
      _crockford[int.parse(bits.substring(i, i + 5), radix: 2)],
  ].join();
  return [for (var i = 0; i < chars.length; i += 4) chars.substring(i, i + 4)]
      .join('-');
}

/// The bytes of a recovery code as typed: dashes, spaces and case do not
/// matter, and O, I and L read as 0, 1 and 1. Null for a code that is not
/// 32 characters of the alphabet.
Uint8List? recoveryBytes(String code) {
  final clean = code
      .toUpperCase()
      .replaceAll(RegExp(r'[\s-]'), '')
      .replaceAll('O', '0')
      .replaceAll(RegExp('[IL]'), '1');
  if (clean.length != 32 ||
      clean.split('').any((c) => !_crockford.contains(c))) {
    return null;
  }
  final bits = clean
      .split('')
      .map((c) => _crockford.indexOf(c).toRadixString(2).padLeft(5, '0'))
      .join();
  return Uint8List.fromList([
    for (var i = 0; i + 8 <= bits.length; i += 8)
      int.parse(bits.substring(i, i + 8), radix: 2),
  ]);
}

Uint8List _pemBody(String pem) => base64.decode(
  pem.split('\n').where((l) => l.isNotEmpty && !l.startsWith('-----')).join(),
);

BigInt _number(List<int> bytes) => BigInt.parse(
  bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  radix: 16,
);

Uint8List _fixed(BigInt n) {
  final hex = n.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList([
    for (var i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
