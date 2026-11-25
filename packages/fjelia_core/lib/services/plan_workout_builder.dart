import 'dart:convert';
import 'dart:math' as math;

import '../models/plan_views.dart';
import '../models/race_profile.dart';
import '../models/workout_profile.dart' show formatBlockDuration;
import '../utils/target_time.dart';
import 'plan_rules.dart';
import 'season/goal_set.dart';
import 'season/season_goal.dart';
import 'season/week_allocator.dart';
import 'workout_semantics.dart';

/// Builds the workouts of a plan: durations, steps, templates and the
/// description text a watch shows. Holds no data of its own.
class PlanWorkoutBuilder {
  /// 0.7–1.1 multiplier from form (TSB), HRV ratio and sleep.
  double readinessFactor(PlanAthleteFitnessSnapshot s) {
    final form = ((s.tsb + 20) / 40).clamp(0.0, 1.0);
    final hrv = ((s.hrvRatio - 0.9) / 0.15).clamp(0.0, 1.0);
    final sleep = s.sleepScore == null
        ? 0.5
        : ((s.sleepScore! - 50) / 35).clamp(0.0, 1.0);
    return 0.7 + 0.4 * (form * 0.4 + hrv * 0.4 + sleep * 0.2);
  }

  int ctlScaledDuration(
    int baseMin,
    String sessionType,
    String tier,
    double ctl,
  ) {
    if (sessionType == 'recovery') return baseMin;
    final ctlF = ctl < 30
        ? 0.7
        : ctl < 60
        ? 1.0
        : ctl < 90
        ? 1.15
        : 1.3;
    final tierF = switch (tier) {
      'beginner' => 0.9,
      'advanced' => 1.1,
      _ => 1.0,
    };
    final factor = (ctlF * tierF).clamp(0.6, 1.4);
    return (baseMin * factor).round().clamp(20, 600);
  }

  static int baseDuration(String sessionType) => switch (sessionType) {
    'long' => 90,
    'key' => 55,
    'recovery' => 40,
    'assessment' => 50,
    _ => 45,
  };

  /// Drops the least important sessions until the rest fits in [limit]
  /// minutes. Used when time has already been spent that no session stands
  /// for.
  static ({List<PlanSessionSlot> kept, List<PlanSessionSlot> removed}) makeRoom(
    List<PlanSessionSlot> slots,
    double limit,
  ) {
    final list = [...slots];
    final removed = <PlanSessionSlot>[];
    int total() => list.fold(0, (a, s) => a + (s.targetMin ?? 0));
    while (list.isNotEmpty && total() > limit) {
      var worst = 0;
      for (var i = 1; i < list.length; i++) {
        final a = list[i], b = list[worst];
        final byRank = (a.rank ?? 9).compareTo(b.rank ?? 9);
        if (byRank > 0 ||
            (byRank == 0 && (a.targetMin ?? 0) < (b.targetMin ?? 0))) {
          worst = i;
        }
      }
      removed.add(list.removeAt(worst));
    }
    return (kept: list, removed: removed);
  }

  /// The race a run is paced against: the goal the session prepares for when
  /// that is a running goal, else the most important running goal. A ride
  /// goal never sets a run's pace.
  static RaceProfile? paceProfile(
    GoalSet goals,
    PlanSessionSlot slot,
    RaceProfile? single,
    bool multi,
  ) {
    if (!multi) return single;
    bool foot(SeasonGoal g) =>
        g.sport == 'running' || g.sport == 'trail_running';
    var goal = slot.goalId == null ? null : goals.byId(slot.goalId!);
    if (goal == null || !foot(goal)) {
      final runs = goals.active.where(foot).toList()
        ..sort((a, b) {
          final byPriority = a.priority.index.compareTo(b.priority.index);
          return byPriority != 0 ? byPriority : a.date.compareTo(b.date);
        });
      goal = runs.isEmpty ? null : runs.first;
    }
    return goal?.profile;
  }

