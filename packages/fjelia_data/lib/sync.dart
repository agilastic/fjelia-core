/// The change log that lets an athlete's devices sync.
///
/// Triggers on every synced table (see `fjelia_core`'s `syncTables`) record
/// the newest change of each record in `sync_changes`. A peer asks for
/// everything after the last `seq` it has; the first sync starts at 0, which
/// returns every record because opening the log once records them all.
///
/// The log's tables are plain SQL, not Drift tables: they belong to the
/// device, so backups neither carry nor restore them. A restore rewrites the
/// data tables through the triggers, which is exactly the change peers need.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fjelia_core/services/sync/sync_change.dart';
import 'package:fjelia_core/services/sync/sync_tables.dart';

import 'database.dart';

/// SQL for a random version 4 UUID, evaluated per row.
const uuidSql =
    "lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-4'||"
    "substr(lower(hex(randomblob(2))),2)||'-'||"
    "substr('89ab',abs(random())%4+1,1)||"
    "substr(lower(hex(randomblob(2))),2)||'-'||lower(hex(randomblob(6)))";

const _nowMs = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

const _schema = [
  // seq grows with every change; REPLACE on (record_table, record_key)
  // moves a record to the end instead of keeping its history.
  'CREATE TABLE IF NOT EXISTS sync_changes ('
      'seq INTEGER PRIMARY KEY AUTOINCREMENT, '
      'record_table TEXT NOT NULL, record_key TEXT NOT NULL, '
      'op TEXT NOT NULL, category TEXT NOT NULL, athlete_id TEXT NOT NULL, '
      'origin_device TEXT, changed_at_ms INTEGER NOT NULL, '
      'UNIQUE (record_table, record_key))',
  'CREATE TABLE IF NOT EXISTS sync_row_ids ('
      'record_table TEXT NOT NULL, row_id INTEGER NOT NULL, '
      'sync_id TEXT NOT NULL, PRIMARY KEY (record_table, row_id), '
      'UNIQUE (record_table, sync_id))',
  // One row. `applying` silences the triggers while received changes are
  // written; it lives in the same transaction, so a crash cannot leave it on.
  'CREATE TABLE IF NOT EXISTS sync_state ('
      'id INTEGER PRIMARY KEY CHECK (id = 1), athlete_id TEXT NOT NULL, '
      'log_epoch TEXT NOT NULL, applying INTEGER NOT NULL DEFAULT 0)',
  // Paired devices: whose certificate to trust and how far each one's log
  // has been received.
  'CREATE TABLE IF NOT EXISTS sync_peers ('
      'device_id TEXT PRIMARY KEY, name TEXT NOT NULL, '
      'certificate_sha256 TEXT NOT NULL, paired_at_ms INTEGER NOT NULL, '
      'categories TEXT NOT NULL, peer_log_epoch TEXT, '
      'received_seq INTEGER NOT NULL DEFAULT 0)',
];

/// The identity of [t]'s row, as SQL over the row alias [r] (NEW, OLD or the
/// table itself).
String _keySql(SyncTable t, String r) => t.hasSyncId
    ? "json_array((SELECT sync_id FROM sync_row_ids "
          "WHERE record_table = '${t.name}' AND row_id = $r.${t.rowId}))"
    : 'json_array(${[for (final c in t.key) '$r.$c'].join(', ')})';

/// Records [op] of the row [r] of [t] in the log, unless changes are being
/// applied. The record's earlier entry is deleted first: inside a trigger
/// an `OR REPLACE` gives way to the conflict rule of the statement that
/// fired it, such as an upsert's.
String _logSql(SyncTable t, String r, SyncOp op, {String where = ''}) =>
    "DELETE FROM sync_changes WHERE record_table = '${t.name}' "
    'AND record_key = ${_keySql(t, r)} '
    'AND (SELECT applying FROM sync_state) = 0$where; '
    'INSERT INTO sync_changes (record_table, record_key, op, '
    'category, athlete_id, origin_device, changed_at_ms) '
    "SELECT '${t.name}', ${_keySql(t, r)}, '${op.name}', "
    "'${t.category.name}', athlete_id, NULL, $_nowMs FROM sync_state "
    'WHERE applying = 0$where';

