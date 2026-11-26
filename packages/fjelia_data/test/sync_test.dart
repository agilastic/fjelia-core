import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_core/services/sync/sync_change.dart';
import 'package:fjelia_core/services/sync/sync_tables.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/sync.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase phone;
  late AppDatabase desktop;
  final day = DateTime.utc(2026, 11, 3);

  setUp(() {
    phone = AppDatabase(NativeDatabase.memory());
    desktop = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() async {
    await phone.close();
    await desktop.close();
  });

  ActivityRecordsCompanion activity(String id, String name) =>
      ActivityRecordsCompanion.insert(
        activityId: id,
        name: name,
        type: 'running',
        startDate: day,
        durationSeconds: 3600,
      );

  AbsencesCompanion absence(String kind) => AbsencesCompanion.insert(
    kind: kind,
    startDay: day,
    endDay: day.add(const Duration(days: 3)),
    createdAt: day,
  );

  /// Sends everything the desktop has not received yet, in small pages.
  Future<int> sync({int from = 0}) async {
    var seq = from;
    while (true) {
      final page = await phone.syncChangesSince(seq, limit: 2);
      if (page.isEmpty) return seq;
      await desktop.applySyncChanges(page, fromDevice: 'phone');
      seq = page.last.seq;
    }
  }

  test('every table is synced, kept on the device or held back', () {
    final named = {
      ...syncTables.map((t) => t.name),
      ...deviceOnlyTables,
      ...coachPhaseTables,
    };
    final tables = phone.allTables.map((t) => t.actualTableName).toSet();
    expect(tables.difference(named), isEmpty, reason: 'needs a decision');
    expect(named.difference(tables), isEmpty, reason: 'no such table');
    expect(
      syncTables.length + deviceOnlyTables.length + coachPhaseTables.length,
      tables.length,
      reason: 'a table is named twice',
    );
  });

  test('every key names real columns', () async {
    for (final t in syncTables) {
      final columns = {
        for (final r
            in await phone.customSelect('PRAGMA table_info("${t.name}")').get())
          r.read<String>('name'),
      };
      expect(t.key.isNotEmpty || t.rowId != null, isTrue, reason: t.name);
      expect(
        columns,
        containsAll([...t.key, ?t.rowId, ...t.localRefs.keys]),
        reason: t.name,
      );
    }
  });

  test(
    'rows written before the log existed are sent on the first sync',
    () async {
      await phone.into(phone.activityRecords).insert(activity('a1', 'Run'));
      await phone.into(phone.absences).insert(absence('vacation'));
      await phone.customStatement('DROP TABLE sync_changes');
      await phone.customStatement('DROP TABLE sync_row_ids');
      await phone.customStatement('DROP TABLE sync_state');
      await phone.installSync();

      await sync();
      final run = await desktop.getActivityById('a1');
      expect(run?.name, 'Run');
      expect(await desktop.select(desktop.absences).get(), hasLength(1));
    },
  );

  test('inserts, edits and deletes reach the desktop', () async {
    await phone.into(phone.activityRecords).insert(activity('a1', 'Run'));
    await phone.into(phone.activityRecords).insert(activity('a2', 'Ride'));
    final vacation = await phone
        .into(phone.absences)
        .insert(absence('vacation'));
    await phone.into(phone.absences).insert(absence('illness'));
    var seq = await sync();
    expect(await desktop.select(desktop.activityRecords).get(), hasLength(2));

    await phone.renameActivity('a1', 'Easy run');
    await (phone.delete(
      phone.activityRecords,
    )..where((a) => a.activityId.equals('a2'))).go();
    await (phone.update(phone.absences)..where((a) => a.id.equals(vacation)))
        .write(const AbsencesCompanion(note: Value('Lofoten')));
    seq = await sync(from: seq);

    expect((await desktop.getActivityById('a1'))?.name, 'Easy run');
    expect(await desktop.getActivityById('a2'), isNull);
    final absences = await desktop.select(desktop.absences).get();
    expect(absences.map((a) => (a.kind, a.note)), {
      ('vacation', 'Lofoten'),
      ('illness', null),
    });

    await phone.delete(phone.absences).go();
    await sync(from: seq);
    expect(await desktop.select(desktop.absences).get(), isEmpty);
  });

  test('a record changed twice is sent once, in its newest state', () async {
    await phone.into(phone.activityRecords).insert(activity('a1', 'Run'));
    await phone.renameActivity('a1', 'Tempo');
    await phone.renameActivity('a1', 'Tempo run');
    final changes = await phone.syncChangesSince(0);
    final runs = changes.where((c) => c.table == 'activity_records');
    expect(runs, hasLength(1));
    expect(runs.single.row?['name'], 'Tempo run');
    expect(runs.single.row, isNot(contains('id')));
  });

  test('received changes are not logged as this device\'s own', () async {
    await phone.into(phone.absences).insert(absence('vacation'));
    await sync();
    final logged = await desktop.syncChangesSince(0);
    expect(logged.single.originDevice, 'phone');
    // The desktop's own log keeps the phone's sync id.
    final sent = await phone.syncChangesSince(0);
    expect(logged.single.key, sent.single.key);
  });

  test('a reference to a device-numbered row travels by sync id', () async {
    // The desktop numbers its zone definitions differently.
    await desktop
        .into(desktop.hrZoneDefinitions)
        .insert(
          HrZoneDefinitionsCompanion.insert(
            sport: 'cycling',
            floorsJson: '[]',
            method: 'manual',
            source: 'desktop',
            effectiveFrom: day,
          ),
        );
    final defs = await phone.select(phone.hrZoneDefinitions).get();
    final definition = defs.isEmpty
        ? await phone
              .into(phone.hrZoneDefinitions)
              .insert(
                HrZoneDefinitionsCompanion.insert(
                  sport: 'running',
                  floorsJson: '[120,140,160,175]',
                  method: 'manual',
                  source: 'athlete',
                  effectiveFrom: day,
                ),
              )
        : defs.first.id;
    await phone
        .into(phone.hrZoneSummaries)
        .insert(
          HrZoneSummariesCompanion.insert(
            activityId: 'a1',
            definitionId: definition,
            algorithmVersion: 1,
            sport: 'running',
            startDate: day,
            elapsedSeconds: 60,
            coveredSeconds: 60,
            zoneSecondsJson: '[60,0,0,0,0]',
            computedAt: day,
          ),
        );
    await sync();

    final summary = await desktop.select(desktop.hrZoneSummaries).getSingle();
    final local = await (desktop.select(
      desktop.hrZoneDefinitions,
    )..where((d) => d.id.equals(summary.definitionId))).getSingle();
    final original = await (phone.select(
      phone.hrZoneDefinitions,
    )..where((d) => d.id.equals(definition))).getSingle();
    expect(local.sport, original.sport);
    expect(local.floorsJson, original.floorsJson);
  });

  test('ECG waveforms are only sent on request', () async {
    await phone.customStatement(
      "INSERT INTO ecg_sample_chunks VALUES ('r1', 0, '[1,2,3]')",
    );
    expect(
      (await phone.syncChangesSince(0))
          .where((c) => c.category == SyncCategory.ecg),
      isEmpty,
    );
    final asked = await phone.syncChangesSince(0, onRequest: true);
    expect(asked.map((c) => c.table), contains('ecg_sample_chunks'));
  });

  test('a change survives the wire', () async {
    await phone.into(phone.absences).insert(absence('injury'));
    final sent = (await phone.syncChangesSince(0)).single;
    final received = SyncChange.fromJson(sent.toJson());
    expect(received.key, sent.key);
    expect(received.row, sent.row);
    expect(received.op, SyncOp.upsert);
    expect(received.changedAt, sent.changedAt);
  });

  test('reopening keeps the log and its triggers', () async {
    await phone.into(phone.absences).insert(absence('injury'));
    final epoch = await phone.syncLogEpoch();
    await phone.installSync();
    expect(await phone.syncLogEpoch(), epoch);
    expect(await phone.syncChangesSince(0), hasLength(1));
    await phone.into(phone.absences).insert(absence('illness'));
    expect(await phone.syncChangesSince(0), hasLength(2));
  });

  test('a device never gets its own changes back', () async {
    await phone.into(phone.absences).insert(absence('vacation'));
    await sync();
    await desktop.into(desktop.absences).insert(absence('injury'));
    final back = await desktop.syncChangesSince(0, exceptOrigin: 'phone');
    expect(back.single.row?['kind'], 'injury');
    expect(back.single.originDevice, isNull); // made on the desktop
  });

  test('the records a device changed are known after a sync', () async {
    await desktop.into(desktop.absences).insert(absence('injury'));
    final before = await desktop.syncHeadSeq();
    await phone.into(phone.absences).insert(absence('vacation'));
    await sync();
    final keys = await desktop.syncKeysFrom(
      'absences',
      'phone',
      afterSeq: before,
    );
    expect(keys, hasLength(1));
    expect(
      await desktop.syncKeysFrom('absences', 'other', afterSeq: 0),
      isEmpty,
    );
  });

  test('the newer edit wins on both sides', () async {
    await phone.into(phone.activityRecords).insert(activity('a1', 'Run'));
    await sync();
    // Both rename; the desktop later.
    await phone.renameActivity('a1', 'Phone name');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await desktop.renameActivity('a1', 'Desktop name');
    // The phone's older rename does not overwrite the desktop's.
    final fromPhone = await phone.syncChangesSince(0);
    final taken = await desktop.applySyncChanges(
      fromPhone,
      fromDevice: 'phone',
    );
    expect(taken, lessThan(fromPhone.length));
    expect((await desktop.getActivityById('a1'))?.name, 'Desktop name');
    // The desktop's newer one reaches the phone.
    final fromDesktop = await desktop.syncChangesSince(
      0,
      exceptOrigin: 'phone',
    );
    await phone.applySyncChanges(fromDesktop, fromDevice: 'desktop');
    expect((await phone.getActivityById('a1'))?.name, 'Desktop name');
  });

  test('clearing one phone keeps the computer\'s own records', () async {
    await phone.into(phone.absences).insert(absence('vacation'));
    await sync();
    await desktop.into(desktop.absences).insert(absence('injury'));
    await desktop.clearSyncedData(origin: 'phone');
    final left = await desktop.select(desktop.absences).get();
    expect(left.single.kind, 'injury');
    expect((await desktop.syncChangesSince(0)).single.row?['kind'], 'injury');
  });
}
