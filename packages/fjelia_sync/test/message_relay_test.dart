import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/messages.dart';
import 'package:fjelia_sync/src/identity/device_list.dart';
import 'package:fjelia_sync/src/identity/message_relay.dart';
import 'package:fjelia_sync/src/identity/person.dart';
import 'package:fjelia_sync/src/identity/recovery.dart';
import 'package:fjelia_sync/src/identity/relay_client.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

import 'identity_person_test.dart' show Memory;

/// The relay's behaviour (push-server relay.py) in memory: lists by
/// person, envelopes per recipient device. It never sees inside them.
class FakeRelay {
  final lists = <String, Map<String, dynamic>>{};
  final queues = <String, List<(int, Map<String, dynamic>)>>{};
  List<(int, Map<String, dynamic>)> queue(String? d) => queues[d] ?? const [];
  final seen = <String>[];
  final recoveries = <String, Map<String, dynamic>>{};
  var _next = 1;

  Future<(int, Object?)> call(
    String method,
    Uri url,
    Object? body,
    Map<String, String> headers,
  ) async {
    final b = jsonDecode(jsonEncode(body)) as Map<String, dynamic>?;
    final device = headers['authorization']?.substring(7);
    switch ((method, url.path)) {
      case ('POST', '/v1/relay/lists'):
        final list = DeviceList.verified(b!)!;
        final had = lists[list.person];
        if (had == null || (had['list'] as Map)['version'] < list.version) {
          lists[list.person] = b;
        }
        return (200, {'kept': true});
      case ('POST', '/v1/relay/challenge'):
        return (200, {'challenge': 'c'});
      case ('POST', '/v1/relay/session'):
        return (200, {'token': b!['device'], 'expires': 1 << 40});
      case ('POST', '/v1/relay/envelopes'):
        seen.add(jsonEncode(b));
        for (final r in b!['recipients'] as List) {
          (queues[r['device']] ??= []).add((_next++, b));
        }
        return (200, {'queued': 1});
      case ('GET', '/v1/relay/envelopes'):
        final after = int.parse(url.queryParameters['after']!);
        return (
          200,
          {
            'envelopes': [
              for (final (id, e) in queue(device))
                if (id > after) {'id': id, 'envelope': e},
            ],
            'more': false,
          },
        );
      case ('POST', '/v1/relay/envelopes/ack'):
        queues[device]?.removeWhere((x) => x.$1 <= (b!['up_to'] as int));
        return (204, null);
    }
    if (method == 'POST' && url.path == '/v1/relay/recovery') {
      if (b!['replaces'] case final String old) recoveries.remove(old);
      recoveries[b['lookup'] as String] = b['blob'] as Map<String, dynamic>;
      return (204, null);
    }
    if (method == 'GET' && url.path.startsWith('/v1/relay/recovery/')) {
      final r = recoveries[url.pathSegments.last];
      return r == null ? (404, null) : (200, {'blob': r});
    }
    if (method == 'GET' && url.path.startsWith('/v1/relay/lists/')) {
      final l = lists[url.pathSegments.last];
      return l == null ? (404, null) : (200, l);
    }
    return (404, null);
  }
}

class Person {
  Person._(this.db, this.me, this.relay, this.name);
  final AppDatabase db;
  final PersonIdentity me;
  final MessageRelay relay;
  final String name;

  static Future<Person> make(String name, FakeRelay fake) async {
    final store = Memory();
    final me = (await PersonIdentity.create(
      store,
      deviceName: '$name device',
      platform: 'ios',
    )).identity;
    final db = AppDatabase(NativeDatabase.memory());
    await db.installMessages();
    await db.savePerson(
      MessagePerson(person: me.personId, name: name, role: PersonRole.self),
    );
    final client = RelayClient(
      Uri.parse('https://relay.test'),
      transport: fake.call,
    );
    return Person._(db, me, MessageRelay(db, me, client, store), name);
  }

  MessagePerson as(PersonRole role) =>
      MessagePerson(person: me.personId, name: name, role: role);

  /// What the coach link (nearby pairing) leaves on each side.
  Future<void> knows(Person other, PersonRole role) =>
      db.savePerson(other.as(role));

  Future<List<String>> texts(String thread) async => [
    for (final e in await openThread(db, thread))
      if (e.event.type == EventType.text) e.event.text!,
  ];
}

