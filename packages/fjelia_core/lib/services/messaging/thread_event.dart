/// Direct messages between a coach and an athlete, and a coach's groups of
/// their own athletes.
///
/// Everything in a thread is an event that is written once and never
/// changed: a text, or a change of the group (created, members added or
/// removed, someone leaving, a new title). Events have a random id, so
/// taking one twice, or by two paths (nearby and through the relay), changes
/// nothing; the members of a thread follow from its events in order.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

enum ThreadKind { direct, group }

enum EventType { created, text, added, removed, left, renamed }

/// A person in a thread, with the name the one who added them knows.
class ThreadMember {
  const ThreadMember(this.person, this.name);

  factory ThreadMember.fromJson(Map<String, dynamic> j) =>
      ThreadMember(j['person'] as String, j['name'] as String);

  final String person;
  final String name;

  Map<String, String> toJson() => {'person': person, 'name': name};
}

class ThreadEvent {
  const ThreadEvent({
    required this.id,
    required this.thread,
    required this.kind,
    required this.sender,
    required this.type,
    required this.sent,
    this.text,
    this.title,
    this.members = const [],
  });

  /// The event as it travels; null for anything malformed, of a later
  /// version, or over the limits.
  static ThreadEvent? fromJson(Map<String, dynamic> j) {
    try {
      if (j['v'] != 1) return null;
      final type = EventType.values.byName(j['type'] as String);
      final text = j['text'] as String?;
      if (text != null && text.length > maxTextLength) return null;
      final title = j['title'] as String?;
      if (title != null && title.length > maxTitleLength) return null;
      final members = [
        for (final m in (j['members'] as List? ?? const []))
          ThreadMember.fromJson(m as Map<String, dynamic>),
      ];
      if (members.length > maxGroupMembers) return null;
      return ThreadEvent(
        id: j['id'] as String,
        thread: j['thread'] as String,
        kind: ThreadKind.values.byName(j['kind'] as String),
        sender: j['sender'] as String,
        type: type,
        sent: DateTime.fromMillisecondsSinceEpoch(
          j['sent'] as int,
          isUtc: true,
        ),
        text: text,
        title: title,
        members: members,
      );
    } on Object {
      return null;
    }
  }

  final String id, thread, sender;
  final ThreadKind kind;
  final EventType type;
  final DateTime sent;

  /// The message ([EventType.text]).
  final String? text;

  /// The group's title ([EventType.created], [EventType.renamed]).
  final String? title;

  /// Everyone in the thread at [EventType.created], including the sender;
  /// who joins at [EventType.added], who goes at [EventType.removed].
  final List<ThreadMember> members;

  Map<String, Object> toJson() => {
    'v': 1,
    'id': id,
    'thread': thread,
    'kind': kind.name,
    'sender': sender,
    'type': type.name,
    'sent': sent.millisecondsSinceEpoch,
    'text': ?text,
    'title': ?title,
    if (members.isNotEmpty) 'members': [for (final m in members) m.toJson()],
  };
}

const maxTextLength = 4000;
const maxTitleLength = 80;
const maxGroupMembers = 100;

/// The one thread two people write to each other in; both sides reach the
/// same id without asking anyone.
String directThreadId(String a, String b) {
  final pair = ([a, b]..sort()).join(':');
  return 'd-${sha256.convert(utf8.encode(pair)).toString().substring(0, 32)}';
}

/// A thread as its events make it.
class ThreadState {
  ThreadState._(this.id, this.kind, this.creator);

  /// As stored: the state after its events.
  ThreadState.restore({
    required this.id,
    required this.kind,
    required this.creator,
    this.title,
    Iterable<ThreadMember> members = const [],
    Iterable<String> gone = const [],
  }) {
    this.members.addAll({for (final m in members) m.person: m});
    this.gone.addAll(gone);
  }

  final String id;
  final ThreadKind kind;

  /// Who created it: for a group, the coach, the only one who adds,
  /// removes and renames.
  final String creator;
  String? title;

  /// Current members by person id.
  final members = <String, ThreadMember>{};

  /// Everyone who was ever a member and has left or been removed; they
  /// receive nothing new.
  final gone = <String>{};

  bool isMember(String person) => members.containsKey(person);
}

/// Applies [event] to [state] (null before the thread exists) and returns
/// the new state, or throws [StateError] with the reason when [event] is
/// not allowed. [sender] is the person the envelope came from, already
/// checked against their device list; an event must name them.
ThreadState applyEvent(ThreadState? state, ThreadEvent event, String sender) {
  if (event.sender != sender) {
    throw StateError('the event names another sender');
  }
  if (state == null) {
    if (event.type != EventType.created) {
      throw StateError('the thread is not known yet');
    }
    final people = {for (final m in event.members) m.person: m};
    if (!people.containsKey(sender)) {
      throw StateError('the creator must be a member');
    }
    if (event.kind == ThreadKind.direct) {
      if (people.length != 2 ||
          event.thread != directThreadId(people.keys.first, people.keys.last)) {
        throw StateError('a direct thread is between its two people');
      }
    } else if (people.length < 2) {
      throw StateError('a group needs someone besides its coach');
    }
    return ThreadState._(event.thread, event.kind, sender)
      ..title = event.title
      ..members.addAll(people);
  }
  if (event.thread != state.id || event.kind != state.kind) {
    throw StateError('another thread');
  }
  switch (event.type) {
    case EventType.created:
      // The same thread created again (both sides of a direct thread
      // start it): nothing changes, the first one counts.
      if (!state.isMember(sender)) throw StateError('not a member');
    case EventType.text:
      if (!state.isMember(sender)) throw StateError('not a member');
      if ((event.text ?? '').trim().isEmpty) throw StateError('empty');
    case EventType.added:
    case EventType.removed:
    case EventType.renamed:
      if (state.kind != ThreadKind.group || sender != state.creator) {
        throw StateError('only the group\'s coach changes it');
      }
      if (event.type == EventType.added) {
        if (state.members.length + event.members.length > maxGroupMembers) {
          throw StateError('at most $maxGroupMembers in a group');
        }
        for (final m in event.members) {
          state.members[m.person] = m;
          state.gone.remove(m.person);
        }
      } else if (event.type == EventType.removed) {
        for (final m in event.members) {
          if (m.person == state.creator) {
            throw StateError('the coach does not remove themselves');
          }
          if (state.members.remove(m.person) != null) state.gone.add(m.person);
        }
      } else {
        state.title = event.title;
      }
    case EventType.left:
      if (state.kind != ThreadKind.group || sender == state.creator) {
        throw StateError('only an athlete leaves a group');
      }
      if (state.members.remove(sender) == null) {
        throw StateError('not a member');
      }
      state.gone.add(sender);
  }
  return state;
}

/// The thread made by [events] (in the order they were sent), and the ids of
/// the events that count; the others are as if they never came. Each
/// event's sender was checked on arrival.
({ThreadState? state, Set<String> accepted}) replay(
  Iterable<ThreadEvent> events,
) {
  final sorted = [...events]
    // Creation first, then by time, then a stable order for events sent at
    // once.
    ..sort((a, b) {
      final c = (a.type == EventType.created ? 0 : 1).compareTo(
        b.type == EventType.created ? 0 : 1,
      );
      if (c != 0) return c;
      final t = a.sent.compareTo(b.sent);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
  ThreadState? state;
  final accepted = <String>{};
  for (final e in sorted) {
    try {
      state = applyEvent(state, e, e.sender);
      accepted.add(e.id);
    } on StateError {
      // Not allowed: as if it never came.
    }
  }
  return (state: state, accepted: accepted);
}
