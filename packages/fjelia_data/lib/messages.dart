/// Direct messages and coach groups: the events of each thread, the people
/// they are with, and what is still to go out.
///
/// The rules (who may write, add, leave) are fjelia_core's
/// `services/messaging/thread_event.dart`; this keeps the events and the
/// state they make. Plain SQL like the sync log: it belongs to the person's
/// identity, which lives with the device, not in backups.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fjelia_core/services/messaging/thread_event.dart';

import 'database.dart';

const _schema = [
  // The people threads are with, and this device's own person (role self).
  // device_list is their signed list, for encrypting to their devices.
  'CREATE TABLE IF NOT EXISTS msg_people ('
      'person TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL, '
      'device_list TEXT, list_version INTEGER NOT NULL DEFAULT 0, '
      'updated_ms INTEGER NOT NULL)',
  // Every event taken, counted or not: one that came before its thread
  // counts once the thread arrives.
  'CREATE TABLE IF NOT EXISTS msg_events ('
      'id TEXT PRIMARY KEY, thread TEXT NOT NULL, sender TEXT NOT NULL, '
      'type TEXT NOT NULL, json TEXT NOT NULL, sent_ms INTEGER NOT NULL, '
      'received_ms INTEGER NOT NULL, accepted INTEGER NOT NULL DEFAULT 0, '
      'outgoing INTEGER NOT NULL DEFAULT 0, relayed INTEGER NOT NULL DEFAULT 0)',
  'CREATE INDEX IF NOT EXISTS msg_events_thread ON msg_events(thread, sent_ms)',
  'CREATE INDEX IF NOT EXISTS msg_events_outbox ON msg_events(outgoing, relayed)',
  // The state the events make.
  'CREATE TABLE IF NOT EXISTS msg_threads ('
      'id TEXT PRIMARY KEY, kind TEXT NOT NULL, creator TEXT NOT NULL, '
      'title TEXT, members TEXT NOT NULL, gone TEXT NOT NULL, '
      'last_ms INTEGER NOT NULL, read_ms INTEGER NOT NULL DEFAULT 0)',
];

/// Who a person is to this device's person: themselves, their coach, an
/// athlete they coach, or someone met only in a coach's group.
enum PersonRole { self, coach, athlete, member }

class MessagePerson {
  const MessagePerson({
    required this.person,
    required this.name,
    required this.role,
    this.deviceList,
    this.listVersion = 0,
  });

  final String person, name;
  final PersonRole role;

  /// The signed device list (`{"list": …, "sig": …}`), as JSON text.
  final String? deviceList;
  final int listVersion;
}

/// One thread in the list of threads.
class ThreadSummary {
  const ThreadSummary({
    required this.state,
    required this.lastAt,
    required this.unread,
    this.lastText,
    this.lastSender,
  });

  final ThreadState state;
  final DateTime lastAt;
  final int unread;
  final String? lastText, lastSender;
}

/// An event that counts, as the thread shows it.
class StoredEvent {
  const StoredEvent(
    this.event, {
    required this.outgoing,
    required this.relayed,
  });
  final ThreadEvent event;
  final bool outgoing, relayed;
}

extension MessageStore on AppDatabase {
  Future<void> installMessages() async {
    for (final sql in _schema) {
      await customStatement(sql);
    }
  }

  Future<void> savePerson(MessagePerson p) => customStatement(
    'INSERT INTO msg_people (person, name, role, device_list, list_version, '
    'updated_ms) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(person) DO UPDATE SET '
    // Meeting someone in a group does not change who they are otherwise.
    "name = CASE WHEN excluded.role = 'member' AND role != 'member' "
    'THEN name ELSE excluded.name END, '
    "role = CASE WHEN excluded.role = 'member' THEN role ELSE excluded.role END, "
    // A list only ever moves to a higher version.
    'device_list = CASE WHEN excluded.list_version > list_version '
    'THEN excluded.device_list ELSE device_list END, '
    'list_version = max(list_version, excluded.list_version), '
    'updated_ms = excluded.updated_ms',
    [
      p.person,
      p.name,
      p.role.name,
      p.deviceList,
      p.listVersion,
      DateTime.now().millisecondsSinceEpoch,
    ],
  );