  /// What the athlete has done in each sport, as the allocator reads it.
  static Map<String, SportCapacity> capacitiesOf(PlanTrainingHistory history) =>
      {
        for (final e in history.sports.entries)
          e.key: SportCapacity(
            sessions: e.value.sessions,
            longestMin: e.value.longestMin,
            medianMin: e.value.medianMin,
            yearLongestMin: e.value.yearLongestMin,
          ),
      };

  /// The allocator's session as a slot of the weekly scheduling loop.
  static PlanSessionSlot slotOf(AllocatedSlot a) => PlanSessionSlot(
    a.sport,
    a.sessionType,
    a.subType,
    a.zone,
    a.weekday,
    goalId: a.goalId,
    goalRole: a.role,
    objective: a.objective,
    targetMin: a.targetMin,
    minMin: a.minMin,
    maxMin: a.maxMin,
    rank: a.rank,
    phase: a.phase.isEmpty ? null : a.phase,
    maxZone: a.maxZone,
  );

  /// Days after an event take easy sessions only, and short ones.
  static bool easyEnough(PlanSessionSlot s) =>
      s.sport != 'strength' &&
      s.zone <= 2 &&
      (s.targetMin ?? 60) <= 60 &&
      s.sessionType != 'key';

  /// A steady endurance workout of [minutes] in [zone]: a short warm-up, one
  /// long block and a cool-down. Used where no template is as long as the
  /// session; the heart-rate or power target is filled in like any other.
  static String steadySteps(int minutes, int zone) {
    Map<String, dynamic> step(String type, int id, int seconds, int z) => {
      'type': 'ExecutableStepDTO',
      'stepType': {'stepTypeId': id, 'stepTypeKey': type},
      'endCondition': {'conditionTypeId': 2, 'conditionTypeKey': 'time'},
      'endConditionValue': seconds,
      'targetType': {
        'workoutTargetTypeId': 4,
        'workoutTargetTypeKey': 'heart.rate.zone',
      },
      'zoneNumber': z,
    };
    final warm = minutes >= 45 ? 600 : 300;
    final cool = minutes >= 45 ? 300 : 0;
    final main = math.max(300, minutes * 60 - warm - cool);
    return jsonEncode([
      step('warmup', 1, warm, 1),
      step('interval', 3, main, zone),
      if (cool > 0) step('cooldown', 2, cool, 1),
    ]);
  }

  static String steadyTitle(
    String sport,
    int minutes, {
    String lead = 'Long endurance',
  }) {
    final noun = sport.startsWith('cycl')
        ? 'ride'
        : sport == 'running' || sport == 'trail_running'
        ? 'run'
        : sport.replaceAll('_', ' ');
    return '$lead $noun ($minutes min)';
  }

  List<PlanSessionSlot> recoveryWeekSlots(String sport) {
    final main = switch (sport) {
      'cycling_road' || 'cycling_gravel' || 'cycling_mtb' => sport,
      'swimming' => 'swimming',
      'indoor_rowing' => 'indoor_rowing',
      'triathlon' => 'running',
      _ => sport,
    };
    return [
      PlanSessionSlot(main, 'long', 'endurance', 2, 6),
      PlanSessionSlot(main, 'recovery', null, 1, 3),
      planYoga,
      PlanSessionSlot(main, 'recovery', null, 1, 1),
    ];
  }

  /// Each template's working zone and zone 5 minutes, from its steps.
  final _templateSemantics = <String, WorkoutSemantics>{};

