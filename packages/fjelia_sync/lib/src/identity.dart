import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// Where an app keeps secrets: the keychain or keystore through its secure
/// storage plugin. Never the database, which a backup copies to another
/// device.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// This device as other devices know it: a permanent id and a self-signed
/// certificate whose fingerprint they pin when pairing.
class DeviceIdentity {
  DeviceIdentity._(this.deviceId, this.certificatePem, this.privateKeyPem)
    : fingerprint = fingerprintOfDer(_pemBody(certificatePem));

  static const _id = 'fjelia.sync.device_id';
  static const _cert = 'fjelia.sync.certificate';
  static const _key = 'fjelia.sync.private_key';

  final String deviceId;
  final String certificatePem;
  final String privateKeyPem;

  /// SHA-256 of the certificate, lowercase hex.
  final String fingerprint;

  /// The identity kept in [store], created on first use.
  static Future<DeviceIdentity> loadOrCreate(SecretStore store) async {
    final id = await store.read(_id);
    final cert = await store.read(_cert);
    final key = await store.read(_key);
    if (id != null && cert != null && key != null) {
      return DeviceIdentity._(id, cert, key);
    }
    final created = generate();
    await store.write(_key, created.privateKeyPem);
    await store.write(_cert, created.certificatePem);
    await store.write(_id, created.deviceId);
    return created;
  }

  /// A new identity with a P-256 key, valid for ten years.
  static DeviceIdentity generate() {
    final id = randomToken(16);
    final pair = CryptoUtils.generateEcKeyPair();
    final private = pair.privateKey as ECPrivateKey;
    final public = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'Fjelia $id'},
      private,
      public,
    );
    final cert = X509Utils.generateSelfSignedCertificate(private, csr, 3650);
    return DeviceIdentity._(
      id,
      cert,
      CryptoUtils.encodeEcPrivateKeyToPem(private),
    );
  }

  /// The TLS context this device serves with.
  SecurityContext serverContext() => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));

  static Uint8List _pemBody(String pem) => base64.decode(
    pem
        .split('\n')
        .where((l) => !l.startsWith('-----'))
        .join()
        .replaceAll(RegExp(r'\s'), ''),
  );
}

String fingerprintOfDer(List<int> der) => sha256.convert(der).toString();

String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// [bytes] random bytes as URL-safe text.
String randomToken(int bytes) {
  final random = Random.secure();
  return base64Url
      .encode([for (var i = 0; i < bytes; i++) random.nextInt(256)])
      .replaceAll('=', '');
}
