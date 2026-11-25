/// One change of one record, as it travels between an athlete's devices.
library;

import 'dart:convert';

import 'sync_tables.dart';

enum SyncOp { upsert, delete }

/// The newest state of one record: its row after an upsert, or a tombstone
/// after a delete. A device's change log keeps one per record, numbered by
/// [seq] in the order the device last changed it, so "everything after
/// seq N" is all a peer needs to catch up.
class SyncChange {
  const SyncChange({
    required this.seq,
    required this.table,
    required this.key,
    required this.op,
    required this.category,
    required this.athleteId,
    required this.changedAt,
    this.originDevice,
    this.row,
  });

  /// Position in the sending device's log.
  final int seq;
  final String table;

  /// The record's identity across devices: its natural key values, or its
  /// one sync id.
  final List<Object?> key;
  final SyncOp op;
  final SyncCategory category;

  /// Whose data this is.
  final String athleteId;
  final DateTime changedAt;

  /// The device the change was made on; null for the device holding the log.
  final String? originDevice;

  /// Column values by SQL name, without device-numbered ids, for an upsert.
  /// A column holding another table's row id carries that row's sync id.
  final Map<String, Object?>? row;

  /// [key] as stored in the log, a JSON array.
  String get keyText => jsonEncode(key);

  Map<String, Object?> toJson() => {
    'seq': seq,
    'table': table,
    'key': key,
    'op': op.name,
    'category': category.name,
    'athlete': athleteId,
    'at': changedAt.millisecondsSinceEpoch,
    'origin': ?originDevice,
    if (row != null)
      'row': {for (final e in row!.entries) e.key: _finite(e.value)},
  };

  factory SyncChange.fromJson(Map<String, Object?> json) => SyncChange(
    seq: json['seq']! as int,
    table: json['table']! as String,
    key: List<Object?>.from(json['key']! as List),
    op: SyncOp.values.byName(json['op']! as String),
    category: SyncCategory.values.byName(json['category']! as String),
    athleteId: json['athlete']! as String,
    changedAt: DateTime.fromMillisecondsSinceEpoch(json['at']! as int),
    originDevice: json['origin'] as String?,
    row: (json['row'] as Map?)?.cast<String, Object?>(),
  );

  // JSON has no infinity; SQLite turns NaN into NULL already.
  static Object? _finite(Object? v) => v is double && !v.isFinite ? null : v;
}
