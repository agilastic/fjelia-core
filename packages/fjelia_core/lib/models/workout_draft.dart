/// A planned workout as blocks the athlete can build and edit: steps of a
/// time or a distance in a zone, and repeats of steps. It reads and writes
/// the stored steps format (the Garmin workout layout the plan uses), so
/// a built workout goes to the watch like any planned one.
library;

import 'dart:convert';

import '../services/workout_semantics.dart';

/// What a step is for.
enum DraftStepKind {
  warmup(1),
  cooldown(2),
  interval(3),
  recovery(4),
  rest(5);

  const DraftStepKind(this.id);

  /// The step type id of the stored format.
  final int id;
}

sealed class DraftItem {
  const DraftItem();
}

/// One step: a time ([seconds]) or a distance ([meters]) in [zone] 1–5.
class DraftStep extends DraftItem {
  const DraftStep({
    required this.kind,
    required this.zone,
    this.seconds,
    this.meters,
    this.note,
  }) : assert((seconds == null) != (meters == null));

  final DraftStepKind kind;
  final int zone;
  final int? seconds;
  final int? meters;
  final String? note;

  DraftStep copyWith({
    DraftStepKind? kind,
    int? zone,
    int? seconds,
    int? meters,
    bool byDistance = false,
    String? note,
  }) {
    final distance = byDistance || (meters != null && seconds == null);
    return DraftStep(
      kind: kind ?? this.kind,
      zone: (zone ?? this.zone).clamp(1, 5),
      seconds: distance ? null : (seconds ?? this.seconds ?? 300),
      meters: distance ? (meters ?? this.meters ?? 1000) : null,
      note: note ?? this.note,
    );
  }
}

/// [steps] done [times] times in a row.
class DraftRepeat extends DraftItem {
  const DraftRepeat({required this.times, required this.steps});
  final int times;
  final List<DraftStep> steps;
}

class WorkoutDraft {
  const WorkoutDraft(this.items);

  final List<DraftItem> items;

  /// A plain start: warm-up, a main block and a cool-down.
  static const starter = WorkoutDraft([
    DraftStep(kind: DraftStepKind.warmup, zone: 1, seconds: 600),
    DraftStep(kind: DraftStepKind.interval, zone: 2, seconds: 1800),
    DraftStep(kind: DraftStepKind.cooldown, zone: 1, seconds: 300),
  ]);

  /// Reads stored steps; steps it does not know become plain intervals so
  /// nothing is lost from view. Null when there is nothing to read.
  static WorkoutDraft? fromStepsJson(String? json) {
    if (json == null || json.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    final list = decoded is Map
        ? decoded['workoutSteps'] ?? decoded['steps']
        : decoded;
    if (list is! List) return null;
    DraftStep? step(Map m) {
      final type = m['stepType'];
      final key = type is Map ? '${type['stepTypeKey']}' : '$type';
      final kind =
          DraftStepKind.values.asNameMap()[key] ?? DraftStepKind.interval;
      final condition = m['endCondition'];
      final unit = condition is Map ? condition['conditionTypeKey'] : 'time';
      final value = (m['endConditionValue'] as num?)?.round();
      final zone = ((m['zoneNumber'] as num?)?.round() ?? 2).clamp(1, 5);
      if (value == null || value <= 0) {
        return DraftStep(kind: kind, zone: zone, seconds: 300);
      }
      return unit == 'distance'
          ? DraftStep(kind: kind, zone: zone, meters: value)
          : DraftStep(kind: kind, zone: zone, seconds: value);
    }

    final items = <DraftItem>[];
    for (final m in list.whereType<Map>()) {
      final children = m['workoutSteps'];
      if (children is List) {
        final times = (m['numberOfIterations'] as num?)?.round() ?? 1;
        items.add(
          DraftRepeat(
            times: times.clamp(1, 99),
            steps: [for (final c in children.whereType<Map>()) ?step(c)],
          ),
        );
      } else if (step(m) case final s?) {
        items.add(s);
      }
    }
    return items.isEmpty ? null : WorkoutDraft(items);
  }

  String toStepsJson() {
    var order = 0;
    Map<String, Object?> step(DraftStep s) => {
      'type': 'ExecutableStepDTO',
      'stepOrder': ++order,
      'stepType': {'stepTypeId': s.kind.id, 'stepTypeKey': s.kind.name},
      'endCondition': s.meters != null
          ? {'conditionTypeId': 3, 'conditionTypeKey': 'distance'}
          : {'conditionTypeId': 2, 'conditionTypeKey': 'time'},
      'endConditionValue': s.meters ?? s.seconds,
      'targetType': {
        'workoutTargetTypeId': 4,
        'workoutTargetTypeKey': 'heart.rate.zone',
      },
      'zoneNumber': s.zone,
      if (s.note case final n? when n.isNotEmpty) 'description': n,
    };
    return jsonEncode([
      for (final item in items)
        switch (item) {
          DraftStep() => step(item),
          DraftRepeat(:final times, :final steps) => {
            'type': 'RepeatGroupDTO',
            'stepOrder': ++order,
            'stepType': {'stepTypeId': 6, 'stepTypeKey': 'repeat'},
            'numberOfIterations': times,
            'endCondition': {
              'conditionTypeId': 7,
              'conditionTypeKey': 'iterations',
            },
            'endConditionValue': times,
            'workoutSteps': [for (final s in steps) step(s)],
          },
        },
    ]);
  }

  /// Duration, zones and load as the plan counts them.
  WorkoutSemantics semantics({String sport = ''}) =>
      WorkoutSemantics.of(toStepsJson(), sport: sport);
}