  T? pickTemplateFromCache<T extends WorkoutTemplateView>(
    List<T> templates,
    String sport,
    String sessionType,
    String? subType,
    String phase,
    int durationMin,
    int seed, {
    int? minZone,
    double? maxZone5Min,
    bool baseIntervals = false,
  }) {
    final templateSport =
        sport.startsWith('cycling') && !templates.any((t) => t.sport == sport)
        ? 'cycling_road'
        : sport;
    var pool = templates
        .where((t) => t.sport == templateSport && t.sessionType == sessionType)
        .toList();
    if (pool.isEmpty) return null;
    final ofSport = pool;

    // Phase match, widening to neighbouring phases if needed.
    final idx = planPhaseOrder.indexOf(phase);
    final phases = <String>{phase};
    if (idx > 0) phases.add(planPhaseOrder[idx - 1]);
    if (idx >= 0 && idx < planPhaseOrder.length - 1) {
      phases.add(planPhaseOrder[idx + 1]);
    }
    final exact = pool
        .where((t) => t.targetPhase.split(',').contains(phase))
        .toList();
    final near = pool
        .where((t) => t.targetPhase.split(',').any(phases.contains))
        .toList();
    pool = exact.isNotEmpty
        ? exact
        : near.isNotEmpty
        ? near
        : pool;

    // Base-phase intervals on the bike are threshold work.
    var wanted = subType;
    if (wanted == 'intervals' &&
        phase == 'base' &&
        !baseIntervals &&
        sport.startsWith('cycling')) {
      wanted = 'threshold';
      if (minZone != null) minZone = math.min(minZone, 4);
    }
    if (wanted != null) {
      final bySub = pool.where((t) => t.subType == wanted).toList();
      if (bySub.isNotEmpty) pool = bySub;
    }
    // A quality session as hard as its slot asks: threshold must not become
    // a zone 3 tempo template, nor race intensity a zone 2 "fast finish". The
    // phase's own templates first, then a neighbouring phase's, then any.
    if (minZone != null) {
      int? zoneOf(T t) => _templateSemantics
          .putIfAbsent(
            t.id,
            () => WorkoutSemantics.of(t.stepsJson, sport: t.sport),
          )
          .topZone;
      // Its zone exactly first (threshold no zone 5 workout either), with
      // its sub-type, then of any sub-type, then at least its zone; and only
      // one of about the wanted length: a structured workout is not cut to
      // fit the day.
      final atLeast = minZone;
      // A shorter one of the right zone comes before a harder one: it
      // always fits the day.
      bool fits(
        T t, {
        required bool exact,
        required bool subType,
        bool shorter = false,
        bool anyLength = false,
      }) {
        final zone = zoneOf(t) ?? 0;
        final length = t.estimatedDurationMin;
        return (!subType || wanted == null || t.subType == wanted) &&
            zone >= atLeast &&
            (!exact || zone <= math.max(atLeast, 4)) &&
            (anyLength ||
                (shorter
                    ? length >= durationMin * 0.4 &&
                          length <= durationMin * 1.15
                    : (length - durationMin).abs() <= durationMin * 0.4));
      }

      search:
      // When no length fits (a week with 20 min left), the right zone still
      // comes first; the length choice below then takes the closest.
      for (final (exact, subType, shorter, anyLength) in [
        (true, true, false, false),
        (true, false, false, false),
        (true, true, true, false),
        (true, false, true, false),
        (false, true, false, false),
        (true, true, false, true),
        (true, false, false, true),
      ]) {
        for (final candidates in [
          pool,
          ofSport.where((t) => t.targetPhase.split(',').any(phases.contains)),
          ofSport,
        ]) {
          final hardEnough = candidates
              .where(
                (t) => fits(
                  t,
                  exact: exact,
                  subType: subType,
                  shorter: shorter,
                  anyLength: anyLength,
                ),
              )
              .toList();
          if (hardEnough.isNotEmpty) {
            pool = hardEnough;
            break search;
          }
        }
      }
    }
    // A short dose of zone 5 where the goal asks for one, not the biggest
    // VO2max workout of the library.
    if (maxZone5Min != null) {
      final dosed = pool
          .where(
            (t) =>
                _templateSemantics
                    .putIfAbsent(
                      t.id,
                      () => WorkoutSemantics.of(t.stepsJson, sport: t.sport),
                    )
                    .zone5Minutes <=
                maxZone5Min,
          )
          .toList();
      if (dosed.isNotEmpty) pool = dosed;
    }

    // Close to the wanted length: within 15 %, else within 40 %, else the
    // nearest few. Never an arbitrary template of the pool, whose steps would
    // run for a different time than the plan shows.
    List<T> within(double share) => pool
        .where(
          (t) =>
              (t.estimatedDurationMin - durationMin).abs() <=
              durationMin * share,
        )
        .toList();
    var closest = within(0.15);
    if (closest.isEmpty) closest = within(0.4);
    if (closest.isEmpty) {
      final byCloseness = [...pool]
        ..sort(
          (a, b) => (a.estimatedDurationMin - durationMin).abs().compareTo(
            (b.estimatedDurationMin - durationMin).abs(),
          ),
        );
      closest = byCloseness.take(3).toList();
    }
    pool = closest;

    return pool[seed % pool.length];
  }

