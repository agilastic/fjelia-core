import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fjelia_core/models/strength_workout.dart';
import 'package:fjelia_data/database.dart';

/// Who a planned strength document belongs to. Never a date or a title.
class StrengthPlanOwner {
  const StrengthPlanOwner(this.kind, this.key);

  /// An app-planned session.
  factory StrengthPlanOwner.session(String sessionId) =>
      StrengthPlanOwner('session', sessionId);

  /// One scheduled occurrence of a provider workout; a repeated workout
  /// definition is not one shared session.
  factory StrengthPlanOwner.scheduled(String provider, String scheduleId) =>
      StrengthPlanOwner('scheduled', '$provider:$scheduleId');

  /// The athlete's own reusable template.
  factory StrengthPlanOwner.template(String id) =>
      StrengthPlanOwner('template', id);

  final String kind, key;

  @override
  bool operator ==(Object other) =>
      other is StrengthPlanOwner && other.kind == kind && other.key == key;
  @override
  int get hashCode => Object.hash(kind, key);
  @override
  String toString() => '$kind:$key';
}

/// A saved plan revision.
class StoredStrengthPlan {
  const StoredStrengthPlan({
    required this.owner,
    required this.revisionId,
    required this.revision,
    required this.plan,
  });
  final StrengthPlanOwner owner;
  final String revisionId;
  final int revision;
  final StrengthWorkoutPlan plan;
}

/// Why a plan was not saved. The apps word it.
sealed class StrengthPlanRefused implements Exception {
  const StrengthPlanRefused();
}

/// The plan has problems ([issues]) or no exercise at all ([empty]).
class StrengthPlanInvalid extends StrengthPlanRefused {
  const StrengthPlanInvalid(this.issues, {this.empty = false});
  final List<StrengthIssue> issues;
  final bool empty;
}

/// A save based on an outdated revision: the plan was changed elsewhere,
/// such as on the other device. The draft is the caller's to keep.
class StrengthPlanConflict extends StrengthPlanRefused {
  const StrengthPlanConflict();
}

/// Stored strength data that cannot be read. It is never overwritten by an
/// empty replacement. [detail] is the parser's message, when it has one.
class StrengthPlanUnreadable extends StrengthPlanRefused {
  const StrengthPlanUnreadable([this.detail]);
  final String? detail;
}

/// Planned strength workouts, one revision history per owner. The phone's
/// editor and the computer's builder save through this.
class StrengthPlans {
  StrengthPlans(this.db);
  final AppDatabase db;

  /// The current plan of [owner], or null when none was saved.
  /// Throws [StrengthPlanUnreadable] for a malformed stored document.
  Future<StoredStrengthPlan?> load(StrengthPlanOwner owner) async {
    final head =
        await (db.select(db.strengthPlanHeads)..where(
              (t) =>
                  t.ownerKind.equals(owner.kind) & t.ownerKey.equals(owner.key),
            ))
            .getSingleOrNull();
    if (head == null) return null;
    return revision(head.revisionId);
  }

  Future<StoredStrengthPlan?> revision(String revisionId) async {
    final row = await (db.select(
      db.strengthPlanRevisions,
    )..where((t) => t.revisionId.equals(revisionId))).getSingleOrNull();
    if (row == null) return null;
    return StoredStrengthPlan(
      owner: StrengthPlanOwner(row.ownerKind, row.ownerKey),
      revisionId: row.revisionId,
      revision: row.revision,
      plan: _decode(row.planJson),
    );
  }

  static StrengthWorkoutPlan _decode(String json) {
    try {
      return StrengthWorkoutPlan.fromJson(jsonDecode(json) as Map);
    } on FormatException catch (e) {
      throw StrengthPlanUnreadable(e.message);
    } on TypeError {
      throw const StrengthPlanUnreadable();
    }
  }

