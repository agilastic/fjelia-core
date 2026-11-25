import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a run test is kept, analysed and put into the thresholds', () async {
    final edits = LabTestEdits(db);
    await edits.add(
      date: DateTime(2026, 11, 20),
      sport: 'running',
      steps: const [
        LactateStep(intensity: 2.78, lactate: 1.2, heartRate: 128),
        LactateStep(intensity: 3.06, lactate: 1.1, heartRate: 137),
        LactateStep(intensity: 3.33, lactate: 1.5, heartRate: 146),
        LactateStep(intensity: 3.61, lactate: 2.3, heartRate: 157),
        LactateStep(intensity: 3.89, lactate: 3.9, heartRate: 168),
        LactateStep(intensity: 4.17, lactate: 6.8, heartRate: 179),
      ],
      note: 'Sports clinic',
    );
    final test = (await loadLabTests(db)).single;
    expect(test.result?.lt1, isNotNull);
    expect(test.result?.lt2, isNotNull);
    expect(await edits.useAsThresholds(test), isTrue);
    final record = (await db.select(db.thresholdRecords).get()).single;
    expect(record.source, 'lab');
    expect(record.ftpWatts, isNull);
    // About 4:15 to 4:40 per km.
    expect(record.lt2PaceSec, inInclusiveRange(255, 280));
    expect(record.lt2Bpm, greaterThan(record.lt1Bpm!));
    await edits.delete(test.id);
    expect(await loadLabTests(db), isEmpty);
  });
}