  /// Makes the targets of a step concrete.
  ///
  /// Every step gets its zone number, taken from the template or, for a
  /// template written as a share of FTP, worked out from that share. The target
  /// is then heart rate in the athlete's zones. Only where [power] is true and
  /// an FTP is known does a step keep a power target in watts: a heart-rate
  /// workout must not turn into a power workout for someone without a meter.
  Map<String, dynamic> resolveStep(
    Map<String, dynamic> step,
    int? ftp,
    PlanAthleteFitnessSnapshot fitness, {
    required bool power,
  }) {
    if (step['type'] == 'RepeatGroupDTO') {
      final iterations =
          (step['numberOfIterations'] as num?)?.toInt() ??
          (step['endConditionValue'] as num?)?.toInt() ??
          1;
      final inner =
          (step['workoutSteps'] as List?)
              ?.cast<Map<String, dynamic>>()
              .map((s) => resolveStep(s, ftp, fitness, power: power))
              .toList() ??
          <Map<String, dynamic>>[];
      return Map<String, dynamic>.of(step)
        ..['numberOfIterations'] = iterations
        ..['workoutSteps'] = inner;
    }

    final out = Map<String, dynamic>.from(step);
    // A ramp test stage keeps its own heart rates: they are not a zone.
    if (out['fixedTarget'] == true) return out;
    final hasFraction =
        out.containsKey('ftpFraction') || out.containsKey('ftpLow');
    final fraction = stepFraction(out, ftp);
    var zone = (out['zoneNumber'] as num?)?.toInt();
    // Sprints are written as a sixth zone; heart rate has five, and the top one
    // runs to the maximum, so that is where a sprint reads on the watch.
    if (zone != null && zone > 5) zone = 5;
    if ((zone == null || zone < 1 || zone > 5) && fraction != null) {
      zone = zoneForFtpFraction(fraction);
    }
    // Zone 1 for a runner is the lower half of zone 2 (see easyRunZ2). A
    // warm-up, cool-down or rest step stays as planned: walking or jogging
    // there is what those steps are for.
    // The step remembers it, so resolving it again with other zones (when the
    // workout is sent, or the zones change) keeps the lower half of zone 2.
    final stepKey = (out['stepType'] as Map?)?['stepTypeKey'];
    final easyRun =
        fitness.easyRunZ2 &&
        (out['easyRun'] == true ||
            zone == 1 &&
                stepKey != 'warmup' &&
                stepKey != 'cooldown' &&
                stepKey != 'recovery' &&
                stepKey != 'rest');
    if (easyRun) {
      zone = 2;
      out['easyRun'] = true;
    }
    if (zone != null && zone >= 1 && zone <= 5) out['zoneNumber'] = zone;

    final key = (out['targetType'] as Map?)?['workoutTargetTypeKey'];
    final isPowerStep = hasFraction || key == 'power.zone';
    if (power && ftp != null && hasFraction) {
      if (out.containsKey('ftpFraction')) {
        final f = (out['ftpFraction'] as num).toDouble();
        out['targetValueOne'] = (ftp * f * 0.95).round().toDouble();
        out['targetValueTwo'] = (ftp * f * 1.05).round().toDouble();
      } else {
        out['targetValueOne'] = (ftp * (out['ftpLow'] as num).toDouble())
            .round()
            .toDouble();
        out['targetValueTwo'] = (ftp * (out['ftpHigh'] as num).toDouble())
            .round()
            .toDouble();
      }
      out['targetType'] = {
        'workoutTargetTypeId': 2,
        'workoutTargetTypeKey': 'power.zone',
        'displayOrder': 2,
      };
    } else if (power &&
        ftp != null &&
        !isPowerStep &&
        zone != null &&
        zone >= 1 &&
        zone <= 5) {
      // Planned as heart rate, ridden on a smart trainer: the zone gives the
      // watts, and the heart-rate range stays as the guide beside them.
      final w = planPowerZones[zone]!;
      final hr = fitness.hrRangeForZone(zone);
      out['targetValueOne'] = (ftp * w.lo).round().toDouble();
      out['targetValueTwo'] = (ftp * w.hi).round().toDouble();
      out['targetType'] = {
        'workoutTargetTypeId': 2,
        'workoutTargetTypeKey': 'power.zone',
        'displayOrder': 2,
      };
      if (hr.low != null || hr.high != null) {
        final own = (out['description'] as String?)?.trim();
        final guide =
            'HR ${hr.low ?? (hr.high! - 15)}–${hr.high ?? (hr.low! + 15)} bpm';
        out['description'] = own == null || own.isEmpty
            ? guide
            : '$guide · $own';
      }
    } else if (isPowerStep && !(power && ftp != null)) {
      // Heart rate instead. A zone is always given with its heart rates, a
      // short effort included: the athlete reads the range on the watch, and
      // the data is there for whoever looks at the workout later.
      final useHr = zone != null && zone >= 1 && zone <= 5;
      out['targetType'] = useHr
          ? {
              'workoutTargetTypeId': 4,
              'workoutTargetTypeKey': 'heart.rate.zone',
              'displayOrder': 4,
            }
          : {
              'workoutTargetTypeId': 1,
              'workoutTargetTypeKey': 'no.target',
              'displayOrder': 1,
            };
      out.remove('targetValueOne');
      out.remove('targetValueTwo');
    }
    // A step that names a zone but has no target gets the zone's heart rates:
    // a zone without its data is only half an instruction. Steps that use
    // power, or a target of their own (pace, cadence), are left alone.
    final tail = (out['targetType'] as Map?)?['workoutTargetTypeKey'];
    if ((tail == null || tail == 'no.target') &&
        zone != null &&
        zone >= 1 &&
        zone <= 5) {
      out['targetType'] = {
        'workoutTargetTypeId': 4,
        'workoutTargetTypeKey': 'heart.rate.zone',
        'displayOrder': 4,
      };
    }
    out
      ..remove('ftpFraction')
      ..remove('ftpLow')
      ..remove('ftpHigh');

    final target = out['targetType'] as Map?;
    if (target?['workoutTargetTypeKey'] == 'heart.rate.zone') {
      final z = (out['zoneNumber'] as num?)?.toInt();
      if (z != null) {
        final r = easyRun ? fitness.easyRunRange() : fitness.hrRangeForZone(z);
        if (r.low != null || r.high != null) {
          out['targetValueOne'] = (r.low ?? (r.high! - 15)).toDouble();
          out['targetValueTwo'] = (r.high ?? (r.low! + 15)).toDouble();
        }
      }
    }
    return out;
  }

