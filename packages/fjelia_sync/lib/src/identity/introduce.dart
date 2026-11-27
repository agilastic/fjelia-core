/// Meeting nearby (docs/identity-and-sync-security.md, section 13): over a
/// pairing already trusted, a coach and an athlete learn each other's person
/// and devices, and an athlete's own computer joins the person of the
/// athlete's phone, so messages reach all of them.
///
/// The phone (the sync client) starts: it sends its person; the computer
/// answers with its own and with what the pairing is to it. For the
/// athlete's own computer the phone then adds it to the device list and
/// hands over the person key.
library;

import 'dart:convert';

import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/messages.dart';
import 'package:fjelia_data/sync.dart' show PeerRole, SyncPeer;

import '../identity.dart' show SecretStore;
import 'device_list.dart';
import 'person.dart';

const personPath = '/v1/person';

/// One side's person: who they are and the store their identity is kept in.
class PersonSide {
  PersonSide({
    required this.db,
    required this.store,
    required this.identity,
    required this.name,
    this.onChanged,
  });

  /// Where people and messages are kept (a coach's own database).
  final AppDatabase db;
  final SecretStore store;

  /// This device's identity, or null while it has none (the first start
  /// makes it).
  final PersonIdentity? Function() identity;

  /// This person's name as others see it.
  final String Function() name;

  /// After the identity changed (a computer joined the phone's person).
  final void Function(PersonIdentity identity)? onChanged;

  Map<String, Object> _hello(PersonIdentity me) => {
    'v': 1,
    'list': me.signedList,
    'name': name(),
  };

  /// The phone's first message.
  Map<String, Object>? hello() {
    final me = identity();
    return me == null ? null : _hello(me);
  }

  /// The computer's answer to [body] from [peer].
  Future<Map<String, Object>> answer(SyncPeer peer, Map body) async {
    final me = identity() ?? (throw StateError('no identity'));
    if (body['join'] case final Map join) {
      return {'joined': await _join(me, join)};
    }
    final list = DeviceList.verified(
      (body['list'] as Map).cast<String, dynamic>(),
    );
    if (list == null) throw const FormatException('device list');
    if (peer.role == PeerRole.athlete) {
      await _keep(list, body['list'], body['name'], PersonRole.athlete);
      return {..._hello(me), 'role': 'coach'};
    }
    // The athlete's own phone: this computer becomes one of its devices.
    final device = me.list.device(me.deviceId)!;
    return {..._hello(me), 'role': 'self', 'device': device.toJson()};
  }

  /// What the phone makes of the computer's [answer]: the follow-up to send,
  /// if any.
  Future<Map<String, Object>?> met(Map answer) async {
    final me = identity();
    if (me == null) return null;
    final list = DeviceList.verified(
      (answer['list'] as Map).cast<String, dynamic>(),
    );
    if (list == null) return null;
    if (answer['role'] == 'coach') {
      await _keep(list, answer['list'], answer['name'], PersonRole.coach);
      return null;
    }
    if (answer['role'] != 'self' || list.person == me.personId) return null;
    final device = ListedDevice.fromJson(
      (answer['device'] as Map).cast<String, dynamic>(),
    );
    if (!list.devices.any((d) => d.id == device.id)) return null;
    if (me.list.device(device.id) == null) {
      me.list = me.list.adding(device, DateTime.now());
      await me.saveList(store);
    }
    return {
      'join': {'person_key': me.person.scalarHex, 'list': me.signedList},
    };
  }

  Future<void> _keep(
    DeviceList list,
    Object? signed,
    Object? name,
    PersonRole role,
  ) => db.savePerson(
    MessagePerson(
      person: list.person,
      name: name is String && name.trim().isNotEmpty && name.length <= 80
          ? name.trim()
          : 'Unknown',
      role: role,
      deviceList: jsonEncode(signed),
      listVersion: list.version,
    ),
  );

  Future<bool> _join(PersonIdentity me, Map join) async {
    final adopted = await me.adopt(
      store,
      personKey: join['person_key'] as String,
      signed: (join['list'] as Map).cast<String, dynamic>(),
    );
    if (adopted == null) return false;
    final old = await db.self();
    await db.savePerson(
      MessagePerson(
        person: adopted.personId,
        name: name(),
        role: PersonRole.self,
      ),
    );
    if (old != null && old.person != adopted.personId) {
      await db.forgetPerson(old.person);
    }
    onChanged?.call(adopted);
    return true;
  }
}
