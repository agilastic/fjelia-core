/// This device's person: the person key, the device's own signing and
/// encryption keys, the person's device list, and the recovery code
/// (docs/identity-and-sync-security.md, sections 4, 6.1 and 9).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../identity.dart' show SecretStore;
import 'crypto.dart';
import 'device_list.dart';

class PersonIdentity {
  PersonIdentity._(this.person, this.deviceSign, this.deviceEnc, this.list);

  static const _person = 'fjelia.identity.person_key';
  static const _sign = 'fjelia.identity.device_sign_key';
  static const _enc = 'fjelia.identity.device_enc_key';
  static const _list = 'fjelia.identity.device_list';

  final KeyPair person, deviceSign, deviceEnc;
  DeviceList list;

  String get personId => person.id;
  String get deviceId => deviceSign.id;

  /// The identity kept in [store]; null before the first start made one.
  static Future<PersonIdentity?> load(SecretStore store) async {
    final p = await store.read(_person);
    final s = await store.read(_sign);
    final e = await store.read(_enc);
    final l = await store.read(_list);
    if (p == null || s == null || e == null || l == null) return null;
    final list = DeviceList.verified(jsonDecode(l) as Map<String, dynamic>);
    if (list == null) return null;
    return PersonIdentity._(
      KeyPair.fromScalar(p),
      KeyPair.fromScalar(s),
      KeyPair.fromScalar(e),
      list,
    );
  }

  /// The first start (6.1): new keys, the device list version 1 with this
  /// device on it, and the recovery code, to show the person once.
  static Future<({PersonIdentity identity, String recoveryCode})> create(
    SecretStore store, {
    required String deviceName,
    required String platform,
    DateTime? now,
  }) async {
    final at = isoSeconds(now ?? DateTime.now());
    final person = KeyPair.generate();
    final sign = KeyPair.generate(), enc = KeyPair.generate();
    final identity = PersonIdentity._(
      person,
      sign,
      enc,
      DeviceList(
        personKey: person.spki,
        version: 1,
        issued: at,
        devices: [
          ListedDevice(
            signKey: sign.spki,
            encKey: enc.spki,
            name: deviceName,
            platform: platform,
            added: at,
          ),
        ],
      ),
    );
    await store.write(_sign, sign.scalarHex);
    await store.write(_enc, enc.scalarHex);
    await store.write(_person, person.scalarHex);
    await identity._saveList(store);
    return (identity: identity, recoveryCode: recoveryCode(randomBytes(20)));
  }

  Future<void> _saveList(SecretStore store) =>
      store.write(_list, jsonEncode(list.signed(person)));

  /// The signed list, as devices and the relay receive it.
  Map<String, Object> get signedList => list.signed(person);

  /// Takes a newer valid list of this person (from another of their
  /// devices); false when it is not newer, or this device is not on it.
  Future<bool> takeList(SecretStore store, Map<String, dynamic> signed) async {
    final next = DeviceList.newer(list, signed);
    if (identical(next, list) || next == null) return false;
    if (next.device(deviceId) == null) return false;
    list = next;
    await _saveList(store);
    return true;
  }

  Future<void> removeDevice(SecretStore store, String id) async {
    if (id == deviceId) throw StateError('remove this device from another');
    list = list.removing(id, DateTime.now());
    await _saveList(store);
  }

  /// The person key encrypted under [code] (9): goes with every backup,
  /// and is useless without the code.
  Map<String, String> recoveryBlob(String code) {
    final bytes = recoveryBytes(code);
    if (bytes == null) throw ArgumentError('not a recovery code');
    final nonce = randomBytes(12);
    return {
      'v': '1',
      'person': personId,
      'nonce': base64.encode(nonce),
      'blob': base64.encode(
        seal(hkdf(bytes, personId, 'fjelia recovery v1'), nonce, pkcs8(person)),
      ),
    };
  }

  /// A wiped or new device (9): the person key from [blob] and [code], new
  /// device keys, and a device list that has this device on it. Null when
  /// the code does not open the blob.
  static Future<PersonIdentity?> restore(
    SecretStore store, {
    required Map<String, dynamic> blob,
    required String code,
    required String deviceName,
    required String platform,
    DeviceList? lastKnown,
    DateTime? now,
  }) async {
    final bytes = recoveryBytes(code);
    if (bytes == null) return null;
    final String scalar;
    try {
      final der = open(
        hkdf(bytes, blob['person'] as String, 'fjelia recovery v1'),
        base64.decode(blob['nonce'] as String),
        base64.decode(blob['blob'] as String),
      );
      scalar = scalarOfPkcs8(der);
    } on Object {
      return null;
    }
    final person = KeyPair.fromScalar(scalar);
    if (person.id != blob['person']) return null;
    final at = now ?? DateTime.now();
    final sign = KeyPair.generate(), enc = KeyPair.generate();
    final device = ListedDevice(
      signKey: sign.spki,
      encKey: enc.spki,
      name: deviceName,
      platform: platform,
      added: isoSeconds(at),
    );
    final base = lastKnown != null && lastKnown.person == person.id
        ? lastKnown
        : DeviceList(
            personKey: person.spki,
            version: 0,
            issued: isoSeconds(at),
            devices: const [],
          );
    final identity = PersonIdentity._(
      person,
      sign,
      enc,
      base.adding(device, at),
    );
    await store.write(_sign, sign.scalarHex);
    await store.write(_enc, enc.scalarHex);
    await store.write(_person, person.scalarHex);
    await identity._saveList(store);
    return identity;
  }
}

// PKCS#8 for a P-256 key with its public point: a fixed DER frame around
// the 32-byte scalar and the 65-byte uncompressed point.
const _pkcs8Head =
    '308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b0201010420';
const _pkcs8Mid = 'a144034200';

Uint8List pkcs8(KeyPair k) {
  final q = k.public.Q!;
  String hex32(BigInt n) => n.toRadixString(16).padLeft(64, '0');
  final hex =
      '$_pkcs8Head${k.scalarHex}${_pkcs8Mid}04'
      '${hex32(q.x!.toBigInteger()!)}${hex32(q.y!.toBigInteger()!)}';
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// The scalar inside [der] as 64 hex digits; throws for anything else.
String scalarOfPkcs8(List<int> der) {
  final hex = der.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  if (!hex.startsWith(_pkcs8Head) || hex.length < _pkcs8Head.length + 64) {
    throw const FormatException('not a P-256 PKCS#8 key');
  }
  return hex.substring(_pkcs8Head.length, _pkcs8Head.length + 64);
}
