import 'dart:convert';
import 'dart:io';

import 'package:fjelia_sync/fjelia_sync.dart' show SecretStore;
import 'package:fjelia_sync/src/identity/crypto.dart';
import 'package:fjelia_sync/src/identity/device_list.dart';
import 'package:fjelia_sync/src/identity/person.dart';
import 'package:test/test.dart';

class Memory implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('PKCS#8 as the independent implementation writes it', () {
    final v = jsonDecode(
      File('../fjelia_core/test/vectors/identity_v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final key = KeyPair.fromScalar(v['keys']['person']['private'] as String);
    final der = pkcs8(key);
    final hex = der.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(hex, v['recovery']['person_key_pkcs8']);
    expect(scalarOfPkcs8(der), key.scalarHex);
  });

  test(
    'first start, a second device, losing both, back with the code',
    () async {
      final mac = Memory();
      final first = await PersonIdentity.create(
        mac,
        deviceName: 'Mac',
        platform: 'macos',
      );
      final me = first.identity;
      expect((await PersonIdentity.load(mac))!.personId, me.personId);
      // Nothing readable about the code is kept.
      expect(
        mac.values.values.any((v) => v.contains(first.recoveryCode)),
        isFalse,
      );

      final blob = jsonDecode(
        jsonEncode(me.recoveryBlob(first.recoveryCode)),
      ) as Map<String, dynamic>;
      final latest = me.list;
      final phone = Memory();
      expect(
        await PersonIdentity.restore(
          phone,
          blob: blob,
          code: 'AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA',
          deviceName: 'Phone',
          platform: 'ios',
        ),
        isNull,
      );
      final back = await PersonIdentity.restore(
        phone,
        blob: blob,
        code: first.recoveryCode.toLowerCase(),
        deviceName: 'Phone',
        platform: 'ios',
        lastKnown: latest,
      );
      expect(back!.personId, me.personId);
      expect(back.list.version, 2);
      expect(back.list.devices.map((d) => d.name), ['Mac', 'Phone']);
      // The Mac takes the newer list; an old one does not go back.
      expect(await me.takeList(mac, back.signedList), isTrue);
      expect(await me.takeList(mac, latest.signed(me.person)), isFalse);
      // Removing the phone from the Mac: the phone is no longer on the list.
      await me.removeDevice(mac, back.deviceId);
      expect(me.list.device(back.deviceId), isNull);
      expect(await back.takeList(phone, me.signedList), isFalse);
      expect(DeviceList.verified(me.signedList)!.removed, [back.deviceId]);
    },
  );

  test('a recovery code finds its blob by itself, and opens it', () async {
    final me = (await PersonIdentity.create(
      Memory(),
      deviceName: 'Mac',
      platform: 'macos',
    )).identity;
    final r = me.newRecovery();
    expect(recoveryLookup(r.code.toLowerCase().replaceAll('-', ' ')), r.lookup);
    expect(r.lookup, hasLength(32));
    expect(r.blob['blob'], isNot(contains(me.person.scalarHex)));
    final back = await PersonIdentity.restore(
      Memory(),
      blob: r.blob,
      code: r.code,
      deviceName: 'New phone',
      platform: 'ios',
      lastKnown: me.list,
    );
    expect(back!.personId, me.personId);
    expect(me.newRecovery().lookup, isNot(r.lookup));
  });
}
