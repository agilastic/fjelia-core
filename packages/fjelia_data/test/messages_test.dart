import 'package:drift/native.dart';
import 'package:fjelia_core/services/messaging/thread_event.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/messages.dart';
import 'package:test/test.dart';

const coach = ThreadMember('coach', 'Coach Kim');
const ana = ThreadMember('ana', 'Ana');
const ben = ThreadMember('ben', 'Ben');

var _n = 0;
ThreadEvent ev(
  EventType type, {
  String sender = 'coach',
  List<ThreadMember> members = const [],
  String? text,
  int minute = 0,
}) => ThreadEvent(
  id: 'e${_n++}',
  thread: 'g1',
  kind: ThreadKind.group,
  sender: sender,
  type: type,
  sent: DateTime.utc(2026, 11, 27, 10, minute),
  members: members,
  text: text,
  title: type == EventType.created ? 'Trail team' : null,
);

void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.installMessages();
    await db.savePerson(
      const MessagePerson(person: 'ana', name: 'Ana', role: PersonRole.self),
    );
  });
  tearDown(() => db.close());

  test('a message before its group counts once the group arrives', () async {
    final hello = ev(EventType.text, sender: 'ben', text: 'Hello', minute: 2);
    expect(await db.addEvent(hello, from: 'ben'), isTrue);
    expect(await db.threads(), isEmpty);
    await db.addEvent(
      ev(EventType.created, members: [coach, ana, ben]),
      from: 'coach',
    );
    final [t] = await db.threads();
    expect(t.state.title, 'Trail team');
    expect(t.lastText, 'Hello');
    expect(t.unread, 1);
    // The same event again changes nothing.
    expect(await db.addEvent(hello, from: 'ben'), isFalse);
    await db.markRead('g1', at: DateTime.utc(2026, 11, 27, 11));
    expect((await db.threads()).single.unread, 0);
  });

  test(
    'an event in someone else\'s name, or by a removed member, is not shown',
    () async {
      await db.addEvent(
        ev(EventType.created, members: [coach, ana, ben]),
        from: 'coach',
      );
      expect(
        await db.addEvent(
          ev(EventType.text, text: 'fake', minute: 1),
          from: 'ben',
        ),
        isFalse,
      );
      await db.addEvent(
        ev(EventType.removed, members: [ben], minute: 2),
        from: 'coach',
      );
      await db.addEvent(
        ev(EventType.text, sender: 'ben', text: 'late', minute: 3),
        from: 'ben',
      );
      final mine = ev(EventType.text, sender: 'ana', text: 'Mine', minute: 4);
      await db.addEvent(mine, from: 'ana', outgoing: true);
      final shown = await db.events('g1');
      expect(shown.map((e) => e.event.type), [
        EventType.created,
        EventType.removed,
        EventType.text,
      ]);
      expect(shown.last.outgoing, isTrue);
      expect((await db.thread('g1'))!.gone, {'ben'});
      expect((await db.outbox()).map((e) => e.id), [mine.id]);
      await db.markRelayed([mine.id]);
      expect(await db.outbox(), isEmpty);
      // Ana's own message is not unread for her.
      expect((await db.threads()).single.unread, 0);
      expect((await db.eventsWith('ben')), isEmpty);
      expect((await db.eventsWith('ana')), hasLength(3));
    },
  );

  test('a person\'s device list only moves to a newer version', () async {
    await db.savePerson(
      const MessagePerson(
        person: 'coach',
        name: 'Kim',
        role: PersonRole.coach,
        deviceList: 'v2',
        listVersion: 2,
      ),
    );
    await db.savePerson(
      const MessagePerson(
        person: 'coach',
        name: 'Coach Kim',
        role: PersonRole.coach,
        deviceList: 'v1',
        listVersion: 1,
      ),
    );
    final [p] = await db.people(role: PersonRole.coach);
    expect(p.name, 'Coach Kim');
    expect((p.deviceList, p.listVersion), ('v2', 2));
  });
}
