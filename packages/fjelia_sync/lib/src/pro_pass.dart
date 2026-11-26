import 'dart:convert';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';

/// The public half of the key fjelia-service signs FjeliaPro passes with
/// (PRO_PASS_KEY_PATH there). A new key needs a new release.
const proPassPublicKey = '''-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEA2POdK7Ct4HM8uNJ0Pp26kowkp0F
pRnqvnR8/KKBObgYf9ZkmArdAStc0mRHDBRQZcdfFeazJBr6jubWktnFAQ==
-----END PUBLIC KEY-----''';

/// When the FjeliaPro of [pass] ends, or null when it is not a pass signed
/// by fjelia-service for computers, or has ended by [now]. The phone gets
/// the pass with its subscription and hands it to its paired computers,
/// which check it here, offline.
DateTime? verifyProPass(
  String pass, {
  DateTime? now,
  String publicKeyPem = proPassPublicKey,
}) {
  final parts = pass.split('.');
  if (parts.length != 3) return null;
  try {
    final header = _json(parts[0]);
    final claims = _json(parts[1]);
    if (header['alg'] != 'ES256') return null;
    if (claims['iss'] != 'fjelia' || claims['aud'] != 'fjelia-computer') {
      return null;
    }
    final signature = _bytes(parts[2]);
    if (signature.length != 64) return null;
    BigInt number(List<int> b) => BigInt.parse(
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );
    final ok = CryptoUtils.ecVerify(
      CryptoUtils.ecPublicKeyFromPem(publicKeyPem),
      Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}')),
      ECSignature(
        number(signature.sublist(0, 32)),
        number(signature.sublist(32)),
      ),
      algorithm: 'SHA-256/ECDSA',
    );
    if (!ok) return null;
    final exp = claims['exp'];
    if (exp is! int) return null;
    final ends = DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    return ends.isAfter(now ?? DateTime.now()) ? ends : null;
  } on Object {
    return null;
  }
}

Map<String, Object?> _json(String part) =>
    (jsonDecode(utf8.decode(_bytes(part))) as Map).cast<String, Object?>();

List<int> _bytes(String part) => base64Url.decode(base64Url.normalize(part));
