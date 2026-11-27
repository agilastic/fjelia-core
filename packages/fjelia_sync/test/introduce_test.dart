import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/messages.dart';
import 'package:fjelia_sync/fjelia_sync.dart';
import 'package:test/test.dart';

import 'pairing_test.dart' show MemoryStore;

/// A device with its person, as an app sets it up.
class Side {
  Side(this.name);
  final String name;
  final db = AppDatabase(NativeDatabase.memory());
  final store = MemoryStore();
  PersonIdentity? me;

  Future<PersonSide> start() async {
    me = (await PersonIdentity.create(
      store,
      deviceName: name,
      platform: 'test',
    )).identity;
    await db.installMessages();
    await db.savePerson(
      MessagePerson(person: me!.personId, name: name, role: PersonRole.self),
    );
    return PersonSide(
      db: db,
      store: store,
      identity: () => me,
      name: () => name,
      onChanged: (i) => me = i,
    );
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final phoneIdentity = DeviceIdentity.generate();
  final macIdentity = DeviceIdentity.generate();

  Future<(SyncServer, SyncClient)> connect(Side mac, Side phone) async {
    final server = SyncServer(
      db: mac.db,
      identity: macIdentity,
      name: mac.name,
      port: 0,
      person: await mac.start(),
    );
    await server.start();
    addTearDown(server.stop);
    final client = SyncClient(
      db: phone.db,
      identity: phoneIdentity,
      name: phone.name,
      secrets: MemoryStore(),
      person: await phone.start(),
    );
    return (server, client);
  }

  test('a coach and an athlete meet at the sync', () async {
    final coach = Side('Kim'), ana = Side('Ana');
    final (server, phone) = await connect(coach, ana);
    final peer = await phone.pair(
      await server.offerPairing(hosts: ['127.0.0.1'], role: PeerRole.athlete),
    );
    await phone.sync(peer);
    final [athlete] = await coach.db.people(role: PersonRole.athlete);
    expect((athlete.name, athlete.person), ('Ana', ana.me!.personId));
    expect(athlete.deviceList, isNotNull);
    final [kim] = await ana.db.people(role: PersonRole.coach);
    expect((kim.name, kim.person), ('Kim', coach.me!.personId));
  });

  test('an athlete\'s own computer joins the phone\'s person', () async {
    final mac = Side('Ana'), phone = Side('Ana');
    final (server, client) = await connect(mac, phone);
    final macDevice = mac.me!.deviceId;
    final peer = await client.pair(
      await server.offerPairing(hosts: ['127.0.0.1']),
    );
    await client.sync(peer);
    expect(mac.me!.personId, phone.me!.personId);
    expect(mac.me!.deviceId, macDevice);
    expect(phone.me!.list.devices.map((d) => d.id), contains(macDevice));
    expect(mac.me!.list.version, phone.me!.list.version);
    expect((await mac.db.self())!.person, phone.me!.personId);
    expect(await mac.db.people(), hasLength(1));
    // It survives a restart.
    expect(
      (await PersonIdentity.load(mac.store))!.personId,
      phone.me!.personId,
    );
    // A second sync changes nothing.
    final version = phone.me!.list.version;
    await client.sync(peer);
    expect(phone.me!.list.version, version);
  });
}
