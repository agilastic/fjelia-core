import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late GearEdits edits;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    edits = GearEdits(db);
  });
  tearDown(() => db.close());

  Future<void> run(
    String id,
    DateTime start,
    double km, {
    String type = 'running',
  }) => db
      .into(db.activityRecords)
      .insert(
        ActivityRecordsCompanion.insert(
          activityId: id,
          name: 'Run $id',
          type: type,
          startDate: start,
          durationSeconds: 3600,
          distanceMeters: Value(km * 1000),
        ),
      );

  test('defaults count by sport and date; links win', () async {
    final old = await edits.add(
      kind: 'shoes',
      name: 'Old Pegasus',
      sports: ['running'],
      startKm: 500,
      retireAtKm: 600,
      firstUsed: DateTime(2026, 1, 1),
    );
    final race = await edits.add(
      kind: 'shoes',
      name: 'Race Flats',
      sports: ['running'],
      isDefault: false,
      firstUsed: DateTime(2026, 1, 1),
    );
    await edits.add(
      kind: 'bike',
      name: 'Gravel',
      sports: ['cycling_gravel'],
      firstUsed: DateTime(2026, 1, 1),
    );
    await run('a', DateTime(2026, 3, 1), 50);
    await run('b', DateTime(2026, 3, 2), 46);
    await run('c', DateTime(2026, 3, 3), 10);
    await run('ride', DateTime(2026, 3, 4), 80, type: 'cycling');
    await run('before', DateTime(2025, 12, 1), 30); // before any gear
    await edits.link('c', race);

    final gear = {for (final g in await loadGear(db)) g.name: g};
    expect(gear['Old Pegasus']!.km, 596);
    expect(gear['Old Pegasus']!.wear, GearWear.soon);
    expect(gear['Race Flats']!.km, 10);
    expect(gear['Gravel']!.km, 80); // a ride counts for the bike
    expect(await gearOfActivity(db, 'c'), race);
    expect(await gearOfActivity(db, 'a'), old);
    expect(await gearOfActivity(db, 'before'), isNull);

    await edits.retire(old, at: DateTime(2026, 3, 2));
    final after = {for (final g in await loadGear(db)) g.name: g};
    expect(after['Old Pegasus']!.wear, GearWear.retired);
    expect(
      after['Old Pegasus']!.km,
      550,
    ); // the run on its retiring day is not its
    await edits.link('c', null);
    expect(await gearOfActivity(db, 'c'), isNull); // no default left
  });
}
