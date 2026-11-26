import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

/// 10 km due north: 5 km up at 8 %, 5 km back down, a point every 25 m.
String gpx() {
  const metresPerDegree = 111195.0;
  final b = StringBuffer('<gpx version="1.1">');
  b.write(
    '<wpt lat="${5000 / metresPerDegree}" lon="0"><name>Top</name></wpt>',
  );
  b.write('<trk><name>Hill</name><trkseg>');
  for (var m = 0.0; m <= 10000; m += 25) {
    final ele = m <= 5000 ? 100 + m * 0.08 : 500 - (m - 5000) * 0.08;
    b.write(
      '<trkpt lat="${m / metresPerDegree}" lon="0"><ele>$ele</ele></trkpt>',
    );
  }
  return '$b</trkseg></trk></gpx>';
}

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 26);
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.raceGoals)
        .insert(
          RaceGoalsCompanion.insert(
            id: 'g1',
            athleteId: 'self',
            name: 'Hill Race',
            primarySport: 'trail_running',
            distanceM: 10000,
            raceDate: DateTime(2027, 3, 1),
            priority: 'A',
            source: 'manual',
            createdAt: now,
          ),
        );
  });
  tearDown(() => db.close());

  Future<void> run(String id, double grade, double pace) => db
      .into(db.activityRecords)
      .insert(
        ActivityRecordsCompanion.insert(
          activityId: id,
          name: 'Run',
          type: 'trail_running',
          startDate: now.subtract(const Duration(days: 3)),
          durationSeconds: 3600,
          metricsJson: Value(
            jsonEncode([
              for (var s = 0; s <= 3600; s += 10)
                {
                  't': s * 1000,
                  'd': s / pace * 1000,
                  'ele': s / pace * 1000 * grade,
                },
            ]),
          ),
        ),
      );

  test('a course is added, analysed and predicted from own runs', () async {
    final edits = RaceCourseEdits(db);
    await edits.setFromGpx('g1', gpx(), startAt: DateTime(2027, 3, 1, 8));
    await edits.setCheckpoints('g1', [
      CourseCheckpoint(name: 'Top', km: 5, cutoff: DateTime(2027, 3, 1, 9)),
    ]);
    // Without runs there is no own table, so no prediction.
    var view = (await loadRaceCourse(db, 'g1', now: now))!;
    expect(view.profile!.gain, closeTo(400, 10));
    expect(view.prediction, isNull);

    await run('flat', 0, 330);
    await run('hill', 0.08, 480);
    view = (await loadRaceCourse(db, 'g1', now: now))!;
    final legs = view.prediction!.legs;
    expect(legs.map((l) => l.to), ['Top', 'Finish']);
    // 5 km up at the own 8:00/km hill pace: about 40 minutes.
    expect(legs.first.seconds, closeTo(2400, 120));
    // Cut-off an hour after the start: about 20 minutes to spare.
    expect(view.marginAt(legs.first)!.inMinutes, closeTo(20, 3));
  });

  test('checkpoints come from the library\'s aid stations', () {
    final c = checkpointsFromLibrary([
      {'name': 'Les Contamines', 'km': 31.2, 'cutoff': '2026-08-28T22:30:00Z'},
      {'name': 'no distance'},
    ]);
    expect(c.single.name, 'Les Contamines');
    expect(c.single.cutoff, DateTime.utc(2026, 8, 28, 22, 30));
  });

  test(
    'race goals come soonest first, with whether they have a course',
    () async {
      await RaceCourseEdits(db).setFromGpx('g1', gpx());
      final goals = await loadRaceGoals(db, now: now);
      expect(goals.single.goal.name, 'Hill Race');
      expect(goals.single.hasCourse, isTrue);
    },
  );
}
