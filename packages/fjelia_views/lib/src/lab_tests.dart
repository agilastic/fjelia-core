import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:fjelia_core/services/lactate_test.dart';
import 'package:fjelia_data/database.dart';

/// A lactate test with the thresholds worked out from it.
class LabTestItem {
  const LabTestItem({
    required this.id,
    required this.date,
    required this.sport,
    required this.steps,
    this.result,
    this.note,
  });

  final String id;
  final DateTime date;

  /// `cycling` (watts) or `running` (metres per second).
  final String sport;
  final List<LactateStep> steps;

  /// Null with fewer than three usable steps.
  final LactateResult? result;
  final String? note;

  bool get isRide => sport == 'cycling';
}

/// The lab tests, newest first.
Future<List<LabTestItem>> loadLabTests(AppDatabase db) async => [
  for (final t in await (db.select(
    db.labTests,
  )..orderBy([(t) => OrderingTerm.desc(t.date)])).get())
    () {
      final steps = _steps(t.stepsJson);
      return LabTestItem(
        id: t.id,
        date: t.date.toLocal(),
        sport: t.sport,
        steps: steps,
        result: analyseLactate(steps),
        note: t.note,
      );
    }(),
];

List<LactateStep> _steps(String json) {
  try {
    return [for (final s in jsonDecode(json) as List) ?LactateStep.fromJson(s)];
  } on Object {
    return const [];
  }
}

/// Lab tests: kept, deleted, and their thresholds put to use.
class LabTestEdits {
  LabTestEdits(this.db);
  final AppDatabase db;

  Future<String> add({
    required DateTime date,
    required String sport,
    required List<LactateStep> steps,
    String? note,
  }) async {
    final id = _newId();
    await db
        .into(db.labTests)
        .insert(
          LabTestsCompanion.insert(
            id: id,
            date: date,
            sport: sport,
            stepsJson: jsonEncode([for (final s in steps) s.toJson()]),
            note: Value(note),
            createdAt: DateTime.now(),
          ),
        );
    return id;
  }

  Future<void> delete(String id) =>
      (db.delete(db.labTests)..where((t) => t.id.equals(id))).go();

  /// Puts the test's thresholds into the threshold history, as measured in
  /// a lab on the test's day: LT1 and LT2 heart rate, and LT2 as power on
  /// a bike or pace running. Returns false when the test has no LT2.
  Future<bool> useAsThresholds(LabTestItem test) async {
    final lt2 = test.result?.lt2;
    if (lt2 == null) return false;
    final lt1 = test.result?.lt1;
    await db
        .into(db.thresholdRecords)
        .insert(
          ThresholdRecordsCompanion.insert(
            date: test.date,
            activityId: 'lab:${test.id}',
            source: 'lab',
            lt1Bpm: Value(lt1?.heartRate?.round()),
            lt2Bpm: Value(lt2.heartRate?.round()),
            ftpWatts: Value(test.isRide ? lt2.intensity.round() : null),
            lt2PaceSec: Value(
              test.isRide || lt2.intensity <= 0
                  ? null
                  : (1000 / lt2.intensity).round(),
            ),
          ),
        );
    return true;
  }

  static final _random = Random.secure();
  static String _newId() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}
