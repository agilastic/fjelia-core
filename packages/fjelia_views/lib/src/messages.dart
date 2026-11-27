import 'dart:math';

import 'package:fjelia_core/services/messaging/thread_event.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/messages.dart';

export 'package:fjelia_core/services/messaging/thread_event.dart'
    show EventType, ThreadKind, ThreadMember, ThreadState, maxTextLength;
export 'package:fjelia_data/messages.dart'
    show MessagePerson, PersonRole, StoredEvent;

/// A thread as the list of threads shows it.
class ThreadRow {
  const ThreadRow({
    required this.id,
    required this.kind,
    required this.title,
    required this.members,
    required this.lastAt,
    required this.unread,
    required this.mine,
    this.lastText,
    this.lastSender,
  });

  final String id;
  final ThreadKind kind;

  /// The group's title, or the other person's name.
  final String title;
  final List<ThreadMember> members;
  final DateTime lastAt;
  final int unread;

  /// A group this person runs (they add, remove and rename).
  final bool mine;
  final String? lastText, lastSender;
}

/// Messages need this device's person; until the identity exists (the
/// first start of a build with identity) there are none.
class NoIdentity implements Exception {
  @override
  String toString() => 'no identity on this device yet';
}

Future<MessagePerson> _me(AppDatabase db) async {
  await db.installMessages();
  return await db.self() ?? (throw NoIdentity());
}

final _random = Random.secure();
String _id() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

Future<ThreadEvent> _write(
  AppDatabase db,
  MessagePerson me, {
  required String thread,
  required ThreadKind kind,
  required EventType type,
  String? text,
  String? title,
  List<ThreadMember> members = const [],
}) async {
  final e = ThreadEvent(
    id: _id(),
    thread: thread,
    kind: kind,
    sender: me.person,
    type: type,
    sent: DateTime.now().toUtc(),
    text: text,
    title: title,
    members: members,
  );
  // The rules first, so nothing that would not count is sent.
  applyEvent(await db.thread(thread), e, me.person);
  await db.addEvent(e, from: me.person, outgoing: true);
  return e;
}

/// The threads, latest first.
Future<List<ThreadRow>> loadThreads(AppDatabase db) async {
  final me = await _me(db);
  return [
    for (final t in await db.threads())
      ThreadRow(
        id: t.state.id,
        kind: t.state.kind,
        title: t.state.kind == ThreadKind.group
            ? t.state.title ?? 'Group'
            : t.state.members.values
                      .where((m) => m.person != me.person)
                      .firstOrNull
                      ?.name ??
                  'Direct',
        members: t.state.members.values.toList(),
        lastAt: t.lastAt,
        unread: t.unread,
        mine: t.state.creator == me.person && t.state.kind == ThreadKind.group,
        lastText: t.lastText,
        lastSender: t.state.members[t.lastSender]?.name,
      ),
  ];
}

/// All unread messages, for a badge.
Future<int> unreadMessages(AppDatabase db) async =>
    (await loadThreads(db)).fold<int>(0, (n, t) => n + t.unread);

/// The thread's messages and changes, oldest first; opening it marks it
/// read.
Future<List<StoredEvent>> openThread(AppDatabase db, String thread) async {
  await _me(db);
  final events = await db.events(thread);
  await db.markRead(thread);
  return events;
}

/// The direct thread with [other] (a coach or one of the coach's athletes),
/// created when it does not exist yet.
Future<String> startDirect(AppDatabase db, MessagePerson other) async {
  final me = await _me(db);
  if (other.role != PersonRole.coach && other.role != PersonRole.athlete) {
    throw ArgumentError('direct messages are between a coach and an athlete');
  }
  final id = directThreadId(me.person, other.person);
  if (await db.thread(id) == null) {
    await _write(
      db,
      me,
      thread: id,
      kind: ThreadKind.direct,
      type: EventType.created,
      members: [
        ThreadMember(me.person, me.name),
        ThreadMember(other.person, other.name),
      ],
    );
  }
  return id;
}

/// A group of this coach's own [athletes]; its id.
Future<String> createGroup(
  AppDatabase db, {
  required String title,
  required List<MessagePerson> athletes,
}) async {
  final me = await _me(db);
  await _ownAthletes(db, athletes);
  final id = 'g-${_id()}';
  await _write(
    db,
    me,
    thread: id,
    kind: ThreadKind.group,
    type: EventType.created,
    title: _title(title),
    members: [
      ThreadMember(me.person, me.name),
      for (final a in athletes) ThreadMember(a.person, a.name),
    ],
  );
  return id;
}

Future<void> _ownAthletes(AppDatabase db, List<MessagePerson> athletes) async {
  final mine = {
    for (final p in await db.people(role: PersonRole.athlete)) p.person,
  };
  if (athletes.isEmpty || athletes.any((a) => !mine.contains(a.person))) {
    throw ArgumentError('a group is of the coach\'s own athletes');
  }
}

String _title(String title) {
  final t = title.trim();
  if (t.isEmpty) throw ArgumentError('a group needs a title');
  return t.length > maxTitleLength ? t.substring(0, maxTitleLength) : t;
}

Future<void> sendText(AppDatabase db, String thread, String text) async {
  final me = await _me(db);
  final state = await db.thread(thread) ?? (throw ArgumentError('no thread'));
  final t = text.trim();
  if (t.isEmpty) return;
  if (t.length > maxTextLength) {
    throw ArgumentError('at most $maxTextLength characters');
  }
  await _write(
    db,
    me,
    thread: thread,
    kind: state.kind,
    type: EventType.text,
    text: t,
  );
}

Future<void> addToGroup(
  AppDatabase db,
  String thread,
  List<MessagePerson> athletes,
) async {
  final me = await _me(db);
  await _ownAthletes(db, athletes);
  final state = await db.thread(thread);
  final adding = [
    for (final a in athletes)
      if (state?.isMember(a.person) != true) ThreadMember(a.person, a.name),
  ];
  if (adding.isEmpty) return;
  await _write(
    db,
    me,
    thread: thread,
    kind: ThreadKind.group,
    type: EventType.added,
    members: adding,
  );
}

Future<void> removeFromGroup(
  AppDatabase db,
  String thread,
  ThreadMember member,
) async => _write(
  db,
  await _me(db),
  thread: thread,
  kind: ThreadKind.group,
  type: EventType.removed,
  members: [member],
);

Future<void> renameGroup(AppDatabase db, String thread, String title) async =>
    _write(
      db,
      await _me(db),
      thread: thread,
      kind: ThreadKind.group,
      type: EventType.renamed,
      title: _title(title),
    );

/// An athlete leaves a coach's group.
Future<void> leaveGroup(AppDatabase db, String thread) async => _write(
  db,
  await _me(db),
  thread: thread,
  kind: ThreadKind.group,
  type: EventType.left,
);
