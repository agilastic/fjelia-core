/// Fjelia's tools for AI assistants (Model Context Protocol), independent of
/// the transport: an app hands each JSON-RPC message to [FjeliaMcp.handle]
/// and sends back what it returns.
///
/// What a tool answers comes from fjelia_views, the same as the screens;
/// changes go through PlanEdits, with the same rules as on the phone. The
/// assistant asks the athlete before it calls a tool that changes the plan.
library;

import 'dart:convert';

import 'package:fjelia_data/database.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:fjelia_core/utils/days.dart';

double _r(double v, [int digits = 1]) =>
    double.parse(v.toStringAsFixed(digits));

/// A tool an assistant can call.
class McpTool {
  const McpTool({
    required this.name,
    required this.title,
    required this.description,
    required this.input,
    required this.run,
    this.changes = false,
  });

  final String name;
  final String title;
  final String description;

  /// JSON Schema of the arguments.
  final Map<String, Object?> input;

  /// Whether it changes the athlete's data (the assistant asks first).
  final bool changes;
  final Future<Object?> Function(Map<String, Object?> args) run;

  Map<String, Object?> get definition => {
    'name': name,
    'title': title,
    'description': description,
    'inputSchema': {'type': 'object', ...input},
    'annotations': {
      'title': title,
      'readOnlyHint': !changes,
      'destructiveHint': false,
      'idempotentHint': !changes,
      'openWorldHint': false,
    },
  };
}

/// Why a tool call could not be done; its message goes back to the
/// assistant.
class McpToolError implements Exception {
  const McpToolError(this.message);
  final String message;
}

class FjeliaMcp {
  FjeliaMcp(this.db, {this.version = '1.0'});

  final AppDatabase db;
  final String version;

  static const protocolVersion = '2025-06-18';

