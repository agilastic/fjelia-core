import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_sync/fjelia_sync.dart';
import 'package:test/test.dart';

class MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class FakeLocator implements PeerLocator {
  String? address;
  final asked = <String>[];
  @override
  Future<String?> locate(String deviceId) async {
    asked.add(deviceId);
    return address;
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // Key generation is the slow part; one identity per side is enough.
  final phoneIdentity = DeviceIdentity.generate();
  final desktopIdentity = DeviceIdentity.generate();
  final day = DateTime.utc(2026, 11, 3);

  late AppDatabase phoneDb;
  late AppDatabase desktopDb;
  late MemoryStore phoneSecrets;
  late SyncServer server;
  late SyncClient phone;

  setUp(() async {
    phoneDb = AppDatabase(NativeDatabase.memory());
    desktopDb = AppDatabase(NativeDatabase.memory());
    phoneSecrets = MemoryStore();
    server = SyncServer(
      db: desktopDb,
      identity: desktopIdentity,
      name: 'Studio Mac',
      port: 0,
    );
    await server.start();
    phone = SyncClient(
      db: phoneDb,
      identity: phoneIdentity,
      name: 'iPhone',
      secrets: phoneSecrets,
      pageSize: 3,
    );
  });
  tearDown(() async {
    await server.stop();
    await phoneDb.close();
    await desktopDb.close();
  });

  Future<PairingOffer> offer() => server.offerPairing(hosts: ['127.0.0.1']);

  Future<void> run(String id) => phoneDb
      .into(phoneDb.activityRecords)
      .insert(
        ActivityRecordsCompanion.insert(
          activityId: id,
          name: 'Run $id',
          type: 'running',
          startDate: day,
          durationSeconds: 3600,
        ),
      );

  Future<int> desktopRuns() async =>
      (await desktopDb.select(desktopDb.activityRecords).get()).length;

  test('the code survives the QR round trip', () async {
    final code = await offer();
    final read = PairingOffer.parse(code.toUri().toString())!;
    expect(read.deviceId, desktopIdentity.deviceId);
    expect(read.name, 'Studio Mac');
    expect(read.fingerprint, desktopIdentity.fingerprint);
    expect(read.hosts, ['127.0.0.1']);
    expect(read.port, server.boundPort);
    expect(read.token, code.token);
    expect(PairingOffer.parse('https://example.com/pair?v=1'), isNull);
  });

  test('a paired phone sends its data, then only what changed', () async {
    for (var i = 0; i < 7; i++) {
      await run('a$i');
    }
    final events = <SyncEvent>[];
    server.events.listen(events.add);

    final desktop = await phone.pair(await offer());
    expect(desktop.name, 'Studio Mac');
    final paired = (await desktopDb.syncPeers()).single;
    expect(paired.name, 'iPhone');
    expect(paired.fingerprint, phoneIdentity.fingerprint);
    // The desktop keeps only a hash of the secret the phone holds.
    final secret = phoneSecrets.values.values.single;
    expect(paired.secretHash, isNot(secret));

    expect(await phone.push(desktop), 7);
    expect(await desktopRuns(), 7);
    expect(await phone.push(desktop), 0);

    await run('a7');
    expect(await phone.push(desktop), 1);
    expect(await desktopRuns(), 8);
    await Future<void>.delayed(Duration.zero);
    expect(events.first, isA<PeerPaired>());
    expect(events.whereType<ChangesReceived>().map((e) => e.count).sum, 8);
  });

  test('a device without the code\'s certificate is refused', () async {
    final code = await offer();
    final forged = PairingOffer(
      deviceId: code.deviceId,
      name: code.name,
      fingerprint: phoneIdentity.fingerprint, // not the desktop's
      hosts: code.hosts,
      port: code.port,
      token: code.token,
    );
    await expectLater(phone.pair(forged), throwsA(anything));
    expect(await phoneDb.syncPeers(), isEmpty);
    expect(await desktopDb.syncPeers(), isEmpty);
  });

  test('a code pairs one device, and only while it is valid', () async {
    final code = await offer();
    await phone.pair(code);
    await expectLater(
      phone.pair(code),
      throwsA(isA<SyncRefused>().having((e) => e.reason, 'reason', 'token')),
    );
    server.cancelPairing();
    final withdrawn = PairingOffer.parse(code.toUri().toString())!;
    await expectLater(phone.pair(withdrawn), throwsA(isA<SyncRefused>()));
  });

  test('a wrong secret is refused', () async {
    final desktop = await phone.pair(await offer());
    phoneSecrets.values.updateAll((key, value) => 'guess');
    await expectLater(
      phone.push(desktop),
      throwsA(isA<SyncRefused>().having((e) => e.status, 'status', 401)),
    );
  });

  test('a desktop that lost its place receives everything again', () async {
    await run('a1');
    await run('a2');
    final desktop = await phone.pair(await offer());
    expect(await phone.push(desktop), 2);
    await desktopDb.setSyncPeerCursor(phoneIdentity.deviceId, 'other', 99);
    expect(await phone.push(desktop), 2);
    expect(await desktopRuns(), 2);
  });

  test('a phone that starts a new log leaves nothing stale behind', () async {
    await run('a1');
    await run('a2');
    final desktop = await phone.pair(await offer());
    await phone.push(desktop);
    // Delete all data: a new database, a new log, one new run.
    await phoneDb.close();
    phoneDb = AppDatabase(NativeDatabase.memory());
    phone = SyncClient(
      db: phoneDb,
      identity: phoneIdentity,
      name: 'iPhone',
      secrets: phoneSecrets,
    );
    await phoneDb.saveSyncPeer(desktop);
    await run('b1');
    expect(await phone.push(desktop), 1);
    final runs = await desktopDb.select(desktopDb.activityRecords).get();
    expect(runs.map((r) => r.activityId), ['b1']);
  });

  test('a computer that moved is found again by its device id', () async {
    await run('a1');
    final desktop = await phone.pair(await offer());
    expect(await phone.push(desktop), 1);

    // The computer comes back on another address (here: another port).
    await server.stop();
    server = SyncServer(
      db: desktopDb,
      identity: desktopIdentity,
      name: 'Studio Mac',
      port: 0,
    );
    await server.start();
    final locator = FakeLocator()..address = '127.0.0.1:${server.boundPort}';
    final located = SyncClient(
      db: phoneDb,
      identity: phoneIdentity,
      name: 'iPhone',
      secrets: phoneSecrets,
      locator: locator,
    );
    await run('a2');
    expect(await located.push((await phoneDb.syncPeer(desktop.deviceId))!), 1);
    expect(locator.asked, [desktopIdentity.deviceId]);
    expect(
      (await phoneDb.syncPeer(desktop.deviceId))!.address,
      locator.address,
    );
    // The next sync goes straight to the new address.
    await run('a3');
    expect(await located.push((await phoneDb.syncPeer(desktop.deviceId))!), 1);
    expect(locator.asked, hasLength(1));
    expect(await desktopRuns(), 3);
  });

  test('a computer that is not around stays an error', () async {
    final desktop = await phone.pair(await offer());
    await server.stop();
    final lost = SyncClient(
      db: phoneDb,
      identity: phoneIdentity,
      name: 'iPhone',
      secrets: phoneSecrets,
      locator: FakeLocator(),
      timeout: const Duration(seconds: 1),
    );
    await expectLater(lost.push(desktop), throwsA(isA<SocketException>()));
    await server.start(); // for tearDown
  });

  test(
    'changes made on the computer reach the phone, nothing echoes',
    () async {
      await run('a1');
      final desktop = await phone.pair(await offer());
      expect(await phone.sync(desktop), isA<SyncResult>());
      // The computer renames the run and notes a vacation.
      await desktopDb.renameActivity('a1', 'Hill Run');
      await desktopDb
          .into(desktopDb.absences)
          .insert(
            AbsencesCompanion.insert(
              kind: 'vacation',
              startDay: day,
              endDay: day.add(const Duration(days: 2)),
              createdAt: day,
            ),
          );
      final peer = (await phoneDb.syncPeer(desktop.deviceId))!;
      final first = await phone.sync(peer);
      expect(first.sent, 0);
      expect(first.received, greaterThan(0));
      expect((await phoneDb.getActivityById('a1'))?.name, 'Hill Run');
      expect(await phoneDb.select(phoneDb.absences).get(), hasLength(1));
      // Nothing goes back and forth any more.
      final again = await phone.sync(
        (await phoneDb.syncPeer(desktop.deviceId))!,
      );
      expect((again.sent, again.received), (0, 0));
      // The phone's next own change still goes out alone.
      await run('a2');
      final third = await phone.sync(
        (await phoneDb.syncPeer(desktop.deviceId))!,
      );
      expect((third.sent, third.received), (1, 0));
    },
  );

  test('a coach keeps each athlete in their own database', () async {
    final athleteDb = AppDatabase(NativeDatabase.memory());
    addTearDown(athleteDb.close);
    await server.stop();
    server = SyncServer(
      db: desktopDb,
      identity: desktopIdentity,
      name: 'Coach Mac',
      port: 0,
      databaseOf: (peer) =>
          peer.role == PeerRole.athlete ? athleteDb : desktopDb,
    );
    await server.start();
    await run('a1');
    final coach = await phone.pair(
      await server.offerPairing(hosts: ['127.0.0.1'], role: PeerRole.athlete),
    );
    expect(await phone.push(coach), 1);
    expect((await desktopDb.syncPeers()).single.role, PeerRole.athlete);
    expect(await desktopDb.select(desktopDb.activityRecords).get(), isEmpty);
    expect(
      await athleteDb.select(athleteDb.activityRecords).get(),
      hasLength(1),
    );
  });

  test('progress has a total, and both sides remember the sync', () async {
    for (var i = 0; i < 5; i++) {
      await run('p$i');
    }
    final desktop = await phone.pair(await offer());
    final seen = <(int, int)>[];
    await phone.sync(desktop, onProgress: (s, t) => seen.add((s, t)));
    expect(seen.first, (0, 5));
    expect(seen.last, (5, 5));
    expect((await phoneDb.syncPeer(desktop.deviceId))!.lastSynced, isNotNull);
    expect((await desktopDb.syncPeers()).single.lastSynced, isNotNull);
  });

  test('the computer asks for an ECG waveform and gets it', () async {
    await phoneDb.customStatement(
      "INSERT INTO ecg_sample_chunks VALUES ('r1', 0, '[1,2]'), "
      "('r1', 1, '[3,4]'), ('r2', 0, '[5]')",
    );
    await server.stop();
    server = SyncServer(
      db: desktopDb,
      identity: desktopIdentity,
      name: 'Studio Mac',
      port: 0,
    );
    await desktopDb.wantEcgWaveform('r1');
    await server.start();
    final desktop = await phone.pair(await offer());
    await phone.sync(desktop);
    final chunks = await desktopDb
        .customSelect('SELECT recording_id FROM ecg_sample_chunks')
        .get();
    expect(
      [for (final c in chunks) c.read<String>('recording_id')],
      ['r1', 'r1'],
    );
  });

  test('the phone hands its Pro pass to the computer', () async {
    final withPass = SyncClient(
      db: phoneDb,
      identity: DeviceIdentity.generate(),
      name: 'Phone',
      secrets: MemoryStore(),
      proPass: () async => 'a.b.c',
    );
    final desktop = await withPass.pair(await offer());
    await withPass.sync(desktop);
    expect((await desktopDb.syncPeers()).single.proPass, 'a.b.c');
  });

  test('unpairing ends it on both devices', () async {
    final desktop = await phone.pair(await offer());
    await phone.unpair(desktop);
    expect(await phoneDb.syncPeers(), isEmpty);
    expect(await desktopDb.syncPeers(), isEmpty);
    expect(phoneSecrets.values, isEmpty);
  });

  test('an identity is kept once created', () async {
    final store = MemoryStore();
    final first = await DeviceIdentity.loadOrCreate(store);
    final again = await DeviceIdentity.loadOrCreate(store);
    expect(again.deviceId, first.deviceId);
    expect(again.fingerprint, first.fingerprint);
    expect(first.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
  });
}

extension on Iterable<int> {
  int get sum => fold(0, (a, b) => a + b);
}