String _mapIdSql(SyncTable t, String r) =>
    'INSERT INTO sync_row_ids (record_table, row_id, sync_id) '
    "SELECT '${t.name}', $r.${t.rowId}, $uuidSql FROM sync_state "
    'WHERE applying = 0 AND NOT EXISTS (SELECT 1 FROM sync_row_ids '
    "WHERE record_table = '${t.name}' AND row_id = $r.${t.rowId})";

/// The triggers of [t] by name.
Map<String, String> _triggers(SyncTable t) {
  final n = t.name;
  final keyChanged = ' AND ${_keySql(t, 'OLD')} IS NOT ${_keySql(t, 'NEW')}';
  return {
    'sync_${n}_insert':
        'CREATE TRIGGER sync_${n}_insert AFTER INSERT ON $n BEGIN '
        '${t.hasSyncId ? '${_mapIdSql(t, 'NEW')}; ' : ''}'
        '${_logSql(t, 'NEW', SyncOp.upsert)}; END',
    'sync_${n}_update':
        'CREATE TRIGGER sync_${n}_update AFTER UPDATE ON $n BEGIN '
        '${t.hasSyncId ? '${_mapIdSql(t, 'NEW')}; ' : ''}'
        '${_logSql(t, 'OLD', SyncOp.delete, where: keyChanged)}; '
        '${_logSql(t, 'NEW', SyncOp.upsert)}; END',
    'sync_${n}_delete':
        'CREATE TRIGGER sync_${n}_delete AFTER DELETE ON $n BEGIN '
        '${_logSql(t, 'OLD', SyncOp.delete)}; '
        '${t.hasSyncId ? "DELETE FROM sync_row_ids WHERE record_table = '$n' "
                  'AND row_id = OLD.${t.rowId} AND '
                  '(SELECT applying FROM sync_state) = 0; ' : ''}'
        'END',
  };
}

extension SyncStore on AppDatabase {
  /// Creates the log and brings its triggers up to date. On the first open
  /// it also gives this database's data an athlete id and records every
  /// existing row, so a new peer receives everything. Safe to repeat.
  Future<void> installSync() async {
    for (final sql in _schema) {
      await customStatement(sql);
    }
    final existing = {
      for (final r in await customSelect(
        "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' "
        "AND name LIKE 'sync\\_%' ESCAPE '\\'",
      ).get())
        r.read<String>('name'): r.read<String>('sql'),
    };
    final wanted = {for (final t in syncTables) ..._triggers(t)};
    for (final name in existing.keys) {
      if (existing[name] != wanted[name]) {
        await customStatement('DROP TRIGGER $name');
      }
    }
    for (final MapEntry(:key, :value) in wanted.entries) {
      if (existing[key] != value) await customStatement(value);
    }
    final started = await customSelect('SELECT 1 FROM sync_state')
        .getSingleOrNull();
    if (started == null) {
      await transaction(() async {
        await customStatement(
          'INSERT INTO sync_state (id, athlete_id, log_epoch) '
          'VALUES (1, $uuidSql, $uuidSql)',
        );
        for (final t in syncTables) {
          if (t.hasSyncId) {
            await customStatement(
              'INSERT OR IGNORE INTO sync_row_ids '
              "SELECT '${t.name}', ${t.rowId}, $uuidSql FROM ${t.name}",
            );
          }
          await customStatement(
            'INSERT OR IGNORE INTO sync_changes (record_table, record_key, '
            'op, category, athlete_id, origin_device, changed_at_ms) '
            "SELECT '${t.name}', ${_keySql(t, t.name)}, 'upsert', "
            "'${t.category.name}', (SELECT athlete_id FROM sync_state), "
            'NULL, $_nowMs FROM ${t.name}',
          );
        }
      });
    }
  }