void main() {
  test(
    'a coach\'s group and a direct thread, end to end through the relay',
    () async {
      final relay = FakeRelay();
      final coach = await Person.make('Kim', relay);
      final ana = await Person.make('Ana', relay);
      final ben = await Person.make('Ben', relay);
      final eve = await Person.make('Eve', relay);
      for (final a in [ana, ben]) {
        await coach.knows(a, PersonRole.athlete);
        await a.knows(coach, PersonRole.coach);
      }
      for (final p in [coach, ana, ben, eve]) {
        await p.relay.run(); // lists up
      }

      final group = await createGroup(
        coach.db,
        title: 'Trail team',
        athletes: [ana.as(PersonRole.athlete), ben.as(PersonRole.athlete)],
      );
      await sendText(coach.db, group, 'Long run Saturday 8:00');
      await coach.relay.run();

      await ana.relay.run();
      expect((await loadThreads(ana.db)).single.title, 'Trail team');
      expect((await loadThreads(ana.db)).single.unread, 1);
      expect(await ana.texts(group), ['Long run Saturday 8:00']);
      await sendText(ana.db, group, 'I am in');
      await ana.relay.run();

      // Ben meets Ana only in the group, and still gets her message.
      await ben.relay.run();
      expect(await ben.texts(group), ['Long run Saturday 8:00', 'I am in']);
      expect(
        (await ben.db.people()).firstWhere((p) => p.name == 'Ana').role,
        PersonRole.member,
      );

      // Ana writes to her coach alone.
      final dm = await startDirect(ana.db, coach.as(PersonRole.coach));
      await sendText(ana.db, dm, 'Knee hurts a bit');
      await ana.relay.run();
      await coach.relay.run();
      final threads = await loadThreads(coach.db);
      expect(threads.map((t) => t.title).toSet(), {'Trail team', 'Ana'});
      expect(await coach.texts(dm), ['Knee hurts a bit']);
      await ben.relay.run();
      expect((await loadThreads(ben.db)).map((t) => t.id), [group]);

      // Ben leaves; what follows does not reach him.
      await leaveGroup(ben.db, group);
      await ben.relay.run();
      await coach.relay.run();
      await sendText(coach.db, group, 'Without Ben now');
      await coach.relay.run();
      await ben.relay.run();
      expect(await ben.texts(group), isNot(contains('Without Ben now')));
      await ana.relay.run();
      expect(await ana.texts(group), contains('Without Ben now'));
      expect((await ana.db.thread(group))!.gone, {ben.me.personId});

      // A stranger cannot write to Ana, nor pull her into a group.
      await eve.db.savePerson(ana.as(PersonRole.athlete));
      final spam = await startDirect(eve.db, ana.as(PersonRole.athlete));
      await sendText(eve.db, spam, 'Buy now');
      await eve.relay.run();
      await ana.relay.run();
      expect(
        (await loadThreads(ana.db)).map((t) => t.id),
        isNot(contains(spam)),
      );

      // The relay only ever saw ciphertext.
      expect(relay.seen.any((e) => e.contains('Knee')), isFalse);
      expect(relay.seen.any((e) => e.contains('Trail team')), isFalse);
    },
  );

  test(
    'a message waits while the coach\'s devices are not known yet',
    () async {
      final relay = FakeRelay();
      final coach = await Person.make('Kim', relay);
      final ana = await Person.make('Ana', relay);
      await ana.knows(coach, PersonRole.coach);
      await ana.relay.run(); // only Ana's list is on the relay
      final dm = await startDirect(ana.db, coach.as(PersonRole.coach));
      await sendText(ana.db, dm, 'Hello?');
      await ana.relay.run();
      expect(await ana.db.outbox(), hasLength(2)); // still waiting
      await coach.knows(ana, PersonRole.athlete);
      await coach.relay.run(); // the coach's list arrives
      await ana.relay.run();
      expect(await ana.db.outbox(), isEmpty);
      await coach.relay.run();
      expect(await coach.texts(dm), ['Hello?']);
    },
  );

  test(
    'a lost phone comes back with the code and keeps its threads going',
    () async {
      final relay = FakeRelay();
      final coach = await Person.make('Kim', relay);
      final ana = await Person.make('Ana', relay);
      await ana.knows(coach, PersonRole.coach);
      await coach.knows(ana, PersonRole.athlete);
      final client = RelayClient(
        Uri.parse('https://relay.test'),
        transport: relay.call,
      );
      final store = Memory();
      final first = await makeRecoveryCode(ana.me, client, store);
      final code = await makeRecoveryCode(ana.me, client, store);
      Future<RestoreProblem?> problem(String c) async => (await restoreWithCode(
        c,
        relay: client,
        store: Memory(),
        deviceName: 'x',
        platform: 'ios',
      )).problem;
      // The first code no longer works.
      expect(await problem(first), RestoreProblem.unknownCode);
      expect(await problem('nonsense'), RestoreProblem.notACode);
      final back = await restoreWithCode(
        code,
        relay: client,
        store: Memory(),
        deviceName: 'New iPhone',
        platform: 'ios',
      );
      final newPhone = back.identity!;
      expect(newPhone.personId, ana.me.personId);
      expect(newPhone.list.devices.map((d) => d.name), [
        'Ana device',
        'New iPhone',
      ]);
      // The coach's next message reaches the new phone too.
      final dm = await startDirect(coach.db, ana.as(PersonRole.athlete));
      await sendText(coach.db, dm, 'Welcome back');
      await coach.relay.run();
      final db = AppDatabase(NativeDatabase.memory());
      await db.installMessages();
      await db.savePerson(
        MessagePerson(
          person: newPhone.personId,
          name: 'Ana',
          role: PersonRole.self,
        ),
      );
      await db.savePerson(coach.as(PersonRole.coach));
      await MessageRelay(db, newPhone, client, Memory()).run();
      expect(
        [
          for (final e in await openThread(db, dm))
            if (e.event.type == EventType.text) e.event.text,
        ],
        ['Welcome back'],
      );
    },
  );

  test(
    'an athlete cannot make a group or add others to the coach\'s',
    () async {
      final relay = FakeRelay();
      final coach = await Person.make('Kim', relay);
      final ana = await Person.make('Ana', relay);
      await ana.knows(coach, PersonRole.coach);
      expect(
        () => createGroup(
          ana.db,
          title: 'Mine',
          athletes: [coach.as(PersonRole.coach)],
        ),
        throwsArgumentError,
      );
    },
  );
}