  Future<List<MessagePerson>> people({PersonRole? role}) async => [
    for (final r in await customSelect(
      'SELECT * FROM msg_people${role == null ? '' : ' WHERE role = ?'} '
      'ORDER BY name',
      variables: [if (role != null) Variable.withString(role.name)],
    ).get())
      MessagePerson(
        person: r.read<String>('person'),
        name: r.read<String>('name'),
        role: PersonRole.values.byName(r.read<String>('role')),
        deviceList: r.readNullable<String>('device_list'),
        listVersion: r.read<int>('list_version'),
      ),
  ];

  Future<MessagePerson?> self() async =>
      (await people(role: PersonRole.self)).firstOrNull;

  /// Takes [event], which came from the person [from] (already checked
  /// against their device list), or was written here ([outgoing]). False
  /// when it was had before or names another sender.
  Future<bool> addEvent(
    ThreadEvent event, {
    required String from,
    bool outgoing = false,
  }) => transaction(() async {
    if (event.sender != from) return false;
    final inserted = await customUpdate(
      'INSERT OR IGNORE INTO msg_events (id, thread, sender, type, json, '
      'sent_ms, received_ms, outgoing) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable.withString(event.id),
        Variable.withString(event.thread),
        Variable.withString(event.sender),
        Variable.withString(event.type.name),
        Variable.withString(jsonEncode(event.toJson())),
        Variable.withInt(event.sent.millisecondsSinceEpoch),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
        Variable.withInt(outgoing ? 1 : 0),
      ],
      updateKind: UpdateKind.insert,
    );
    if (inserted == 0) return false;
    final current = await thread(event.thread);
    // The usual case: a message in a thread its sender is in, after every
    // change of members. Everything else replays the thread.
    final last = await _lastChangeMs(event.thread);
    if (event.type == EventType.text &&
        current != null &&
        current.isMember(event.sender) &&
        event.sent.millisecondsSinceEpoch >= last &&
        (event.text ?? '').trim().isNotEmpty) {
      await customStatement('UPDATE msg_events SET accepted = 1 WHERE id = ?', [
        event.id,
      ]);
      await customStatement(
        'UPDATE msg_threads SET last_ms = max(last_ms, ?) WHERE id = ?',
        [event.sent.millisecondsSinceEpoch, event.thread],
      );
    } else {
      await _replay(event.thread);
    }
    return true;
  });

  Future<int> _lastChangeMs(String thread) async =>
      (await customSelect(
        "SELECT max(sent_ms) AS m FROM msg_events WHERE thread = ? "
        "AND accepted = 1 AND type != 'text'",
        variables: [Variable.withString(thread)],
      ).getSingle()).readNullable<int>('m') ??
      0;

  Future<void> _replay(String id) async {
    final events = [
      for (final r in await customSelect(
        'SELECT json FROM msg_events WHERE thread = ?',
        variables: [Variable.withString(id)],
      ).get())
        ?ThreadEvent.fromJson(
          jsonDecode(r.read<String>('json')) as Map<String, dynamic>,
        ),
    ];
    final result = replay(events);
    await customStatement(
      'UPDATE msg_events SET accepted = 0 WHERE thread = ?',
      [id],
    );
    if (result.accepted.isNotEmpty) {
      await customStatement(
        'UPDATE msg_events SET accepted = 1 WHERE id IN '
        '(SELECT value FROM json_each(?))',
        [jsonEncode(result.accepted.toList())],
      );
    }
    final s = result.state;
    if (s == null) return;
    final lastMs = events
        .where((e) => result.accepted.contains(e.id))
        .fold(
          0,
          (m, e) => e.sent.millisecondsSinceEpoch > m
              ? e.sent.millisecondsSinceEpoch
              : m,
        );
    await customStatement(
      'INSERT INTO msg_threads (id, kind, creator, title, members, gone, '
      'last_ms) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'title = excluded.title, members = excluded.members, '
      'gone = excluded.gone, last_ms = excluded.last_ms',
      [
        s.id,
        s.kind.name,
        s.creator,
        s.title,
        jsonEncode([for (final m in s.members.values) m.toJson()]),
        jsonEncode(s.gone.toList()),
        lastMs,
      ],
    );
  }

  Future<ThreadState?> thread(String id) async {
    final r = await customSelect(
      'SELECT * FROM msg_threads WHERE id = ?',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return r == null ? null : _state(r);
  }

  ThreadState _state(QueryRow r) => ThreadState.restore(
    id: r.read<String>('id'),
    kind: ThreadKind.values.byName(r.read<String>('kind')),
    creator: r.read<String>('creator'),
    title: r.readNullable<String>('title'),
    members: [
      for (final m in jsonDecode(r.read<String>('members')) as List)
        ThreadMember.fromJson(m as Map<String, dynamic>),
    ],
    gone: (jsonDecode(r.read<String>('gone')) as List).cast<String>(),
  );

  /// Threads, the latest first, with their last message and how many
  /// messages from others came after this device last opened them.
  Future<List<ThreadSummary>> threads() async {
    final me = (await self())?.person;
    final rows = await customSelect(
      'SELECT t.*, '
      "(SELECT json FROM msg_events e WHERE e.thread = t.id AND e.accepted = 1 "
      "AND e.type = 'text' ORDER BY e.sent_ms DESC, e.id DESC LIMIT 1) AS last, "
      "(SELECT count(*) FROM msg_events e WHERE e.thread = t.id "
      "AND e.accepted = 1 AND e.type = 'text' AND e.sent_ms > t.read_ms "
      'AND e.sender IS NOT ?) AS unread '
      'FROM msg_threads t ORDER BY t.last_ms DESC',
      variables: [Variable<String>(me)],
    ).get();
    return [
      for (final r in rows)
        () {
          final last = r.readNullable<String>('last');
          final e = last == null
              ? null
              : ThreadEvent.fromJson(jsonDecode(last) as Map<String, dynamic>);
          return ThreadSummary(
            state: _state(r),
            lastAt: DateTime.fromMillisecondsSinceEpoch(r.read<int>('last_ms')),
            unread: r.read<int>('unread'),
            lastText: e?.text,
            lastSender: e?.sender,
          );
        }(),
    ];
  }

  /// The thread's events that count, oldest first.
  Future<List<StoredEvent>> events(String thread, {int limit = 500}) async => [
    for (final r in (await customSelect(
      'SELECT json, outgoing, relayed FROM msg_events WHERE thread = ? '
      'AND accepted = 1 ORDER BY sent_ms DESC, id DESC LIMIT ?',
      variables: [Variable.withString(thread), Variable.withInt(limit)],
    ).get()).reversed)
      StoredEvent(
        ThreadEvent.fromJson(
          jsonDecode(r.read<String>('json')) as Map<String, dynamic>,
        )!,
        outgoing: r.read<int>('outgoing') == 1,
        relayed: r.read<int>('relayed') == 1,
      ),
  ];

  Future<void> markRead(String thread, {DateTime? at}) => customStatement(
    'UPDATE msg_threads SET read_ms = max(read_ms, ?) WHERE id = ?',
    [(at ?? DateTime.now()).millisecondsSinceEpoch, thread],
  );

  /// Events written here that have not gone out through the relay yet.
  Future<List<ThreadEvent>> outbox() async => [
    for (final r in await customSelect(
      'SELECT json FROM msg_events WHERE outgoing = 1 AND relayed = 0 '
      'ORDER BY sent_ms',
    ).get())
      ThreadEvent.fromJson(
        jsonDecode(r.read<String>('json')) as Map<String, dynamic>,
      )!,
  ];

  Future<void> markRelayed(Iterable<String> ids) => customStatement(
    'UPDATE msg_events SET relayed = 1 WHERE id IN '
    '(SELECT value FROM json_each(?))',
    [jsonEncode(ids.toList())],
  );

  /// Every event of the threads [person] is or was in, for a device that
  /// meets them nearby and may have missed some.
  Future<List<ThreadEvent>> eventsWith(String person) async {
    final rows = await customSelect(
      'SELECT e.json FROM msg_events e JOIN msg_threads t ON t.id = e.thread '
      'WHERE e.accepted = 1 AND EXISTS (SELECT 1 FROM json_each(t.members) m '
      "WHERE json_extract(m.value, '\$.person') = ?) ORDER BY e.sent_ms",
      variables: [Variable.withString(person)],
    ).get();
    return [
      for (final r in rows)
        ThreadEvent.fromJson(
          jsonDecode(r.read<String>('json')) as Map<String, dynamic>,
        )!,
    ];
  }
}