  /// The athlete whose data this database holds.
  Future<String> syncAthleteId() async => (await customSelect(
    'SELECT athlete_id FROM sync_state',
  ).getSingle()).read<String>('athlete_id');

  /// Identifies this log. A peer that kept a `seq` from another epoch starts
  /// again at 0.
  Future<String> syncLogEpoch() async => (await customSelect(
    'SELECT log_epoch FROM sync_state',
  ).getSingle()).read<String>('log_epoch');

  /// The newest `seq` in the log, 0 when it is empty.
  Future<int> syncHeadSeq() async => (await customSelect(
    'SELECT COALESCE(MAX(seq), 0) AS s FROM sync_changes',
  ).getSingle()).read<int>('s');

  /// Up to [limit] changes after [afterSeq] in [categories], each upsert
  /// with its current row. Tables sent [SyncTable.onRequest] are left out
  /// unless [onRequest] is set.
  Future<List<SyncChange>> syncChangesSince(
    int afterSeq, {
    int limit = 500,
    Set<SyncCategory> categories = const {...SyncCategory.values},
    bool onRequest = false,
  }) => transaction(() async {
    final tables = [
      for (final t in syncTables)
        if (categories.contains(t.category) && (onRequest || !t.onRequest))
          "'${t.name}'",
    ];
    if (tables.isEmpty) return const [];
    final rows = await customSelect(
      'SELECT * FROM sync_changes WHERE seq > ? '
      'AND record_table IN (${tables.join(', ')}) ORDER BY seq LIMIT ?',
      variables: [Variable.withInt(afterSeq), Variable.withInt(limit)],
    ).get();
    return [
      for (final r in rows)
        SyncChange(
          seq: r.read<int>('seq'),
          table: r.read<String>('record_table'),
          key: List<Object?>.from(
            jsonDecode(r.read<String>('record_key')) as List,
          ),
          op: SyncOp.values.byName(r.read<String>('op')),
          category: SyncCategory.values.byName(r.read<String>('category')),
          athleteId: r.read<String>('athlete_id'),
          changedAt: DateTime.fromMillisecondsSinceEpoch(
            r.read<int>('changed_at_ms'),
          ),
          originDevice: r.readNullable<String>('origin_device'),
          row: r.read<String>('op') == SyncOp.upsert.name
              ? await _outgoingRow(
                  syncTableNamed(r.read<String>('record_table'))!,
                  jsonDecode(r.read<String>('record_key')) as List,
                )
              : null,
        ),
    ];
  });

  /// Writes changes received from [fromDevice]. Each is logged here as made
  /// on its origin device, so it is not sent back there.
  ///
  /// The desktop of the first release only receives, so a received change
  /// always wins; weighing [SyncMerge] against local edits comes with
  /// editing on more than one device.
  Future<void> applySyncChanges(
    List<SyncChange> changes, {
    required String fromDevice,
  }) => transaction(() async {
    await customStatement('UPDATE sync_state SET applying = 1');
    final columns = <String, Set<String>>{};
    for (final c in changes) {
      final t = syncTableNamed(c.table);
      if (t == null) continue; // a newer peer's table this version lacks
      final local = columns[t.name] ??= {
        for (final r in await customSelect(
          'PRAGMA table_info("${t.name}")',
        ).get())
          r.read<String>('name'),
      };
      if (c.op == SyncOp.delete) {
        await _deleteRow(t, c.key);
      } else {
        await _writeRow(t, c.key, c.row ?? const {}, local);
      }
      await customStatement(
        'INSERT OR REPLACE INTO sync_changes (record_table, record_key, op, '
        'category, athlete_id, origin_device, changed_at_ms) '
        'VALUES (?, json(?), ?, ?, ?, ?, ?)',
        [
          t.name,
          c.keyText,
          c.op.name,
          t.category.name,
          c.athleteId,
          c.originDevice ?? fromDevice,
          c.changedAt.millisecondsSinceEpoch,
        ],
      );
    }
    await customStatement('UPDATE sync_state SET applying = 0');
    markTablesUpdated(allTables);
  });

