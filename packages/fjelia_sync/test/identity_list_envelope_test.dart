import 'dart:convert';
import 'dart:io';

import 'package:fjelia_sync/src/identity/crypto.dart';
import 'package:fjelia_sync/src/identity/device_list.dart';
import 'package:fjelia_sync/src/identity/envelope.dart';
import 'package:test/test.dart';

ListedDevice device(KeyPair sign, KeyPair enc, String name) => ListedDevice(
  signKey: sign.spki,
  encKey: enc.spki,
  name: name,
  platform: 'macos',
  added: '2026-11-27T10:00:00Z',
);

void main() {
  final vectors = jsonDecode(
    File('../fjelia_core/test/vectors/identity_v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  test('the vectors\' device list is accepted as it is, and not changed', () {
    final d = vectors['device_list'] as Map<String, dynamic>;
    final signed = {'list': d['list'], 'sig': d['sig']};
    final list = DeviceList.verified(signed)!;
    expect(list.person, '2a1ba3b9e9eebfb0d82bc192aed0a4cc');
    expect(list.devices.single.name, 'Test MacBook');
    final changed = jsonDecode(jsonEncode(signed)) as Map<String, dynamic>;
    (changed['list'] as Map)['version'] = 2;
    expect(DeviceList.verified(changed), isNull);
  });

  test('a list only grows; an old one or a stranger\'s is refused', () {
    final person = KeyPair.generate(), stranger = KeyPair.generate();
    final mac = device(KeyPair.generate(), KeyPair.generate(), 'Mac');
    final phone = device(KeyPair.generate(), KeyPair.generate(), 'Phone');
    final now = DateTime.utc(2026, 11, 27, 10);
    final v1 = DeviceList(
      personKey: person.spki,
      version: 1,
      issued: isoSeconds(now),
      devices: [mac],
    );
    final v2 = v1.adding(phone, now);
    final v3 = v2.removing(phone.id, now);
    final current = DeviceList.verified(v3.signed(person));
    expect(current!.devices.map((d) => d.name), ['Mac']);
    // The older list with the phone still on it does not win.
    expect(DeviceList.newer(current, v2.signed(person))!.version, 3);
    expect(() => v3.adding(phone, now), throwsStateError);
    // Someone else's key cannot sign this person's list.
    expect(() => v3.signed(stranger), throwsArgumentError);
    final forged = DeviceList(
      personKey: stranger.spki,
      version: 9,
      issued: isoSeconds(now),
      devices: [phone],
    ).signed(stranger);
    expect(DeviceList.newer(current, forged), same(current));
  });

  test('an envelope opens on its recipients only, and not when changed', () {
    final sender = KeyPair.generate();
    final aSign = KeyPair.generate(), aEnc = KeyPair.generate();
    final bEnc = KeyPair.generate(), stranger = KeyPair.generate();
    final payload = [
      {'table': 'messages', 'op': 'upsert', 'text': 'Hallo'},
    ];
    final env = sealEnvelope(
      senderSign: sender,
      person: 'p1',
      seq: 7,
      payload: payload,
      recipients: [
        (device: aSign.id, encKey: aEnc.spki),
        (device: 'b', encKey: bEnc.spki),
      ],
    );
    List<int>? keys(String from, String person) =>
        from == sender.id && person == 'p1' ? sender.spki : null;
    final wire = jsonDecode(jsonEncode(env)) as Map<String, dynamic>;
    expect(
      openEnvelope(wire, device: aSign.id, encKey: aEnc, senderKey: keys),
      payload,
    );
    expect(
      openEnvelope(wire, device: 'b', encKey: bEnc, senderKey: keys),
      payload,
    );
    Matcher dropped(String why) => throwsA(
      isA<EnvelopeRejected>().having((e) => e.reason, 'reason', contains(why)),
    );
    expect(
      () => openEnvelope(wire, device: 'c', encKey: stranger, senderKey: keys),
      dropped('not a recipient'),
    );
    expect(
      () => openEnvelope(
        wire,
        device: 'b',
        encKey: bEnc,
        senderKey: (_, _) => null,
      ),
      dropped('sender not allowed'),
    );
    final changed = Map<String, dynamic>.of(wire)..['seq'] = 8;
    expect(
      () => openEnvelope(changed, device: 'b', encKey: bEnc, senderKey: keys),
      dropped('bad signature'),
    );
    // A key that is on the list but wrapped for another device still fails.
    expect(
      () => openEnvelope(wire, device: 'b', encKey: aEnc, senderKey: keys),
      dropped('does not open'),
    );
  });
}