  /// The share of FTP a step asks for: from its own fields, or from the
  /// target values (fractions below 3, watts above 5 with an [ftp]).
  static double? stepFraction(Map<String, dynamic> step, int? ftp) {
    double? number(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    final single = number(step['ftpFraction']);
    if (single != null) return single;
    final low = number(step['ftpLow']), high = number(step['ftpHigh']);
    if (low != null && high != null) return (low + high) / 2;
    final one = number(step['targetValueOne']);
    final two = number(step['targetValueTwo']);
    if (one == null || two == null) return null;
    final mean = (one + two) / 2;
    if (mean > 0 && mean < 3) return mean;
    if (mean > 5 && ftp != null && ftp > 0) return mean / ftp;
    return null;
  }

  String resolveStepsJson(
    String stepsJson,
    int? ftp,
    PlanAthleteFitnessSnapshot fitness, {
    required bool power,
  }) {
    final steps = (jsonDecode(stepsJson) as List).cast<Map<String, dynamic>>();
    return jsonEncode(
      steps.map((s) => resolveStep(s, ftp, fitness, power: power)).toList(),
    );
  }

  ({String? text, int? minutes}) extractWarmUpDescription(String stepsJson) {
    try {
      final steps = (jsonDecode(stepsJson) as List)
          .cast<Map<String, dynamic>>();
      for (final s in steps) {
        final type =
            (s['stepType'] as Map<String, dynamic>?)?['stepTypeKey'] ??
            s['intensity'];
        if (type?.toString().toLowerCase() != 'warmup') continue;
        final secs = (s['endConditionValue'] as num?)?.toInt();
        final text = s['stepName'] as String? ?? s['description'] as String?;
        return (
          text:
              text ?? (secs == null ? 'Warm-up' : 'Warm-up ${secs ~/ 60} min'),
          minutes: secs == null ? null : secs ~/ 60,
        );
      }
    } catch (_) {}
    return (text: null, minutes: null);
  }

  /// Session difficulty 1–9 from type, zone and phase.
  static int sessionLevel(String sessionType, int zone, String phase) {
    var level = switch (sessionType) {
      'recovery' => 2,
      'long' => 5,
      'key' => 4 + zone.clamp(1, 5) - 2,
      'assessment' => 7,
      _ => 4,
    };
    if (phase == 'peak') level += 1;
    if (phase == 'taper' || phase == 'recovery') level -= 1;
    return level.clamp(1, 9);
  }

  /// Lines about the race goal and, for a run, the pace that goes with this
  /// session. The pace is a guide; the heart-rate target decides.
  static List<String>? goalLines(PlannedSessionView s, RaceGoalView? goal) {
    final lines = <String>[];
    // The A goal is "the race goal"; any other is named, so a brevet ride
    // never reads like marathon preparation.
    final isTop = goal?.priority.toLowerCase() == 'a';
    final label = goal == null || isTop
        ? 'Race goal'
        : 'Goal ${goal.priority.toUpperCase()} · ${goal.name}';
    if (goal != null && goal.targetFinishSeconds != null) {
      final profile = RaceProfile(
        sport: goal.primarySport,
        distanceM: goal.distanceM,
        elevationM: goal.elevationM,
        targetSeconds: goal.targetFinishSeconds,
      );
      final flat = profile.flatEquivalentPaceSecPerKm;
      final climb = profile.isRide && goal.elevationM != null
          ? ', ${goal.elevationM!.round()} m climbing'
          : '';
      lines.add(
        '$label: ${formatTargetTime(goal.targetFinishSeconds!)} for '
        '${(goal.distanceM / 1000).toStringAsFixed(1)} km'
        '${profile.isRide
            ? ' (${profile.goalSpeedKmh!.toStringAsFixed(1)} km/h)$climb'
            : flat == null
            ? ''
            : ' (${formatPace(profile.goalPaceSecPerKm!)}, ${formatPace(flat)} on the flat)'}.',
      );
    } else if (goal != null && !isTop) {
      lines.add(
        '$label: ${(goal.distanceM / 1000).toStringAsFixed(1)} km'
        '${goal.elevationM == null ? '' : ', ${goal.elevationM!.round()} m climbing'}.',
      );
    }
    if (s.goalObjective != null) {
      lines.add('Purpose: ${s.goalObjective}.');
    }
    try {
      final json = s.paceRangesJson;
      if (json != null) {
        final pace = jsonDecode(json) as Map<String, dynamic>;
        final low = pace['low_sec_per_km'], high = pace['high_sec_per_km'];
        if (low is num && high is num) {
          lines.add(
            'Pace guide: ${formatPace(low.toDouble())} to ${formatPace(high.toDouble())}'
            '${pace['basis'] == 'goal' ? ', estimated from your goal' : ''}. '
            'Heart rate decides.',
          );
        }
      }
    } catch (_) {}
    return lines.isEmpty ? null : lines;
  }

