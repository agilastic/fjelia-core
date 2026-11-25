import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:fjelia_core/services/activity_kind.dart';
import 'package:fjelia_data/database.dart';

/// How worn a piece of equipment is.
enum GearWear {
  fine,

  /// Past 90 % of the distance the athlete set for it.
  soon,

  /// At or past that distance.
  due,
  retired,
}

/// One shoe, bike or other piece of equipment with its distance.
class GearItem {
  const GearItem({
    required this.id,
    required this.kind,
    required this.name,
    required this.sports,
    required this.isDefault,
    required this.startKm,
    required this.firstUsed,
    required this.km,
    required this.activities,
    this.brand,
    this.retireAtKm,
    this.retiredAt,
    this.lastUsed,
    this.notes,
  });

  final String id;

  /// `shoes`, `bike` or `other`.
  final String kind;
  final String name;
  final String? brand;
  final List<String> sports;
  final bool isDefault;
  final double startKm;
  final double? retireAtKm;
  final DateTime firstUsed;
  final DateTime? retiredAt;
  final String? notes;

  /// Its distance: [startKm] and the activities that count for it.
  final double km;
  final int activities;
  final DateTime? lastUsed;

  GearWear get wear {
    if (retiredAt != null) return GearWear.retired;
    final limit = retireAtKm;
    if (limit == null || limit <= 0) return GearWear.fine;
    if (km >= limit) return GearWear.due;
    return km >= limit * 0.9 ? GearWear.soon : GearWear.fine;
  }
}

List<String> _sports(String json) {
  try {
    return [for (final s in jsonDecode(json) as List) '$s'];
  } on Object {
    return const [];
  }
}

/// The gear an activity counts for: the one it is linked to, else the
/// default of its sport that was in use on its day (the newest, if
/// several were).
String? gearOf({
  required String activityType,
  required DateTime start,
  required List<GearRow> gear,
  String? linked,
}) {
  if (linked != null) return linked;
  final kind = activityKind(activityType);
  GearRow? best;
  for (final g in gear) {
    if (!g.isDefault) continue;
    if (start.isBefore(g.firstUsed)) continue;
    final retired = g.retiredAt;
    if (retired != null && !start.isBefore(retired)) continue;
    if (!_sports(g.sportsJson).any((s) => activityKind(s) == kind)) continue;
    if (best == null || g.firstUsed.isAfter(best.firstUsed)) best = g;
  }
  return best?.id;
}

/// All equipment, in use first, each with its distance.
Future<List<GearItem>> loadGear(AppDatabase db) async {
  final gear = await db.select(db.gear).get();
  if (gear.isEmpty) return const [];
  final links = {
    for (final l in await db.select(db.activityGear).get())
      l.activityId: l.gearId,
  };
  final a = db.activityRecords;
  final km = <String, double>{}, count = <String, int>{};
  final last = <String, DateTime>{};
  for (final r in await (db.selectOnly(
    a,
  )..addColumns([a.activityId, a.type, a.startDate, a.distanceMeters])).get()) {
    final start = r.read(a.startDate)!;
    final id = gearOf(
      activityType: r.read(a.type)!,
      start: start,
      gear: gear,
      linked: links[r.read(a.activityId)],
    );
    if (id == null) continue;
    km[id] = (km[id] ?? 0) + (r.read(a.distanceMeters) ?? 0) / 1000;
    count[id] = (count[id] ?? 0) + 1;
    if (last[id] == null || start.isAfter(last[id]!)) last[id] = start;
  }
  final items = [
    for (final g in gear)
      GearItem(
        id: g.id,
        kind: g.kind,
        name: g.name,
        brand: g.brand,
        sports: _sports(g.sportsJson),
        isDefault: g.isDefault,
        startKm: g.startKm,
        retireAtKm: g.retireAtKm,
        firstUsed: g.firstUsed.toLocal(),
        retiredAt: g.retiredAt?.toLocal(),
        notes: g.notes,
        km: g.startKm + (km[g.id] ?? 0),
        activities: count[g.id] ?? 0,
        lastUsed: last[g.id]?.toLocal(),
      ),
  ];
  return items..sort((x, y) {
    final retired =
        (x.retiredAt != null ? 1 : 0) - (y.retiredAt != null ? 1 : 0);
    return retired != 0 ? retired : y.km.compareTo(x.km);
  });
}

/// The gear [activityId] counts for, or null.
Future<String?> gearOfActivity(AppDatabase db, String activityId) async {
  final row = await db.getActivityById(activityId);
  if (row == null) return null;
  final link = await (db.select(
    db.activityGear,
  )..where((l) => l.activityId.equals(activityId))).getSingleOrNull();
  return gearOf(
    activityType: row.type,
    start: row.startDate,
    gear: await db.select(db.gear).get(),
    linked: link?.gearId,
  );
}

/// Changes to equipment, the same on every device.
class GearEdits {
  GearEdits(this.db);
  final AppDatabase db;

  Future<String> add({
    required String kind,
    required String name,
    String? brand,
    List<String> sports = const [],
    bool isDefault = true,
    double startKm = 0,
    double? retireAtKm,
    DateTime? firstUsed,
  }) async {
    final id = _newId();
    await db
        .into(db.gear)
        .insert(
          GearCompanion.insert(
            id: id,
            kind: kind,
            name: name,
            brand: Value(brand),
            sportsJson: Value(jsonEncode(sports)),
            isDefault: Value(isDefault),
            startKm: Value(startKm),
            retireAtKm: Value(retireAtKm),
            firstUsed: firstUsed ?? DateTime.now(),
          ),
        );
    return id;
  }

  Future<void> update(
    String id, {
    String? name,
    String? brand,
    bool? isDefault,
    double? startKm,
    double? retireAtKm,
    String? notes,
  }) => (db.update(db.gear)..where((g) => g.id.equals(id))).write(
    GearCompanion(
      name: name == null ? const Value.absent() : Value(name),
      brand: brand == null ? const Value.absent() : Value(brand),
      isDefault: isDefault == null ? const Value.absent() : Value(isDefault),
      startKm: startKm == null ? const Value.absent() : Value(startKm),
      retireAtKm: retireAtKm == null
          ? const Value.absent()
          : Value(retireAtKm <= 0 ? null : retireAtKm),
      notes: notes == null ? const Value.absent() : Value(notes),
    ),
  );

  /// Retires it from [at] on; activities before stay counted.
  Future<void> retire(String id, {DateTime? at}) =>
      (db.update(db.gear)..where((g) => g.id.equals(id))).write(
        // Default stays: it still counts its activities up to [at].
        GearCompanion(retiredAt: Value(at ?? DateTime.now())),
      );

  /// Uses it again.
  Future<void> reactivate(String id) =>
      (db.update(db.gear)..where((g) => g.id.equals(id))).write(
        const GearCompanion(retiredAt: Value(null)),
      );

  /// Says which gear [activityId] was done with; null goes back to the
  /// default of its sport.
  Future<void> link(String activityId, String? gearId) async {
    if (gearId == null) {
      await (db.delete(
        db.activityGear,
      )..where((l) => l.activityId.equals(activityId))).go();
    } else {
      await db
          .into(db.activityGear)
          .insertOnConflictUpdate(
            ActivityGearCompanion.insert(
              activityId: activityId,
              gearId: gearId,
            ),
          );
    }
  }

  static final _random = Random.secure();
  static String _newId() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}
