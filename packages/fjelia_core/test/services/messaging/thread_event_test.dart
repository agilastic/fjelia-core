import 'package:fjelia_core/services/messaging/thread_event.dart';
import 'package:test/test.dart';

const coach = ThreadMember('coach', 'Coach Kim');
const ana = ThreadMember('ana', 'Ana');
const ben = ThreadMember('ben', 'Ben');
const cleo = ThreadMember('cleo', 'Cleo');

var _n = 0;
ThreadEvent ev(
  EventType type, {
  String sender = 'coach',
  String thread = 'g1',
  ThreadKind kind = ThreadKind.group,
  List<ThreadMember> members = const [],
  String? text,
  String? title,
  int minute = 0,
}) => ThreadEvent(
  id: 'e${_n++}',
  thread: thread,
  kind: kind,
  sender: sender,
  type: type,
  sent: DateTime.utc(2026, 11, 27, 10, minute),
  members: members,
  text: text,
  title: title,
);

void main() {
  test('a coach\'s group: members, renames, leaving and removing', () {
    final created = ev(
      EventType.created,
      members: [coach, ana, ben],
      title: 'Trail team',
    );
    var g = applyEvent(null, created, 'coach');
    expect(g.members.keys, ['coach', 'ana', 'ben']);
    g = applyEvent(g, ev(EventType.text, sender: 'ana', text: 'Hi all'), 'ana');
    g = applyEvent(g, ev(EventType.added, members: [cleo]), 'coach');
    g = applyEvent(g, ev(EventType.renamed, title: 'Trail team 2027'), 'coach');
    expect(g.title, 'Trail team 2027');
    g = applyEvent(g, ev(EventType.left, sender: 'ben'), 'ben');
    g = applyEvent(g, ev(EventType.removed, members: [cleo]), 'coach');
    expect(g.members.keys, ['coach', 'ana']);
    expect(g.gone, {'ben', 'cleo'});
    // Gone people write nothing more; athletes change nothing.
    expect(
      () => applyEvent(g, ev(EventType.text, sender: 'ben', text: 'x'), 'ben'),
      throwsStateError,
    );
    expect(
      () => applyEvent(
        g,
        ev(EventType.added, sender: 'ana', members: [ben]),
        'ana',
      ),
      throwsStateError,
    );
    expect(() => applyEvent(g, ev(EventType.left), 'coach'), throwsStateError);
    // An envelope from Ana cannot carry an event in the coach's name.
    expect(
      () => applyEvent(g, ev(EventType.added, members: [ben]), 'ana'),
      throwsStateError,
    );
  });

  test('a direct thread is the same on both sides and only between two', () {
    final id = directThreadId('coach', 'ana');
    expect(directThreadId('ana', 'coach'), id);
    final mine = ev(
      EventType.created,
      thread: id,
      kind: ThreadKind.direct,
      members: [coach, ana],
    );
    final theirs = ev(
      EventType.created,
      sender: 'ana',
      thread: id,
      kind: ThreadKind.direct,
      members: [ana, coach],
      minute: 1,
    );
    var d = applyEvent(null, mine, 'coach');
    d = applyEvent(d, theirs, 'ana');
    expect(d.creator, 'coach');
    expect(
      () => applyEvent(
        null,
        ev(
          EventType.created,
          thread: 'd-x',
          kind: ThreadKind.direct,
          members: [coach, ana],
        ),
        'coach',
      ),
      throwsStateError,
    );
    expect(
      () => applyEvent(
        d,
        ev(
          EventType.added,
          thread: id,
          kind: ThreadKind.direct,
          members: [ben],
        ),
        'coach',
      ),
      throwsStateError,
    );
  });

  test('events arriving out of order, twice, or from strangers make the same thread', () {
    final events = [
      ev(EventType.created, members: [coach, ana, ben], title: 'T'),
      ev(EventType.text, sender: 'ana', text: 'one', minute: 1),
      ev(EventType.removed, members: [ben], minute: 2),
      ev(EventType.text, sender: 'ben', text: 'too late', minute: 3),
      ev(EventType.text, sender: 'mallory', text: 'spam', minute: 4),
    ];
    final a = replay(events);
    final b = replay([...events.reversed, ...events]);
    expect(a.state!.members.keys, b.state!.members.keys);
    expect(a.state!.members.keys, ['coach', 'ana']);
    // Ben's late message and the stranger's do not count.
    expect(a.accepted, {for (final e in events.take(3)) e.id});
    expect(b.accepted, a.accepted);
  });

  test('the travelling form round-trips and refuses what it cannot take', () {
    final e = ev(EventType.created, members: [coach, ana], title: 'T');
    final back = ThreadEvent.fromJson(e.toJson())!;
    expect(back.toJson(), e.toJson());
    expect(ThreadEvent.fromJson({...e.toJson(), 'v': 2}), isNull);
    expect(ThreadEvent.fromJson({...e.toJson(), 'type': 'poll'}), isNull);
    expect(
      ThreadEvent.fromJson({...e.toJson(), 'text': 'x' * (maxTextLength + 1)}),
      isNull,
    );
  });
}