  /// Each step gets its target as a note ("Z2 · 110–127 bpm") so the watch
  /// shows what is asked even where it hides the target type.
  static List<Map<String, dynamic>> withNotes(
    List<Map<String, dynamic>> steps,
  ) => [
    for (final step in steps)
      if (step['workoutSteps'] is List)
        {
          ...step,
          'workoutSteps': withNotes(
            (step['workoutSteps'] as List).cast<Map<String, dynamic>>(),
          ),
        }
      else
        () {
          final note = stepNote(step);
          if (note == null) return step;
          final own = (step['description'] as String?)?.trim();
          return {
            ...step,
            'description': own == null || own.isEmpty ? note : '$note · $own',
          };
        }(),
  ];

  static String? stepNote(Map<String, dynamic> step) {
    final zone = (step['zoneNumber'] as num?)?.toInt();
    final key = (step['targetType'] as Map?)?['workoutTargetTypeKey'];
    final one = step['targetValueOne'], two = step['targetValueTwo'];
    final parts = <String>[
      if (zone != null && zone >= 1) 'Z$zone',
      if (key == 'heart.rate.zone' && one is num && two is num)
        '${one.round()}–${two.round()} bpm',
      if (key == 'power.zone' && one is num && two is num)
        '${one.round()}–${two.round()} W',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The comment on the Garmin workout: the session's notes, then everything
  /// the athlete needs to carry it out, so nothing depends on reading the
  /// targets from the watch screen.
  String garminDescription(
    PlannedSessionView s,
    List<Map<String, dynamic>> steps, {
    required bool power,
    RaceGoalView? goal,
  }) {
    String label(Map<String, dynamic> step) {
      final type = (step['stepType'] as Map?)?['stepTypeKey'];
      return switch (type) {
        'warmup' => 'Warm-up',
        'cooldown' => 'Cool-down',
        'recovery' => 'Recovery',
        'rest' => 'Rest',
        'interval' => 'Interval',
        _ => 'Step',
      };
    }

    String length(Map<String, dynamic> step) {
      final condition = (step['endCondition'] as Map?)?['conditionTypeKey'];
      final value = (step['endConditionValue'] as num?)?.toDouble();
      if (value == null || value <= 0) return 'Until lap press';
      return condition == 'distance'
          ? (value >= 1000
                ? '${(value / 1000).toStringAsFixed(1)} km'
                : '${value.round()} m')
          : formatBlockDuration(value);
    }

    final lines = <String>[];
    void walk(List<Map<String, dynamic>> items, String indent) {
      for (final step in items) {
        if (step['workoutSteps'] is List) {
          final n = (step['numberOfIterations'] as num?)?.toInt() ?? 1;
          lines.add('$indent$n× repeat');
          walk(
            (step['workoutSteps'] as List).cast<Map<String, dynamic>>(),
            '$indent  ',
          );
          continue;
        }
        final note = stepNote(step);
        lines.add(
          '$indent${length(step)} ${label(step)}${note == null ? '' : ' · $note'}',
        );
      }
    }

    walk(steps, '');
    final total = WorkoutSemantics.of(jsonEncode(steps), sport: s.sport);
    final notes = s.sessionNotes?.trim();
    final text = [
      if (notes != null && notes.isNotEmpty) ...[notes, ''],
      power
          ? 'TARGETS: power where it is set, with heart rate as the guide.'
          : 'TARGETS: heart rate in your zones. No power or pace targets.',
      ...lines,
      'Total ${total.totalMinutes} min${total.isExact ? '' : ' (partly estimated)'}.',
      ...?goalLines(s, goal),
    ].join('\n');
    // The description has a length limit; keep the targets, shorten the rest.
    return text.length <= 1500 ? text : '${text.substring(0, 1497)}...';
  }

  static List<int> zonesFromJson(String? json) {
    if (json == null) return const [];
    try {
      return (jsonDecode(json) as List).map((e) => (e as num).round()).toList();
    } catch (_) {
      return const [];
    }
  }
}
