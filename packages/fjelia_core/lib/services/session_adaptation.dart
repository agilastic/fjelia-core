import 'dart:convert';
import 'dart:math' as math;

import '../models/plan_views.dart';
import 'readiness.dart';
import 'workout_semantics.dart';

/// Session intensity tiers, easiest first.
const _levels = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

/// One tier easier.
int dropSessionIntensity(int level) {
  final i = _levels.indexOf(level);
  if (i < 0) return level;
  return _levels[(i - 1).clamp(0, _levels.length - 1)];
}

/// What readiness changes in a session.
class SessionChange {
  const SessionChange({
    required this.rest,
    required this.level,
    required this.duration,
    required this.zone,
    required this.title,
    required this.steps,
    required this.trimp,
    required this.notes,
    required this.shift,
  });
  final bool rest;
  final int level, duration, zone, shift;
  final String title, notes;
  final String? steps;
  final int? trimp;
}

/// How the morning readiness changes today's sessions: yellow trims
/// duration by 15 % and drops every HR zone by one, red swaps the session for
/// an easy zone-2 recovery or advises rest.
abstract final class ReadinessAdaptation {
  /// The change readiness asks of [session]; null when it asks none.
  ///
  /// [lastAdaptedLevel] is the readiness level of the session's last
  /// adaptation, for a session already adapted.
  static SessionChange? change(
    PlannedSessionView session,
    ReadinessResult readiness, {
    String? lastAdaptedLevel,
  }) {
    if (readiness.level == ReadinessLevel.green) return null;
    if (session.status == 'adapted') {
      // An earlier adjustment stands unless today's finding is stronger: the
      // same evidence read twice must not cut a session twice.
      final stronger =
          readiness.level == ReadinessLevel.red && lastAdaptedLevel != 'red';
      if (!stronger) return null;
    } else if (session.status != 'planned') {
      return null;
    }

    final red = readiness.level == ReadinessLevel.red;
    // The readiness says rest: that is not a reason to add an easy session.
    final rest = red && readiness.severity == TrainingSeverity.rest;
    final int newLevel;
    final int newDuration;
    final int newZone;
    var newTitle = session.title;
    final String? newSteps;
    final int? newTrimp;
    final String notes;
    var shift = 0;

    if (rest) {
      newLevel = session.sessionLevel;
      newDuration = 0;
      newZone = session.primaryZone;
      newSteps = session.stepsJson;
      newTrimp = null;
      notes =
          'Your readiness says rest today. No replacement session was added; '
          'restore the session if you want to train anyway.';
    } else if (red) {
      newLevel = 1;
      newDuration = math.min(30, session.plannedDurationMin);
      newZone = 1;
      newTitle = 'Easy Recovery ${sportLabel(session.sport)}';
      newSteps = recoveryStepsJson();
      newTrimp = null;
      notes =
          'Your body is signalling it needs more rest today. This easy '
          'session keeps momentum without adding fatigue.';
    } else {
      shift = -1;
      newLevel = dropSessionIntensity(session.sessionLevel);
      newZone = (session.primaryZone - 1).clamp(1, 5);
      notes =
          'Today\'s effort adjusted to match your recovery. Same session, '
          'slightly easier pace.';
      if (session.stepsJson == null) {
        newSteps = null;
        newTrimp = null;
        newDuration = (session.plannedDurationMin * 0.85).round();
      } else {
        // The steps change, not just the number shown: an easy main step is
        // shortened, else one repetition of the first repeat group dropped.
        final shifted = shiftZonesInSteps(session.stepsJson!, shift);
        final base = WorkoutSemantics.of(shifted, sport: session.sport);
        var steps = shifted;
        if (!base.isEmpty) {
          final fitted = fitSteadyWorkout(shifted, base.totalSeconds * 0.85);
          steps = fitted.scaled ? fitted.stepsJson : dropOneRepeat(shifted);
        }
        final result = WorkoutSemantics.of(steps, sport: session.sport);
        newSteps = steps;
        newDuration = result.isEmpty
            ? (session.plannedDurationMin * 0.85).round()
            : result.totalMinutes;
        newTrimp = result.isEmpty ? null : result.legacyLoad.round();
        if (steps != shifted && newDuration != session.plannedDurationMin) {
          newTitle = retimeTitle(session.title, newDuration);
        }
      }
    }

    return SessionChange(
      rest: rest,
      level: newLevel,
      duration: newDuration,
      zone: newZone,
      title: newTitle,
      steps: newSteps,
      trimp: newTrimp,
      notes: notes,
      shift: shift,
    );
  }

  /// Drops one repetition of the first repeat group of three or more.
  static String dropOneRepeat(String stepsJson) {
    final decoded = jsonDecode(stepsJson);
    if (decoded is! List) return stepsJson;
    for (var i = 0; i < decoded.length; i++) {
      final step = decoded[i];
      if (step is! Map || step['workoutSteps'] is! List) continue;
      final n = (step['numberOfIterations'] as num?)?.toInt() ?? 1;
      if (n < 3) continue;
      final out = [...decoded];
      out[i] = {
        ...Map<String, dynamic>.from(step),
        'numberOfIterations': n - 1,
        'endConditionValue': n - 1,
      };
      return jsonEncode(out);
    }
    return stepsJson;
  }

  static String flagsJson(ReadinessResult r) => jsonEncode(<String, bool>{
    'hrv': r.hrvLow,
    'hr': r.restingHrHigh,
    'sleep': r.sleepShort || r.remLow || r.deepLow || r.spo2Low,
    'battery': r.batteryLow,
    'skinTemp': r.skinTempShift,
    'fatigue': r.fatigue,
  });

  /// 5 min warm-up, 20 min steady, 5 min cool-down — all in HR zone 1.
  static String recoveryStepsJson() {
    Map<String, Object> step(int typeId, String key, int seconds) => {
      'type': 'ExecutableStepDTO',
      'stepType': {'stepTypeId': typeId, 'stepTypeKey': key},
      'endCondition': {'conditionTypeId': 2, 'conditionTypeKey': 'time'},
      'endConditionValue': seconds,
      'targetType': {
        'workoutTargetTypeId': 4,
        'workoutTargetTypeKey': 'heart.rate.zone',
      },
      'zoneNumber': 1,
    };
    return jsonEncode(<Map<String, Object>>[
      step(1, 'warmup', 300),
      step(3, 'interval', 1200),
      step(2, 'cooldown', 300),
    ]);
  }

  static String sportLabel(String sport) {
    switch (sport) {
      case 'running' || 'trail_running':
        return 'Run';
      case 'cycling_road' || 'cycling_gravel' || 'cycling_mtb':
        return 'Ride';
      case 'swimming':
        return 'Swim';
      case 'strength':
        return 'Strength';
      case 'indoor_rowing':
        return 'Row';
      default:
        return 'Session';
    }
  }

  static String shiftZonesInSteps(String stepsJson, int shift) =>
      jsonEncode(_shiftList(jsonDecode(stepsJson) as List, shift));

  static List _shiftList(List steps, int shift) => steps.map((step) {
    if (step is! Map) return step;
    final m = Map<String, dynamic>.from(step);
    if (m.containsKey('zoneNumber') && m['zoneNumber'] is int) {
      m['zoneNumber'] = ((m['zoneNumber'] as int) + shift).clamp(1, 5);
    }
    if (m['workoutSteps'] is List) {
      m['workoutSteps'] = _shiftList(m['workoutSteps'] as List, shift);
    }
    return m;
  }).toList();
}
