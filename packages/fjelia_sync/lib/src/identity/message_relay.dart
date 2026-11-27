/// Messages through the relay: the outbox goes to every device of every
/// member (and to the person's own other devices), and what arrives is
/// opened, checked and stored.
library;

import 'dart:convert';

import 'package:fjelia_core/services/messaging/thread_event.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/messages.dart';

import '../identity.dart' show SecretStore;
import 'device_list.dart';
import 'envelope.dart';
import 'person.dart';
import 'relay_client.dart';

class MessageRelay {
  MessageRelay(this.db, this.me, this.relay, this.store);

  final AppDatabase db;
  final PersonIdentity me;
  final RelayClient relay;
  final SecretStore store;

  static const _taken = 'fjelia.identity.relay_taken';

  /// Sends what waits, then takes what arrived. Returns the events taken.
  /// Throws [RelayError] or a socket error when the relay cannot be
  /// reached; nothing is lost, the next run goes on.
  Future<int> run() async {
    await relay.uploadList(me.signedList);
    await relay.signIn(me);
    await send();
    return receive();
  }

  /// The devices of [person]: their newest list from the relay, checked
  /// against their person id, kept when newer than the one known.
  Future<DeviceList?> devicesOf(String person) async {
    if (person == me.personId) return me.list;
    final known = (await db.people())
        .where((p) => p.person == person)
        .firstOrNull;
    var list = known?.deviceList == null
        ? null
        : DeviceList.verified(
            jsonDecode(known!.deviceList!) as Map<String, dynamic>,
            person: person,
          );
    final fresh = await relay.list(person);
    if (fresh != null) {
      final next = DeviceList.newer(list, fresh);
      if (next != null && !identical(next, list)) {
        list = next;
        if (known != null) {
          await db.savePerson(
            MessagePerson(
              person: person,
              name: known.name,
              role: known.role,
              deviceList: jsonEncode(fresh),
              listVersion: next.version,
            ),
          );
        }
      }
    }
    return list;
  }

  Future<void> send() async {
    final waiting = await db.outbox();
    final byThread = <String, List<ThreadEvent>>{};
    for (final e in waiting) {
      (byThread[e.thread] ??= []).add(e);
    }
    var seq = DateTime.now().millisecondsSinceEpoch;
    for (final events in byThread.values) {
      final state = await db.thread(events.first.thread);
      if (state == null) continue;
      // Members now, those removed by these events (they learn it), and
      // this person's own other devices.
      final people = {
        ...state.members.keys,
        for (final e in events)
          if (e.type == EventType.removed) ...e.members.map((m) => m.person),
        me.personId,
      };
      final recipients = <Recipient>[];
      for (final person in people) {
        final list = await devicesOf(person);
        for (final d in list?.devices ?? const <ListedDevice>[]) {
          if (d.id != me.deviceId) {
            recipients.add((device: d.id, encKey: d.encKey));
          }
        }
      }
      if (recipients.isNotEmpty) {
        await relay.send(
          sealEnvelope(
            senderSign: me.deviceSign,
            person: me.personId,
            seq: seq++,
            payload: {
              'messages': [for (final e in events) e.toJson()],
            },
            recipients: recipients,
          ),
        );
      }
      await db.markRelayed(events.map((e) => e.id));
    }
  }

  Future<int> receive() async {
    var after = int.tryParse(await store.read(_taken) ?? '') ?? 0;
    var taken = 0;
    while (true) {
      final page = await relay.fetch(after);
      for (final (id, envelope) in page.envelopes) {
        taken += await _take(envelope);
        after = id;
      }
      if (page.envelopes.isNotEmpty) {
        await relay.ack(after);
        await store.write(_taken, '$after');
      }
      if (!page.more) return taken;
    }
  }

  Future<int> _take(Map<String, dynamic> envelope) async {
    final person = envelope['person'];
    if (person is! String) return 0;
    if (!await _mayWrite(person)) return 0;
    final list = await devicesOf(person);
    final Object? payload;
    try {
      payload = openEnvelope(
        envelope,
        device: me.deviceId,
        encKey: me.deviceEnc,
        senderKey: (from, p) =>
            p == person ? list?.device(from)?.signKey : null,
      );
    } on EnvelopeRejected {
      return 0;
    }
    if (payload is! Map || payload['messages'] is! List) return 0;
    var taken = 0;
    for (final m in payload['messages'] as List) {
      final event = m is Map<String, dynamic> ? ThreadEvent.fromJson(m) : null;
      if (event == null) continue;
      if (!await _allowed(event, person)) continue;
      if (await db.addEvent(
        event,
        from: person,
        outgoing: person == me.personId,
      )) {
        taken++;
        await _meet(event);
      }
    }
    if (person == me.personId) {
      // This person's own other device: what it wrote has gone out already.
      await db.markRelayed([
        for (final m in payload['messages'] as List)
          if (m is Map) m['id'] as String,
      ]);
    }
    return taken;
  }

  /// Someone this person knows: themselves, their coach or athletes, or a
  /// member of one of their threads. Strangers cannot write.
  Future<bool> _mayWrite(String person) async {
    if (person == me.personId) return true;
    if ((await db.people()).any((p) => p.person == person)) return true;
    return (await db.threads()).any((t) => t.state.isMember(person));
  }

  /// A group is created only by this person's coach, and only with them in
  /// it; a direct thread only by someone they know.
  Future<bool> _allowed(ThreadEvent e, String person) async {
    if (e.type != EventType.created || person == me.personId) return true;
    if (!e.members.any((m) => m.person == me.personId)) return false;
    final known = (await db.people())
        .where((p) => p.person == person)
        .firstOrNull;
    if (known == null) return false;
    return e.kind == ThreadKind.direct || known.role == PersonRole.coach;
  }

  /// The people a group brings, so their names show and their devices can
  /// be written to.
  Future<void> _meet(ThreadEvent e) async {
    if (e.type != EventType.created && e.type != EventType.added) return;
    final known = {for (final p in await db.people()) p.person};
    for (final m in e.members) {
      if (!known.contains(m.person)) {
        await db.savePerson(
          MessagePerson(
            person: m.person,
            name: m.name,
            role: PersonRole.member,
          ),
        );
      }
    }
  }
}
