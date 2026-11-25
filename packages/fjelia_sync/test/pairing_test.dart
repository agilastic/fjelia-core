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
