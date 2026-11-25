import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 25, 9);
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('health shows the latest value against the week before', () async {
    for (var i = 0; i < 10; i++) {
      await db
          .into(db.hrvRecords)
          .insert(
            HrvRecordsCompanion.insert(
              date: DateTime(2026, 11, 16 + i),
              hrvLastNight: Value(i == 9 ? 50.0 : 60.0),
              restingHeartRate: const Value(48),
            ),
          );
    }
    await db
        .into(db.sleepRecords)
        .insert(
          SleepRecordsCompanion.insert(
            date: DateTime(2026, 11, 25),
            totalSleepSeconds: 7 * 3600,
            deepSleepSeconds: 3600,
            remSleepSeconds: 5400,
            lightSleepSeconds: 14400,
            awakeSleepSeconds: 1800,
          ),
        );
    final view = await loadHealth(db, now: now);
    expect(view.isEmpty, isFalse);
    expect(view.hrv.latest?.$2, 50);
    expect(view.hrv.weekBefore, 60);
    expect(view.hrv.change, -10);
    expect(view.restingHr.change, 0);
    expect(view.nights.single.total, const Duration(hours: 7));
    expect(view.sleepHours.latest?.$2, 7);
    expect(
      (await loadHealth(
        AppDatabase(NativeDatabase.memory()),
        now: now,
      )).isEmpty,
      isTrue,
    );
  });

  test('the diary gathers notes from everywhere, newest first', () async {
    await db
        .into(db.activityRecords)
        .insert(
          ActivityRecordsCompanion.insert(
            activityId: 'a1',
            name: 'Long Run',
            type: 'running',
            startDate: DateTime(2026, 11, 22, 8),
            durationSeconds: 7200,
            athleteNote: const Value('Calves tight after 25 km'),
          ),
        );
    await db
        .into(db.activityRecords)
        .insert(
          ActivityRecordsCompanion.insert(
            activityId: 'a2',
            name: 'Easy Run',
            type: 'running',
            startDate: DateTime(2026, 11, 23, 8),
            durationSeconds: 3600,
          ),
        );
    await db
        .into(db.absences)
        .insert(
          AbsencesCompanion.insert(
            kind: 'illness',
            startDay: DateTime(2026, 11, 10),
            endDay: DateTime(2026, 11, 12),
            createdAt: now,
            note: const Value('Cold, slept a lot'),
          ),
        );
    await db
        .into(db.coachMemories)
        .insert(
          CoachMemoriesCompanion.insert(
            id: 'm',
            title: 'Knees',
            body: 'No more than 2 runs in a row on asphalt.',
            createdAt: DateTime(2026, 11, 24),
            updatedAt: DateTime(2026, 11, 24),
          ),
        );
    final all = await loadDiary(db);
    expect(all.map((e) => e.kind), [
      DiaryKind.coachNote,
      DiaryKind.activity,
      DiaryKind.absence,
    ]);
    expect(all[1].activityId, 'a1');
    expect((await loadDiary(db, query: 'calves')).single.title, 'Long Run');
    expect(
      (await loadDiary(db, query: 'long run')).single.kind,
      DiaryKind.activity,
    );
    expect(
      (await loadDiary(db, kinds: {DiaryKind.absence})).single.text,
      'Cold, slept a lot',
    );
  });
}
