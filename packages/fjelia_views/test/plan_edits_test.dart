import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late PlanEdits edits;
  final now = DateTime(2026, 11, 25, 9);
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    edits = PlanEdits(db);
  });
  tearDown(() => db.close());

  Future<TrainingSession> session(
    String id,
    DateTime day, {
    String status = 'planned',
  }) async {
    await db
        .into(db.trainingSessions)
        .insert(
          TrainingSessionsCompanion.insert(
            id: id,
            planId: 'p',
            athleteId: 'self',
            sessionDate: day,
            sessionNumber: 1,
            weekNumber: 1,
            sport: 'running',
            sessionType: 'easy',
            phase: 'base',
            primaryZone: 2,
            title: 'Session $id',
            plannedDurationMin: 50,
            plannedTrimp: 50,
            sessionLevel: 2,
            status: Value(status),
          ),
        );
    return edits.session(id);
  }

  test(
    'a move keeps the first date and refuses days that cannot take it',
    () async {
      final s = await session('s', DateTime(2026, 11, 26));
      final moved = await edits.moveToDate(s, DateTime(2026, 11, 28));
      expect(moved.sessionDate, DateTime(2026, 11, 28));
      expect(moved.sessionDateOriginal, startsWith('2026-11-26'));
      expect(moved.modifiedBy, 'athlete');

      await db
          .into(db.absences)
          .insert(
            AbsencesCompanion.insert(
              kind: 'vacation',
              startDay: DateTime(2026, 11, 30),
              endDay: DateTime(2026, 12, 2),
              createdAt: now,
            ),
          );
      await expectLater(
        edits.moveToDate(moved, DateTime(2026, 12, 1)),
        throwsA(
          isA<AbsenceRefused>().having((e) => e.kind, 'kind', 'vacation'),
        ),
      );
      await db
          .into(db.raceGoals)
          .insert(
            RaceGoalsCompanion.insert(
              id: 'g',
              athleteId: 'self',
              name: 'Nikolauslauf',
              primarySport: 'running',
              distanceM: 10000,
              raceDate: DateTime(2026, 12, 6),
              priority: 'A',
              source: 'athlete',
              createdAt: now,
            ),
          );
      await expectLater(
        edits.moveToDate(moved, DateTime(2026, 12, 5)), // the day before
        throwsA(isA<EventDayRefused>()),
      );
      final done = await session(
        'd',
        DateTime(2026, 11, 24),
        status: 'completed',
      );
      await expectLater(
        edits.moveToDate(done, DateTime(2026, 11, 27)),
        throwsA(isA<DoneRefused>()),
      );
    },
  );

  test('copy, rest, restore and notes', () async {
    final s = await session('s', DateTime(2026, 11, 26));
    final copy = await edits.copyToDate(s, DateTime(2026, 11, 27));
    expect(copy.id, isNot('s'));
    expect(copy.title, 'Session s');
    expect(copy.addedByAthlete, isTrue);
    final rest = await edits.markRest(s);
    expect(rest.status, 'skipped');
    expect((await edits.restore(rest)).status, 'planned');
    expect(
      (await edits.setNotes(s, ' Legs heavy ')).athleteNotes,
      'Legs heavy',
    );
    await edits.delete(copy);
    expect(await db.select(db.trainingSessions).get(), hasLength(1));
  });

  test('a plan moves as one piece, or not at all', () async {
    for (var i = 0; i < 5; i++) {
      await session('s$i', DateTime(2026, 11, 26 + i * 2));
    }
    await session('done', DateTime(2026, 11, 24), status: 'completed');
    expect(await edits.shiftPlan('p', 7, from: DateTime(2026, 11, 25)), 5);
    final dates = [
      for (final s in await (db.select(
        db.trainingSessions,
      )..orderBy([(t) => OrderingTerm(expression: t.sessionDate)])).get())
        s.sessionDate.day,
    ];
    expect(dates, [24, 3, 5, 7, 9, 11]);
    await db
        .into(db.absences)
        .insert(
          AbsencesCompanion.insert(
            kind: 'illness',
            startDay: DateTime(2026, 12, 12),
            endDay: DateTime(2026, 12, 12),
            createdAt: now,
          ),
        );
    await expectLater(
      edits.shiftPlan('p', 3, from: DateTime(2026, 11, 25)),
      throwsA(isA<PlanShiftRefused>()),
    );
    final after = await (db.select(
      db.trainingSessions,
    )..orderBy([(t) => OrderingTerm(expression: t.sessionDate)])).get();
    expect([for (final s in after) s.sessionDate.day], dates); // unchanged
  });

  test(
    'a week copies into another, leaving out days that cannot take it',
    () async {
      await session('a', DateTime(2026, 11, 23));
      await session('b', DateTime(2026, 11, 25));
      await db
          .into(db.absences)
          .insert(
            AbsencesCompanion.insert(
              kind: 'vacation',
              startDay: DateTime(2026, 12, 2),
              endDay: DateTime(2026, 12, 2),
              createdAt: now,
            ),
          );
      final copies = await edits.copyWeek(
        DateTime(2026, 11, 23),
        DateTime(2026, 11, 30),
      );
      expect(copies.single.sessionDate, DateTime(2026, 11, 30));
    },
  );

  test('build a workout, save it to the library and plan it again', () async {
    const draft = WorkoutDraft([
      DraftStep(kind: DraftStepKind.warmup, zone: 1, seconds: 600),
      DraftRepeat(
        times: 4,
        steps: [
          DraftStep(kind: DraftStepKind.interval, zone: 4, seconds: 300),
          DraftStep(kind: DraftStepKind.recovery, zone: 1, seconds: 120),
        ],
      ),
      DraftStep(kind: DraftStepKind.cooldown, zone: 1, seconds: 300),
    ]);
    final made = await edits.create(
      DateTime(2026, 11, 27),
      sport: 'running',
      title: 'Threshold 4 × 5 min',
      draft: draft,
    );
    expect(made.plannedDurationMin, 43);
    expect(made.addedByAthlete, isTrue);
    expect(made.plannedTrimp, greaterThan(43));
    final shorter = await edits.setSteps(made, WorkoutDraft.starter);
    expect(shorter.plannedDurationMin, 45);
    expect(shorter.primaryZone, 2);

    final id = await edits.saveToLibrary(
      name: 'Threshold 4 × 5 min',
      sport: 'running',
      draft: draft,
    );
    final library = await loadWorkoutLibrary(db);
    expect(library['running']!.single.durationMin, 43);
    final planned = await edits.planFromLibrary(id, DateTime(2026, 12, 1));
    expect(planned.title, 'Threshold 4 × 5 min');
    expect(planned.sessionDate, DateTime(2026, 12, 1));
  });
}
