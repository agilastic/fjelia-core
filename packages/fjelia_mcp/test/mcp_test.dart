import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_mcp/fjelia_mcp.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late FjeliaMcp mcp;
  var id = 0;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    mcp = FjeliaMcp(db);
  });
  tearDown(() => db.close());

  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? params,
  ]) async => (await mcp.handle({
    'jsonrpc': '2.0',
    'id': ++id,
    'method': method,
    'params': ?params,
  }))!;

  Future<Map<String, Object?>> tool(
    String name, [
    Map<String, Object?> args = const {},
  ]) async =>
      ((await call('tools/call', {'name': name, 'arguments': args}))['result']
              as Map)
          .cast<String, Object?>();

  test(
    'initialize, list the tools, and notifications take no answer',
    () async {
      final init = await call('initialize', {'protocolVersion': '2025-06-18'});
      expect(
        (init['result'] as Map)['serverInfo'],
        containsPair('name', 'fjelia'),
      );
      expect(
        await mcp.handle({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        }),
        isNull,
      );
      final tools =
          ((await call('tools/list'))['result'] as Map)['tools'] as List;
      final names = [for (final t in tools) (t as Map)['name']];
      expect(
        names,
        containsAll([
          'get_today',
          'get_calendar',
          'move_session',
          'add_workout',
        ]),
      );
      final move = tools.cast<Map>().firstWhere(
        (t) => t['name'] == 'move_session',
      );
      expect((move['annotations'] as Map)['readOnlyHint'], isFalse);
      expect((await call('nope'))['error'], isNotNull);
    },
  );

  test('the read tools answer on an empty database', () async {
    for (final name in [
      'get_today',
      'list_activities',
      'get_analysis',
      'get_season',
      'get_health',
      'search_diary',
    ]) {
      final r = await tool(name);
      expect(r['isError'], isNot(true), reason: name);
      jsonDecode(((r['content'] as List).single as Map)['text'] as String);
    }
    expect(
      (await tool('get_calendar', {'from': '2026-11-25'}))['structuredContent'],
      isA<Map>(),
    );
  });

  test('a workout is added and moved; a refused move says why', () async {
    final added = await tool('add_workout', {
      'date': '2026-12-01',
      'sport': 'running',
      'title': 'Tempo 3 × 10 min',
      'steps': [
        {'kind': 'warmup', 'zone': 1, 'minutes': 15},
        {
          'times': 3,
          'steps': [
            {'kind': 'interval', 'zone': 3, 'minutes': 10},
            {'kind': 'recovery', 'zone': 1, 'minutes': 2},
          ],
        },
        {'kind': 'cooldown', 'zone': 1, 'minutes': 10},
      ],
    });
    final made = added['structuredContent'] as Map;
    expect(made['minutes'], 61);
    final moved = await tool('move_session', {
      'sessionId': made['id'],
      'date': '2026-12-02',
    });
    expect((moved['structuredContent'] as Map)['to'], '2026-12-02');

    await db
        .into(db.absences)
        .insert(
          AbsencesCompanion.insert(
            kind: 'vacation',
            startDay: DateTime(2026, 12, 5),
            endDay: DateTime(2026, 12, 6),
            createdAt: DateTime(2026, 11, 25),
          ),
        );
    final refused = await tool('move_session', {
      'sessionId': made['id'],
      'date': '2026-12-05',
    });
    expect(refused['isError'], isTrue);
    expect(
      ((refused['content'] as List).single as Map)['text'],
      contains('away'),
    );
    final missing = await tool('get_activity', {'id': 'nope'});
    expect(missing['isError'], isTrue);
  });
}