  Future<int?> _rowIdFor(String table, Object? syncId) async =>
      (await customSelect(
        'SELECT row_id FROM sync_row_ids '
        'WHERE record_table = ? AND sync_id = ?',
        variables: [Variable(table), Variable(syncId)],
      ).getSingleOrNull())?.read<int>('row_id');

  Future<Object?> _syncIdFor(String table, Object? rowId) async =>
      (await customSelect(
        'SELECT sync_id FROM sync_row_ids '
        'WHERE record_table = ? AND row_id = ?',
        variables: [Variable(table), Variable(rowId)],
      ).getSingleOrNull())?.read<String>('sync_id');

  /// Where clause and values that find [key] in [t].
  Future<(String, List<Object?>)?> _where(SyncTable t, List key) async {
    if (!t.hasSyncId) {
      return (t.key.map((c) => '"$c" = ?').join(' AND '), [...key]);
    }
    final id = await _rowIdFor(t.name, key.single);
    return id == null ? null : ('"${t.rowId}" = ?', <Object?>[id]);
  }

  Future<Map<String, Object?>?> _outgoingRow(SyncTable t, List key) async {
    final where = await _where(t, key);
    if (where == null) return null;
    final row = await customSelect(
      'SELECT * FROM "${t.name}" WHERE ${where.$1}',
      variables: [for (final v in where.$2) Variable(v)],
    ).getSingleOrNull();
    if (row == null) return null;
    final data = Map<String, Object?>.of(row.data)..remove(t.rowId);
    for (final MapEntry(key: column, value: target) in t.localRefs.entries) {
      data[column] = await _syncIdFor(target, data[column]);
    }
    return data;
  }

  Future<void> _deleteRow(SyncTable t, List key) async {
    final where = await _where(t, key);
    if (where == null) return;
    await customStatement('DELETE FROM "${t.name}" WHERE ${where.$1}', [
      ...where.$2,
    ]);
    if (t.hasSyncId) {
      await customStatement(
        'DELETE FROM sync_row_ids WHERE record_table = ? AND sync_id = ?',
        [t.name, key.single],
      );
    }
  }

  Future<void> _writeRow(
    SyncTable t,
    List key,
    Map<String, Object?> incoming,
    Set<String> local,
  ) async {
    final row = <String, Object?>{
      for (final e in incoming.entries)
        if (local.contains(e.key) && e.key != t.rowId) e.key: e.value,
    };
    if (row.isEmpty) return;
    for (final MapEntry(key: column, value: target) in t.localRefs.entries) {
      if (row.containsKey(column)) {
        row[column] = await _rowIdFor(target, row[column]);
      }
    }
    final names = row.keys.map((c) => '"$c"').join(', ');
    final marks = List.filled(row.length, '?').join(', ');
    if (!t.hasSyncId) {
      final updates = [
        for (final c in row.keys)
          if (!t.key.contains(c)) '"$c" = excluded."$c"',
      ];
      await customStatement(
        'INSERT INTO "${t.name}" ($names) VALUES ($marks) '
        'ON CONFLICT (${t.key.map((c) => '"$c"').join(', ')}) '
        'DO ${updates.isEmpty ? 'NOTHING' : 'UPDATE SET ${updates.join(', ')}'}',
        [...row.values],
      );
      return;
    }
    final id = await _rowIdFor(t.name, key.single);
    if (id != null) {
      await customStatement(
        'UPDATE "${t.name}" SET '
        '${row.keys.map((c) => '"$c" = ?').join(', ')} '
        'WHERE "${t.rowId}" = ?',
        [...row.values, id],
      );
      return;
    }
    await customStatement('INSERT INTO "${t.name}" ($names) VALUES ($marks)', [
      ...row.values,
    ]);
    await customStatement(
      'INSERT INTO sync_row_ids (record_table, row_id, sync_id) '
      'VALUES (?, last_insert_rowid(), ?)',
      [t.name, key.single],
    );
  }
}