  /// Handles one JSON-RPC message; null for a notification, which takes no
  /// answer.
  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    final id = message['id'];
    final method = message['method'];
    if (id == null) return null; // a notification
    Map<String, Object?> ok(Object? result) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    Map<String, Object?> fail(int code, String text) => {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': text},
    };
    switch (method) {
      case 'initialize':
        return ok({
          'protocolVersion': protocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {
            'name': 'fjelia',
            'title': 'Fjelia',
            'version': version,
          },
          'instructions':
              'Fjelia holds the athlete\'s own training: activities, the '
              'plan, health and recovery data, notes. Read with the read '
              'tools before advising. Change the plan only when the athlete '
              'asks, one tool call per change; Fjelia refuses moves onto '
              'race days or days away and says why.',
        });
      case 'ping':
        return ok({});
      case 'tools/list':
        return ok({
          'tools': [for (final t in tools) t.definition],
        });
      case 'tools/call':
        final params = (message['params'] as Map?)?.cast<String, Object?>();
        final name = params?['name'];
        final tool = tools.where((t) => t.name == name).firstOrNull;
        if (tool == null) return fail(-32602, 'Unknown tool: $name');
        final args =
            (params?['arguments'] as Map?)?.cast<String, Object?>() ?? {};
        try {
          final result = await tool.run(args);
          return ok({
            'content': [
              {'type': 'text', 'text': jsonEncode(result)},
            ],
            if (result is Map) 'structuredContent': result,
          });
        } on McpToolError catch (e) {
          return ok({
            'content': [
              {'type': 'text', 'text': e.message},
            ],
            'isError': true,
          });
        } on PlanEditRefused catch (e) {
          return ok({
            'content': [
              {'type': 'text', 'text': _refusal(e)},
            ],
            'isError': true,
          });
        }
      default:
        return fail(-32601, 'Method not found: $method');
    }
  }

  static String _refusal(PlanEditRefused e) => switch (e) {
    EventDayRefused(:final event) =>
      'Refused: that day belongs to $event (the race or the rest day before it).',
    AbsenceRefused(:final kind) =>
      'Refused: the athlete is away that day ($kind).',
    DoneRefused() => 'Refused: that workout is already done.',
    PlanShiftRefused(:final session, :final reason) =>
      'Refused for $session: ${_refusal(reason)}',
  };

  static DateTime _day(Map<String, Object?> args, String key) {
    final d = DateTime.tryParse('${args[key] ?? ''}');
    if (d == null) throw McpToolError('$key must be a date like 2026-12-01.');
    return DateTime(d.year, d.month, d.day);
  }

  static String _text(Map<String, Object?> args, String key) {
    final v = args[key];
    if (v is! String || v.trim().isEmpty) {
      throw McpToolError('$key is required.');
    }
    return v.trim();
  }

  Map<String, Object?> _activity(ActivityItem a) => {
    'id': a.id,
    'name': a.name,
    'sport': a.sport,
    'start': a.start.toIso8601String(),
    'minutes': a.duration.inMinutes,
    if (a.distanceMeters case final m? when m > 0) 'km': _r(m / 1000, 2),
    if (a.avgHeartRate case final hr?) 'avgHeartRate': hr.round(),
    'load': a.load.round(),
  };

  Map<String, Object?> _session(PlannedSession s) => {
    'id': s.id,
    'title': s.title,
    'sport': s.sport,
    'date': isoDay(s.date),
    'minutes': s.durationMin,
    'zone': s.zone,
    'load': s.load,
    'done': s.done,
  };

  late final List<McpTool> tools = [
    McpTool(
      name: 'get_today',
      title: 'Today',
      description:
          'The athlete\'s day: morning readiness verdict and its causes, '
          'today\'s planned sessions, fitness/fatigue/form, the current week '
          'against the plan, the next race goal and the latest activities.',
      input: const {'properties': {}},
      run: (_) async {
        final t = await loadToday(db);
        final r = t.readiness;
        return {
          'date': isoDay(t.date),
          if (r != null)
            'readiness': {
              'level': r.level.name,
              'flags': [for (final f in r.flags) f.name],
              'hrvMs': ?r.hrvToday?.round(),
              'hrvBelowBaselinePct': ?r.hrvDropPct?.round(),
              'restingHr': ?r.restingHrToday?.round(),
              'sleepScore': ?r.sleepScore,
            },
          'load': {
            'fitness': t.load.ctl.round(),
            'fatigue': t.load.atl.round(),
            'form': t.load.tsb.round(),
            'formStatus': t.load.status.name,
          },
          'plannedToday': [for (final s in t.today) _session(s)],
          'week': {
            'doneMinutes': t.week.done.inMinutes,
            'plannedMinutes': t.week.planned.inMinutes,
            'doneLoad': t.week.doneLoad.round(),
            'plannedLoad': t.week.plannedLoad,
          },
          if (t.nextGoal case final g?)
            'nextGoal': {
              'name': g.name,
              'date': isoDay(g.date),
              'daysToGo': g.daysToGo,
              'priority': g.priority,
              'km': _r(g.distanceMeters / 1000),
              'targetSeconds': ?g.targetSeconds,
            },
          'recent': [for (final a in t.recent) _activity(a)],
        };
      },
    ),
    McpTool(
      name: 'get_calendar',
      title: 'Calendar',
      description:
          'Planned sessions and done activities per day for one or more '
          'weeks from a date, with how each session was done (onTarget, '
          'partly, offPlan, missed, upcoming), races, days away and a '
          'summary per week.',
      input: const {
        'properties': {
          'from': {
            'type': 'string',
            'description': 'A date in the first week, YYYY-MM-DD.',
          },
          'weeks': {'type': 'integer', 'minimum': 1, 'maximum': 8},
        },
        'required': ['from'],
      },
      run: (args) async {
        final from = _day(args, 'from');
        final weeks = ((args['weeks'] as num?)?.toInt() ?? 1).clamp(1, 8);
        final start = (await loadCalendarWeek(db, from)).focusStart;
        final view = await loadCalendar(
          db,
          start: start,
          weeks: weeks,
          focusStart: start,
          focusEnd: start.add(Duration(days: 7 * weeks)),
        );
        return {
          'weeks': [
            for (final w in view.weeks)
              {
                'start': isoDay(w.start),
                'doneMinutes': w.summary.done.inMinutes,
                'plannedMinutes': w.summary.planned.inMinutes,
                'km': _r(w.summary.distanceMeters / 1000),
                'load': w.summary.load.round(),
                'plannedLoad': w.summary.plannedLoad,
                'days': [
                  for (final d in w.days)
                    if (d.entries.isNotEmpty || d.hrv != null)
                      {
                        'date': isoDay(d.date),
                        'hrvMs': ?d.hrv?.round(),
                        'readiness': ?d.readiness?.name,
                        'entries': [
                          for (final e in d.entries)
                            switch (e) {
                              SessionEntry(
                                :final session,
                                :final compliance,
                                :final activity,
                              ) =>
                                {
                                  'session': _session(session),
                                  'compliance': compliance.name,
                                  if (activity != null)
                                    'activity': _activity(activity),
                                },
                              ActivityEntry(:final activity) => {
                                'unplannedActivity': _activity(activity),
                              },
                              RaceEntry(:final goal) => {
                                'race': goal.name,
                                'priority': goal.priority,
                              },
                              AbsenceEntry(:final kind) => {'away': kind},
                            },
                        ],
                      },
                ],
              },
          ],
        };
      },
    ),
    McpTool(
      name: 'list_activities',
      title: 'Activities',
      description: 'Done activities, newest first, optionally of one sport.',
      input: const {
        'properties': {
          'sport': {
            'type': 'string',
            'enum': ['all', 'run', 'ride', 'swim', 'strength'],
          },
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
        },
      },
      run: (args) async {
        final filter =
            SportFilter.values.asNameMap()['${args['sport'] ?? 'all'}'] ??
            SportFilter.all;
        final limit = ((args['limit'] as num?)?.toInt() ?? 30).clamp(1, 200);
        final list = await loadActivityList(db, filter: filter);
        return {
          'total': list.total,
          'activities': [
            for (final a in list.months.expand((m) => m.items).take(limit))
              _activity(a),
          ],
        };
      },
    ),
    McpTool(
      name: 'get_activity',
      title: 'Activity',
      description:
          'One activity\'s values for its sport (pace or speed, power, heart '
          'rate, elevation, load), time in heart-rate zones and the athlete\'s note.',
      input: const {
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
      run: (args) async {
        final d = await loadActivityDetail(db, _text(args, 'id'));
        if (d == null) throw const McpToolError('No activity with that id.');
        return {
          ..._activity(d.item),
          'stats': {for (final (k, v) in d.stats) k.name: _r(v, 2)},
          if (d.zoneSeconds.isNotEmpty)
            'zoneMinutes': [for (final s in d.zoneSeconds) _r(s / 60)],
          'note': ?d.note,
        };
      },
    ),
    McpTool(
      name: 'get_analysis',
      title: 'Analysis',
      description:
          'Fitness, fatigue and form today and their 45-day forecast with '
          'the plan, best power by duration this year and last, easy share '
          'of the last 12 weeks, running and riding records, and the '
          'threshold history.',
      input: const {'properties': {}},
      run: (_) async {
        final a = await loadAnalysis(db);
        final end = a.forecast.isEmpty ? null : a.forecast.last;
        return {
          'fitness': a.load.ctl.round(),
          'fatigue': a.load.atl.round(),
          'form': a.load.tsb.round(),
          if (end != null)
            'forecastEnd': {
              'date': isoDay(end.date),
              'fitness': end.ctl.round(),
              'form': end.tsb.round(),
            },
          'powerCurveWatts': {
            'thisYear': {
              for (final e in a.powerCurve.thisYear.entries)
                '${e.key}s': e.value.round(),
            },
            'lastYear': {
              for (final e in a.powerCurve.lastYear.entries)
                '${e.key}s': e.value.round(),
            },
          },
          if (a.easyShare case final e?) 'easySharePct': (e * 100).round(),
          'records': {
            for (final MapEntry(key: sport, value: s) in a.records.entries)
              sport.name: {
                'activities': s.allTime.count.round(),
                'km': (s.allTime.meters / 1000).round(),
                'bestSeconds': {
                  for (final e in s.efforts)
                    if (e.allTime != null) e.label: e.allTime!.round(),
                },
              },
          },
          'thresholds': [
            for (final t in a.thresholds.reversed.take(10))
              {
                'date': isoDay(t.date),
                'source': t.source,
                'ftpWatts': ?t.ftpWatts,
                'lt2Bpm': ?t.lt2Bpm,
                'lt2PaceSecPerKm': ?t.lt2PaceSec,
                'lt1Bpm': ?t.lt1Bpm,
              },
          ],
        };
      },
    ),
    McpTool(
      name: 'get_season',
      title: 'Season',
      description:
          'The season plan: goals, whether they can be combined, the '
          'planner\'s trade-offs, and each week\'s phase, hours by sport and '
          'projected fitness.',
      input: const {'properties': {}},
      run: (_) async {
        final s = await loadSeason(db);
        if (s.isEmpty) return {'planned': false};
        return {
          'planned': true,
          'outcome': s.outcome.name,
          'goals': [
            for (final g in s.goals)
              {
                'name': g.name,
                'priority': g.priority,
                'sport': g.sport,
                if (g.date case final d?) 'date': isoDay(d),
              },
          ],
          'conflicts': [for (final c in s.conflicts) c.message],
          'tradeoffs': s.summary,
          'weeks': [
            for (final w in s.weeks)
              {
                'start': isoDay(w.start),
                'phase': w.phase,
                'minutesBySport': w.minutesBySport,
                'load': w.load,
                if (w.form case final f?) 'fitness': f.ctl.round(),
              },
          ],
        };
      },
    ),
    McpTool(
      name: 'get_health',
      title: 'Health',
      description:
          'HRV, resting heart rate, sleep, steps, weight and blood pressure: '
          'latest value, change against the week before and the daily series.',
      input: const {
        'properties': {
          'days': {'type': 'integer', 'minimum': 7, 'maximum': 365},
        },
      },
      run: (args) async {
        final h = await loadHealth(
          db,
          days: ((args['days'] as num?)?.toInt() ?? 30).clamp(7, 365),
        );
        Map<String, Object?> metric(HealthMetric m) => {
          if (m.latest case final l?)
            'latest': {'date': isoDay(l.$1), 'value': _r(l.$2)},
          if (m.change case final c?) 'changeVsWeekBefore': _r(c),
          'series': [
            for (final (d, v) in m.series) [isoDay(d), _r(v)],
          ],
        };
        return {
          'hrvMs': metric(h.hrv),
          'restingHr': metric(h.restingHr),
          'sleepHours': metric(h.sleepHours),
          'sleepScore': metric(h.sleepScore),
          'steps': metric(h.steps),
          'weightKg': metric(h.weight),
          'bloodPressure': [
            for (final b in h.bloodPressure)
              [isoDay(b.date), b.systolic.round(), b.diastolic.round()],
          ],
        };
      },
    ),
    McpTool(
      name: 'search_diary',
      title: 'Diary',
      description:
          'The athlete\'s own notes (on activities, sessions, how workouts '
          'felt, notes for the coach, time away), newest first.',
      input: const {
        'properties': {
          'query': {'type': 'string'},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
        },
      },
      run: (args) async {
        final entries = await loadDiary(db, query: '${args['query'] ?? ''}');
        final limit = ((args['limit'] as num?)?.toInt() ?? 30).clamp(1, 100);
        return {
          'entries': [
            for (final e in entries.take(limit))
              {
                'date': isoDay(e.at),
                'kind': e.kind.name,
                'about': ?e.title,
                'effort': ?e.effort,
                'text': e.text,
              },
          ],
        };
      },
    ),
    McpTool(
      name: 'move_session',
      title: 'Move a Session',
      description:
          'Moves a planned session to another day. Refused onto race days, '
          'the rest day before a race, days away, or when already done.',
      changes: true,
      input: const {
        'properties': {
          'sessionId': {'type': 'string'},
          'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
        },
        'required': ['sessionId', 'date'],
      },
      run: (args) async {
        final edits = PlanEdits(db);
        final moved = await edits.moveToDate(
          await _sessionOf(edits, args),
          _day(args, 'date'),
        );
        return {
          'moved': moved.title,
          'to': isoDay(moved.sessionDate.toLocal()),
        };
      },
    ),
    McpTool(
      name: 'mark_rest',
      title: 'Mark a Session as Rest',
      description: 'Lets a planned session go; the plan keeps it as skipped.',
      changes: true,
      input: const {
        'properties': {
          'sessionId': {'type': 'string'},
          'reason': {'type': 'string'},
        },
        'required': ['sessionId'],
      },
      run: (args) async {
        final edits = PlanEdits(db);
        final s = await edits.markRest(
          await _sessionOf(edits, args),
          reason: '${args['reason'] ?? 'Marked as rest'}',
        );
        return {'rest': s.title, 'date': isoDay(s.sessionDate.toLocal())};
      },
    ),
    McpTool(
      name: 'add_workout',
      title: 'Add a Workout',
      description:
          'Plans a new workout on a day from steps. Each step has a kind '
          '(warmup, interval, recovery, rest, cooldown), a zone 1–5 and '
          'either minutes or meters; a repeat has times and steps.',
      changes: true,
      input: const {
        'properties': {
          'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
          'sport': {
            'type': 'string',
            'enum': ['running', 'cycling', 'swimming', 'indoor_rowing'],
          },
          'title': {'type': 'string'},
          'steps': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'kind': {'type': 'string'},
                'zone': {'type': 'integer'},
                'minutes': {'type': 'number'},
                'meters': {'type': 'number'},
                'times': {'type': 'integer'},
                'steps': {'type': 'array'},
              },
            },
          },
        },
        'required': ['date', 'sport', 'title', 'steps'],
      },
      run: (args) async {
        final draft = _draft(args['steps']);
        final s = await PlanEdits(db).create(
          _day(args, 'date'),
          sport: _text(args, 'sport'),
          title: _text(args, 'title'),
          draft: draft,
        );
        return {
          'added': s.title,
          'id': s.id,
          'date': isoDay(s.sessionDate.toLocal()),
          'minutes': s.plannedDurationMin,
          'load': s.plannedTrimp,
        };
      },
    ),
  ];

  static Future<TrainingSession> _sessionOf(
    PlanEdits edits,
    Map<String, Object?> args,
  ) async {
    try {
      return await edits.session(_text(args, 'sessionId'));
    } on StateError {
      throw const McpToolError('No session with that id.');
    }
  }

  static WorkoutDraft _draft(Object? steps) {
    DraftStep step(Map m) {
      final kind =
          DraftStepKind.values.asNameMap()['${m['kind']}'] ??
          DraftStepKind.interval;
      final zone = ((m['zone'] as num?)?.toInt() ?? 2).clamp(1, 5);
      final meters = (m['meters'] as num?)?.round();
      final minutes = (m['minutes'] as num?)?.toDouble();
      if (meters != null && meters > 0) {
        return DraftStep(kind: kind, zone: zone, meters: meters);
      }
      return DraftStep(
        kind: kind,
        zone: zone,
        seconds: ((minutes ?? 5) * 60).round().clamp(10, 6 * 3600),
      );
    }

    if (steps is! List || steps.isEmpty) {
      throw const McpToolError('steps must list at least one step.');
    }
    return WorkoutDraft([
      for (final s in steps.whereType<Map>())
        if (s['steps'] is List)
          DraftRepeat(
            times: ((s['times'] as num?)?.toInt() ?? 1).clamp(1, 50),
            steps: [
              for (final c in (s['steps'] as List).whereType<Map>()) step(c),
            ],
          )
        else
          step(s),
    ]);
  }
}