  /// Saves [plan] as the next revision of [owner], atomically with its head.
  /// [expectedRevision] is the revision the editor started from (0 for none).
  Future<StoredStrengthPlan> save(
    StrengthPlanOwner owner,
    StrengthWorkoutPlan plan, {
    required int expectedRevision,
  }) async {
    final issues = plan.issues();
    if (plan.isEmpty || issues.isNotEmpty) {
      throw StrengthPlanInvalid(issues, empty: plan.isEmpty);
    }
    return db.transaction(() async {
      final head =
          await (db.select(db.strengthPlanHeads)..where(
                (t) =>
                    t.ownerKind.equals(owner.kind) &
                    t.ownerKey.equals(owner.key),
              ))
              .getSingleOrNull();
      final current = head?.revision ?? 0;
      if (current != expectedRevision) throw const StrengthPlanConflict();
      final now = DateTime.now();
      final id = newStrengthId('rev');
      final next = current + 1;
      await db
          .into(db.strengthPlanRevisions)
          .insert(
            StrengthPlanRevisionsCompanion.insert(
              revisionId: id,
              ownerKind: owner.kind,
              ownerKey: owner.key,
              revision: next,
              schemaVersion: plan.schemaVersion,
              planJson: jsonEncode(plan.toJson()),
              createdAt: now,
            ),
          );
      await db
          .into(db.strengthPlanHeads)
          .insertOnConflictUpdate(
            StrengthPlanHeadsCompanion.insert(
              ownerKind: owner.kind,
              ownerKey: owner.key,
              revisionId: id,
              revision: next,
              updatedAt: now,
            ),
          );
      return StoredStrengthPlan(
        owner: owner,
        revisionId: id,
        revision: next,
        plan: plan,
      );
    });
  }

  /// The athlete's saved templates; unreadable ones are left out.
  Future<List<StoredStrengthPlan>> templates() async {
    final heads = await (db.select(
      db.strengthPlanHeads,
    )..where((t) => t.ownerKind.equals('template'))).get();
    final out = <StoredStrengthPlan>[];
    for (final h in heads) {
      try {
        final p = await revision(h.revisionId);
        if (p != null) out.add(p);
      } on StrengthPlanUnreadable {
        continue;
      }
    }
    return out;
  }

  /// Every exercise to choose from: the built-in ones, then the athlete's
  /// own that are not archived.
  Future<List<StrengthExerciseVariant>> exercises() async => [
    ...builtInStrengthVariants,
    ...await customExercises(),
  ];

  Future<List<StrengthExerciseVariant>> customExercises() async {
    final rows = await (db.select(
      db.strengthExerciseVariants,
    )..where((t) => t.archived.equals(false))).get();
    return [
      for (final r in rows)
        StrengthExerciseVariant(
          id: r.id,
          name: r.name,
          equipment: r.equipment,
          convention: StrengthConvention.fromJson(jsonDecode(r.conventionJson)),
          timed: r.timed,
        ),
    ];
  }

  /// A new custom exercise with a fresh id; ids are never reused. A blank
  /// [name] is refused with [ArgumentError].
  Future<StrengthExerciseVariant> addCustomExercise({
    required String name,
    required String equipment,
    StrengthConvention convention = const StrengthConvention(),
    bool timed = false,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError.value(name, 'name');
    final v = StrengthExerciseVariant(
      id: newStrengthId('custom'),
      name: name.trim(),
      equipment: equipment.trim(),
      convention: convention,
      timed: timed,
    );
    await db
        .into(db.strengthExerciseVariants)
        .insert(
          StrengthExerciseVariantsCompanion.insert(
            id: v.id,
            name: v.name,
            equipment: v.equipment,
            conventionJson: jsonEncode(convention.toJson()),
            timed: Value(timed),
            createdAt: DateTime.now(),
          ),
        );
    return v;
  }

  /// Hides a custom exercise from the picker; history keeps its snapshots.
  Future<void> archiveCustomExercise(String id) =>
      (db.update(
        db.strengthExerciseVariants,
      )..where((t) => t.id.equals(id))).write(
        const StrengthExerciseVariantsCompanion(archived: Value(true)),
      );
}
