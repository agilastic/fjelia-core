import 'dart:convert';
import 'dart:math' as math;

import '../models/plan_views.dart';
import '../models/race_profile.dart';
import '../utils/log.dart';
import '../utils/week.dart';
import 'plan_rules.dart';
import 'plan_workout_builder.dart';
import 'ramp_test.dart';
import 'season/goal_set.dart';
import 'season/season_goal.dart';
import 'season/season_report.dart';
import 'season/season_timeline.dart';
import 'season/week_allocator.dart';
import 'session_stress.dart';
import 'strength/strength_templates.dart';
import 'workout_semantics.dart';

/// One write of a plan run, in the order the generator made it.
sealed class PlanWrite {
  const PlanWrite();
}

/// A planned session the app stores.
class GeneratedPlanSession extends PlanWrite {
  const GeneratedPlanSession({
    required this.sessionDate,
    required this.sessionNumber,
    required this.weekNumber,
    required this.sport,
    required this.sessionType,
    required this.subType,
    required this.phase,
    required this.primaryZone,
    required this.title,
    required this.sessionNotes,
    required this.mainSet,
    required this.warmUp,
    required this.warmUpDurationMin,
    required this.stepsJson,
    required this.hrRangesJson,
    required this.paceRangesJson,
    required this.powerRangesJson,
    required this.plannedDurationMin,
    required this.plannedTrimp,
    required this.sessionLevel,
    required this.goalId,
    required this.goalRole,
    required this.goalObjective,
  });

  final DateTime sessionDate;
  final int sessionNumber;
  final int weekNumber;
  final String sport;
  final String sessionType;
  final String? subType;
  final String phase;
  final int primaryZone;
  final String title;
  final String? sessionNotes;
  final String? mainSet;
  final String? warmUp;
  final int? warmUpDurationMin;
  final String? stepsJson;
  final String? hrRangesJson;
  final String? paceRangesJson;
  final String? powerRangesJson;
  final int plannedDurationMin;
  final int plannedTrimp;
  final int sessionLevel;
  final String? goalId;
  final String? goalRole;
  final String? goalObjective;
}

/// The summary of one planned week. An existing summary of the same week
/// keeps its fitness values and takes [weekNumberOnUpdate].
class GeneratedWeekSummary extends PlanWrite {
  const GeneratedWeekSummary({
    required this.weekStart,
    required this.weekNumber,
    required this.weekNumberOnUpdate,
    required this.phase,
    required this.plannedTrimp,
    required this.sessionsPlanned,
    required this.ctl,
    required this.tsb,
  });

  /// The Monday of the week.
  final DateTime weekStart;
  final int weekNumber;
  final int weekNumberOnUpdate;
  final String phase;
  final int plannedTrimp;
  final int sessionsPlanned;
  final double ctl;
  final double tsb;
}

/// What a plan run produced.
class PlanGeneration {
  const PlanGeneration({
    required this.writes,
    required this.report,
    required this.sessionNumber,
  });

  final List<PlanWrite> writes;
  final SeasonReport report;

  /// The number of the last session planned.
  final int sessionNumber;
}

/// Plans the weeks of a season: slots, durations, workouts and the season
/// report, from inputs the app has loaded.
class PlanWeekGenerator {
  PlanWeekGenerator(
    this._build, {
    required bool Function(String sport, bool indoor) usesPower,
  }) : _usesPower = usesPower;

  final PlanWorkoutBuilder _build;
  final bool Function(String sport, bool indoor) _usesPower;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _addDays(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  /// [readFitness] reads the fitness snapshot of another sport, for seasons
  /// with goals in several sports.
  Future<PlanGeneration> generate({
    required Set<String> allowedSports,
    required DateTime anchorWeek,
    required PlanAthleteProfile athlete,
    required List<PlanSessionSlot> baseSlots,
    required double baseWeeklyTss,
    required int? Function(DateTime) capOn,
    required bool casual,
    required String? casualGoal,
    required int daysPerWeek,
    required List<({DateTime day, int minutes})> doneToday,
    required Set<DateTime> easeInDays,
    required DateTime end,
    required int firstIndex,
    required PlanAthleteFitnessSnapshot fitness,
    required int? ftp,
    required int gadIndex,
    required List<String> gadSports,
    required GoalSet goalSet,
    required Set<DateTime> healthDays,
    required PlanTrainingHistory history,
    required List<PlannedSessionView> kept,
    required Map<String, DateTime?> lastRamp,
    required int longRunCap,
    required String mainSport,
    required int maxSessionsPerDay,
    required bool multi,
    required DateTime? nextRamp,
    required bool prependRecovery,
    required DateTime raceDay,
    required String? raceGoalId,
    required RaceProfile? raceProfile,
    required String? Function(String) rampFamilyOf,
    required double readiness,
    required List<int> restDays,
    required List<String> rotation,
    required int sessionNumber,
    required String sport,
    required List<int> strengthDays,
    required double targetWeeklyMin,
    required List<WorkoutTemplateView> templates,
    required Terrain terrain,
    required double? thresholdPaceMps,
    required DateTime today,
    required bool weekStartsOnMonday,
    required int weeks,
    required Future<PlanAthleteFitnessSnapshot> Function(String sport)
    readFitness,
  }) async {
    final writes = <PlanWrite>[];
    // The season: which goal asks what of each week, what the weeks hold and
    // where the days are taken by an event.
    final timeline = SeasonTimeline(
      goals: goalSet,
      anchorWeek: anchorWeek,
      mondayFirst: weekStartsOnMonday,
      cycle: athlete.recoveryCycle,
    );
    final capacities = PlanWorkoutBuilder.capacitiesOf(history);
    final goalSports = {
      for (final g in goalSet.active) ...SeasonTimeline.sportsOf(g).keys,
    };
    // Sports of the same family as a goal sport are not variety: a gravel
    // ride is the road goal's own sport. Variety needs the sport's own
    // history, so a sport the athlete never does is never scheduled.
    String family(String s) => s.startsWith('cycl')
        ? 'cycling'
        : s == 'running' || s == 'trail_running'
        ? 'running'
        : s;
    final goalFamilies = {for (final s in goalSports) family(s)};
    final varietySports = [
      for (final s in planGadSportRotation(gadSports))
        if (!goalFamilies.contains(family(s)) && history.sports[s] != null) s,
    ];
    final allocations = <WeekAllocation>[];
    final weekReports = <WeekReport>[];
    // Days that carried a long session or an event, with its minutes: the day
    // next to one is no place for a second hard day.
    final longDates = <DateTime, int>{
      for (final g in goalSet.relevant)
        if (g.demand.planningMinutes >= 150)
          g.date: g.demand.planningMinutes.round(),
    };
    // Days that already hold a quality (key, not strength) session.
    final keyDates = <DateTime>{};
    // The load of each day (session_stress.dart), events included: a key
    // session does not go next to a day that, with it, is too much.
    final dayStress = <DateTime, double>{
      for (final g in goalSet.relevant)
        localDay(g.date): sessionStress(
          sport: g.demand.sport,
          minutes: g.demand.planningMinutes.round(),
          zone: 3,
        ),
    };
    // The load a slot will have before its workout exists: a key session
    // at zone 4 or more, since its template may reach zone 4 (a steady slot
    // can get a tempo workout), and at least 50 min.
    double plannedStress(PlanSessionSlot s) {
      final key = s.sessionType == 'key' && s.sport != 'strength';
      return sessionStress(
        sport: s.sport,
        minutes: key ? math.max(50, s.targetMin ?? 60) : s.targetMin ?? 60,
        zone: key ? math.max(4, s.zone) : s.zone,
      );
    }

    bool heavyNextTo(DateTime day, double stress) => [-1, 1].any(
      (n) => heavyPair(stress, dayStress[_addDays(day, n)] ?? 0, margin: 0.9),
    );
    // A long event raced to finish (6 h on foot, 4 h otherwise, without the
    // ambition "performance") needs a short dose of zone 5, not a big one.
    bool longFinish(String? goalId) {
      final g =
          goalSet.all
              .where((g) => g.id == (goalId ?? raceGoalId))
              .firstOrNull ??
          goalSet.display;
      if (g == null || g.ambition == Ambition.performance) return false;
      return g.demand.planningMinutes >= (g.demand.isFoot ? 360 : 240);
    }

    final sportFitness = <String, PlanAthleteFitnessSnapshot>{
      mainSport: fitness,
    };
    Future<PlanAthleteFitnessSnapshot> fitnessFor(String sport) async {
      if (!multi) return fitness;
      final key = sport.contains('cycl')
          ? 'cycling'
          : sport.contains('swim')
          ? 'swimming'
          : 'running';
      final cached = sportFitness[key];
      if (cached != null) return cached;
      var read = await readFitness(sport);
      // No measured zones for this sport either: the age estimate stands in.
      if (read.hrZones.length < 4 && athlete.estimatedHrZones.isNotEmpty) {
        read = read.withHrZones(athlete.estimatedHrZones);
      }
      return sportFitness[key] = read;
    }

    for (var g = firstIndex; g < weeks; g++) {
      // g counts from the season anchor, w from this plan run.
      final w = g - firstIndex;
      final weekStart = _addDays(anchorWeek, g * 7);
      final weekIntents = multi
          ? timeline.intentsFor(weekStart)
          : const <GoalWeek>[];
      var needs = SeasonTimeline.needsOf(weekIntents);
      if (multi && prependRecovery && w == 0) {
        needs = [
          for (final n in needs)
            SportNeed(
              sport: n.sport,
              weight: n.weight,
              intent: GoalIntent.unload,
              goal: n.goal,
              weeksToEvent: n.weeksToEvent,
              progress: n.progress,
            ),
        ];
      }
      var phase = (prependRecovery && w == 0)
          ? 'recovery'
          : casual
          // No race: base training, with the usual recovery weeks.
          ? (g % athlete.recoveryCycle == athlete.recoveryCycle - 1
                ? 'recovery'
                : 'base')
          : multi
          ? (needs.isEmpty ? 'base' : needs.first.intent.phase)
          : planPhase(g, weeks, cycle: athlete.recoveryCycle);
      final weeksIntoBlock = g % athlete.recoveryCycle;
      final progression = phase == 'taper' || phase == 'recovery'
          ? 1.0
          : 1.0 + athlete.progressionPerWeek * weeksIntoBlock;
      // Volume ramps from what the athlete currently does to the target.
      var weeklyBudgetMin = rampedWeeklyMinutes(
        targetMin: targetWeeklyMin,
        recentMin: history.weeklyMinutes,
        week: w,
        rate: volumeRampRate(
          targetMin: targetWeeklyMin,
          peakMin: history.peakWeeklyMinutes,
          athlete: athlete,
        ),
      );
      if (!multi && (phase == 'recovery' || phase == 'taper')) {
        weeklyBudgetMin *= 0.7;
      }
      final weekTss =
          (baseWeeklyTss *
                  planWeeklyTssFactor(phase, fitness.tier) *
                  progression *
                  (w == 0 ? readiness : 1.0))
              .round();
      final weekTssCap = (weekTss * 1.1).round();

      // Choose slots for the week.
      var slots = phase == 'recovery'
          ? _build.recoveryWeekSlots(mainSport)
          : List<PlanSessionSlot>.of(baseSlots);
      slots = planRestrictSlotsToSports(
        slots,
        allowed: allowedSports,
        mainSport: mainSport,
        strength: strengthDays.isNotEmpty,
      );
      if (phase == 'taper') {
        slots = slots
            .where((s) => s.sessionType != 'long' || s.weekday == 6)
            .toList();
      }
      // A beginner gets one long session a week: the second long slot of the
      // template becomes an easy run.
      if (athlete.isBeginner) {
        var longs = 0;
        for (var i = 0; i < slots.length; i++) {
          if (slots[i].sessionType == 'long' && ++longs > 1) {
            slots[i] = slots[i].copyWith(
              sessionType: 'recovery',
              clearSubType: true,
              zone: 2,
            );
          }
        }
      }
      // Rotate the general-development sport into easy slots.
      if (rotation.length > 1) {
        slots = slots.map((s) {
          if (s.sessionType != 'recovery' || s.sport == 'yoga') return s;
          final alt = rotation[gadIndex++ % rotation.length];
          return s.copyWith(sport: alt);
        }).toList();
      }
      // Hard sessions: capped by experience; athletes who rarely train hard
      // get one moderate (tempo) key session in the first two weeks of the
      // season. Counted from the season, not from this plan run: a replan
      // would otherwise start over, and the easy weeks it plans keep the
      // history easy for the next one.
      final easyStart = history.mostlyEasy && g < 2;
      final easingIn = List.generate(
        7,
        (i) => _addDays(_addDays(anchorWeek, g * 7), i),
      ).any(easeInDays.contains);
      final maxKeys = easingIn
          ? 0
          // For the fun of it: every session easy. To get fitter: one hard
          // session a week, two for an advanced athlete.
          : casualGoal == 'fun' && casual
          ? 0
          : casual
          ? (athlete.isAdvanced ? 2 : 1)
          : easyStart
          ? 1
          : athlete.maxKeySessions;
      // Fewer hard sessions allowed than the week has: they take turns by
      // week, so a beginner's one session is threshold one week and zone 5
      // the next, not the template's first one every week.
      final keySlots = [
        for (var i = 0; i < slots.length; i++)
          if (slots[i].sessionType == 'key' && slots[i].sport != 'strength') i,
      ];
      final keep = maxKeys == null || maxKeys >= keySlots.length
          ? keySlots.toSet()
          : {
              for (var k = 0; k < maxKeys; k++)
                keySlots[(g + k) % keySlots.length],
            };
      for (var i = 0; i < slots.length; i++) {
        final s = slots[i];
        if (s.sessionType != 'key' || s.sport == 'strength') continue;
        if (!keep.contains(i)) {
          slots[i] = s.copyWith(
            sessionType: 'recovery',
            clearSubType: true,
            zone: 2,
          );
        } else {
          if (easyStart) {
            // A hike keeps its hills: its effort comes from climbing.
            slots[i] = s.copyWith(
              subType: s.sport == 'hiking' ? 'hills' : 'tempo',
              zone: math.min(s.zone, 3),
            );
          }
        }
      }
      // A hilly race gets hill work in the build and peak: one tempo session
      // becomes a hill session, every other week on rolling to hilly courses
      // and every week on mountainous ones.
      if ((phase == 'build' || phase == 'peak') &&
          planFootSports.contains(mainSport) &&
          (terrain == Terrain.mountainous ||
              (terrain == Terrain.hilly && g.isEven))) {
        final i = slots.indexWhere(
          (s) =>
              s.sessionType == 'key' &&
              s.subType == 'tempo' &&
              planFootSports.contains(s.sport),
        );
        if (i >= 0) slots[i] = slots[i].copyWith(subType: 'hills', zone: 4);
      }
      // A triathlon keeps the top end too: the bike key session is zone 5
      // intervals every other week, tempo in between. One discipline is
      // enough; swim and run stay at threshold (finding 10 of the review).
      if (mainSport == 'triathlon' &&
          const {'base', 'build', 'peak'}.contains(phase) &&
          g.isOdd) {
        final i = slots.indexWhere(
          (s) => s.sessionType == 'key' && s.sport == 'cycling_road',
        );
        if (i >= 0) {
          slots[i] = slots[i].copyWith(subType: 'intervals', zone: 5);
        }
      }
      // Strength goes on every strength day the athlete chose, aimed at the
      // race: base and build use each day, peak at most two, taper one
      // short session, race weeks none, recovery weeks core and stability.
      // Sessions A and B alternate from day to day and week to week.
      final strengthWeek =
          strengthDays.isNotEmpty &&
          (phase == 'recovery' || slots.any((s) => s.sport == 'strength'));
      slots.removeWhere((s) => s.sport == 'strength');
      if (strengthWeek) {
        final count = switch (phase) {
          'base' || 'build' => math.min(strengthDays.length, 3),
          'peak' => math.min(strengthDays.length, 2),
          'taper' || 'recovery' => 1,
          _ => 0,
        };
        final focus = strengthFocusFor(
          mainSport,
          hilly: terrain == Terrain.hilly || terrain == Terrain.mountainous,
        );
        for (var i = 0; i < count; i++) {
          slots.add(
            planStrengthFull.copyWith(
              subType: phase == 'recovery'
                  ? 'strengthCore'
                  : strengthProgrammeId(focus, phase, g + i),
              weekday: strengthDays[i],
            ),
          );
        }
      }
      // Few hours a week (under three): no more sessions than the week's
      // minutes hold at half an hour each. One hour a week is two sessions
      // of 30 minutes or one of an hour, not five short ones that add up to
      // well over the hour.
      final smallWeek = targetWeeklyMin < 180;
      final maxSessions = math.max(
        1,
        math.min(
          daysPerWeek * maxSessionsPerDay,
          smallWeek ? weeklyBudgetMin ~/ 30 : 1 << 30,
        ),
      );
      // Keep long and key sessions first when trimming.
      int rank(PlanSessionSlot s) => switch (s.sessionType) {
        'long' => 0,
        'key' => s.sport == 'strength' ? 2 : 1,
        _ => 3,
      };
      slots.sort((a, b) => rank(a).compareTo(rank(b)));
      if (slots.length > maxSessions) slots = slots.sublist(0, maxSessions);

      final weekNotes = <String>[];
      var weekBudget = 0.0;
      // What the week really holds, to set against what was allocated: the
      // report describes the sessions that are stored, not the intention.
      WeekAllocation? weekAllocation;
      Map<String, dynamic>? reportAllocation;
      var weekPartial = false;
      final actualRows =
          <({String sport, String type, String? sub, int minutes})>[];
      void dropped(PlanSessionSlot slot, String why) {
        final allocation = weekAllocation;
        if (allocation == null) return;
        final what = (slot.objective ?? '${slot.sport} session').toLowerCase();
        final protectedSession = (slot.rank ?? 9) <= 1;
        final message = '$what was dropped: $why.';
        // A part week cannot fail a long session it never had the days for.
        if (protectedSession && !weekPartial) {
          allocation.unmet.add(message);
        } else if ((slot.rank ?? 9) <= 3) {
          allocation.tradeoffs.add(message);
        }
      }

      if (multi) {
        // The season allocator shares the week between the goals' sports
        // before any day is chosen; the weekly template is not used.
        final events = [
          for (final gw in weekIntents)
            if (gw.intent == GoalIntent.event)
              (
                name: gw.goal.name,
                minutes: gw.goal.demand.planningMinutes.round(),
              ),
        ];
        final eventMinutes = events.fold<int>(0, (a, e) => a + e.minutes);
        // Read from every goal's intent, so a goal that shares its sport with
        // a later one is still recovered from.
        var budget =
            weeklyBudgetMin *
            (prependRecovery && w == 0
                ? 0.7
                : WeekAllocator.budgetFactor(weekIntents));
        budget = math.max(budget * 0.3, budget - eventMinutes);
        // A week already begun, or ending at the last event, has fewer days
        // to train in: its time and its sessions shrink with them.
        var daysLeft = 0;
        for (var off = 0; off < 7; off++) {
          final date = _addDays(weekStart, off);
          if (date.isBefore(today) || date.isAfter(end)) continue;
          if (restDays.contains(date.weekday)) continue;
          if (healthDays.contains(date)) continue;
          if (goalSet.loadOn(date) == DayLoad.blocked) continue;
          daysLeft++;
        }
        final trainingDays = math.max(
          1,
          math.min(daysPerWeek, 7 - restDays.length),
        );
        if (daysLeft < trainingDays) {
          budget *= math.max(1, daysLeft) / trainingDays;
        }
        final sessionCap = math.max(
          1,
          math.min(maxSessions, daysLeft * maxSessionsPerDay),
        );
        final allocation = const WeekAllocator().allocate(
          AllocationInput(
            needs: needs,
            budgetMin: budget,
            sessionCap: sessionCap,
            strengthDays: strengthDays,
            recoveringFromEvent: WeekAllocator.isRecoveringFromLongEvent(
              weekIntents,
            ),
            partialWeek: daysLeft < trainingDays,
            capacities: capacities,
            weekInRun: w,
            weekIndex: g,
            maxKeySessions: easingIn
                ? 0
                : easyStart
                ? 1
                : athlete.maxKeySessions,
            easyStart: easyStart,
            varietySports: varietySports,
            footLongCap: (goal) => maxLongRunMinutes(
              planDistanceCategory(goal.distanceM),
              targetMin: goal.targetSeconds == null
                  ? null
                  : (goal.targetSeconds! / 60).round(),
            ),
            allowedSports: allowedSports,
            events: events,
            goalWeeks: weekIntents,
            cycle: athlete.recoveryCycle,
          ),
        );
        allocations.add(allocation);
        weekAllocation = allocation;
        weekPartial = daysLeft < trainingDays;
        weekBudget = budget;
        slots = [for (final a in allocation.slots) PlanWorkoutBuilder.slotOf(a)]
          ..sort((a, b) => (a.rank ?? 9).compareTo(b.rank ?? 9));
        reportAllocation = allocation.toJson();
        weekReports.add(
          WeekReport(
            weekStart: weekStart,
            phase: phase,
            intents: {for (final gw in weekIntents) gw.goal.id: gw.intent.name},
            allocation: reportAllocation,
            notes: weekNotes,
          ),
        );
      }

      // Assign each slot to a day offset in the week.
      final used = <int, int>{};
      final dayMinutes = <int, int>{};
      final usedSports = <int, Set<String>>{};
      bool isPreRaceRest(DateTime d) => d == _addDays(raceDay, -1);

      int? bestOffset(PlanSessionSlot s) {
        final candidates = <int>[];
        for (var off = 0; off < 7; off++) {
          final date = _addDays(weekStart, off);
          // An event day belongs to the event, not to an ordinary session.
          if (multi) {
            if (date.isAfter(end)) continue;
            final load = goalSet.loadOn(date);
            if (load == DayLoad.blocked) continue;
            if (load == DayLoad.easyOnly && !PlanWorkoutBuilder.easyEnough(s))
              continue;
          } else if (!date.isBefore(raceDay)) {
            continue;
          }
          // Days already gone cannot take a session.
          if (date.isBefore(today)) continue;
          // After an event a day holds only what its recovery allows: no
          // second session on a day that has less than 20 min of it left.
          if (s.sport != 'strength' &&
              goalSet.volumeFactorOn(date) != null &&
              (capOn(date) ?? 999) - (dayMinutes[off] ?? 0) < 20) {
            continue;
          }
          if (restDays.contains(date.weekday)) continue;
          if (healthDays.contains(date)) continue;
          if (!multi && isPreRaceRest(date)) continue;
          final count = used[off] ?? 0;
          if (count >= maxSessionsPerDay) continue;
          if (count > 0 && (usedSports[off]?.contains(s.sport) ?? false)) {
            continue;
          }
          candidates.add(off);
        }
        // The first week back from an illness or injury has no hard or
        // long session.
        if (s.sessionType == 'key' || s.sessionType == 'long') {
          candidates.removeWhere(
            (off) => easeInDays.contains(_addDays(weekStart, off)),
          );
        }
        if (candidates.isEmpty) return null;
        // A day whose training window is too short for the session is used
        // only when no day has room for it.
        final wanted = s.sport == 'strength'
            ? null
            : s.targetMin ?? (s.sessionType == 'long' ? 90 : null);
        if (wanted != null) {
          final fits = [
            for (final off in candidates)
              if ((capOn(_addDays(weekStart, off)) ?? wanted) >= wanted) off,
          ];
          if (fits.isNotEmpty) {
            candidates
              ..clear()
              ..addAll(fits);
          }
        }
        // Strength days are the athlete's own choice in the settings: a
        // strength session takes its day whenever that day is open at all.
        if (s.sport == 'strength' && s.weekday != 0) {
          for (final off in candidates) {
            if (_addDays(weekStart, off).weekday == s.weekday) return off;
          }
        }
        if (s.weekday == 0) {
          // The quietest day: fewest sessions, then fewest minutes.
          candidates.sort((a, b) {
            final byCount = (used[a] ?? 0).compareTo(used[b] ?? 0);
            return byCount != 0
                ? byCount
                : (dayMinutes[a] ?? 0).compareTo(dayMinutes[b] ?? 0);
          });
          return candidates.first;
        }
        int dist(int off) {
          final wd = _addDays(weekStart, off).weekday;
          final d = (wd - s.weekday).abs();
          var cost = math.min(d, 7 - d) * 10 + (used[off] ?? 0);
          // A hard or long day next to a long one, or on top of one, is the
          // last choice: the legs and the week are not asked twice.
          final minutes = s.targetMin;
          if (multi && minutes != null) {
            final demanding = s.sessionType == 'key' || minutes >= 90;
            if (demanding) {
              final day = _addDays(weekStart, off);
              for (final next in [-1, 1]) {
                final neighbour = longDates[_addDays(day, next)] ?? 0;
                if (neighbour >= 150 || (minutes >= 150 && neighbour >= 100)) {
                  cost += 50;
                }
              }
            }
            if ((dayMinutes[off] ?? 0) >= 90 && (demanding || minutes >= 60)) {
              cost += 80;
            }
          }
          // Never a hard session the day before or after another one, in
          // either path (≥ 48 h between them, §3 #5 of the plan review),
          // unless no other day is open. A very long day counts as hard
          // too: hours in zone 2 tire as much as intervals.
          final day = _addDays(weekStart, off);
          bool nextTo(bool Function(DateTime) hard) =>
              hard(_addDays(day, -1)) || hard(_addDays(day, 1));
          final key = s.sessionType == 'key' && s.sport != 'strength';
          // No key session the day before or after another (§3 #5): a
          // zone 3 slot can still get a template with zone 5 in it.
          if (key && nextTo(keyDates.contains)) cost += 100;
          // One quality session a day: a tempo run and trail intervals are
          // two sports but one pair of legs.
          if (key && keyDates.contains(day)) cost += 200;
          // Nor next to a heavy day that, together with it, is too much:
          // minutes × intensity × the sport's impact, so 3 h on a trail
          // weighs and 150 min of easy riding does not (§3 #5).
          final stress = plannedStress(s);
          if (key && heavyNextTo(day, stress)) cost += 100;
          // Nor on a day that is heavy already (the long run's day).
          if (key && (dayStress[day] ?? 0) >= heavyDayStress * 0.9) {
            cost += 100;
          }
          // A heavy session does not go next to a key day the same way.
          if (!key &&
              [-1, 1].any(
                (n) =>
                    keyDates.contains(_addDays(day, n)) &&
                    heavyPair(
                      dayStress[_addDays(day, n)] ?? 0,
                      stress,
                      margin: 0.9,
                    ),
              )) {
            cost += 100;
          }
          return cost;
        }

        candidates.sort((a, b) => dist(a).compareTo(dist(b)));
        return candidates.first;
      }

      var weekPlannedTrimp = 0;
      var weekPlannedMin = 0;
      var weekSessions = 0;

      // What stays of the old plan takes its place: the day is used, the
      // time counts, and the slot it stands for is not planned a second time.
      // A skipped session takes nothing and is not made up for.
      final weekEndExclusive = _addDays(weekStart, 7);
      bool inWeek(DateTime d) =>
          !d.isBefore(weekStart) && d.isBefore(weekEndExclusive);
      // A session the athlete moved to another week still stands for its
      // slot here, in the week it was planned for: that week does not plan
      // it a second time on its old day.
      for (final p in kept) {
        final original = DateTime.tryParse(p.sessionDateOriginal ?? '');
        if (original == null ||
            !inWeek(_day(original)) ||
            inWeek(p.sessionDate)) {
          continue;
        }
        final i = slots.indexWhere(
          (s) => s.sport == p.sport && s.sessionType == p.sessionType,
        );
        if (i >= 0) slots.removeAt(i);
      }
      var unmatchedMin = 0;
      for (final p in kept.where(
        (p) =>
            !p.sessionDate.isBefore(weekStart) &&
            p.sessionDate.isBefore(weekEndExclusive),
      )) {
        final i = slots.indexWhere(
          (s) => s.sport == p.sport && s.sessionType == p.sessionType,
        );
        if (i >= 0) {
          slots.removeAt(i);
        } else if (p.status != 'skipped') {
          unmatchedMin += p.actualDurationMin ?? p.plannedDurationMin;
        }
        if (p.status == 'skipped') continue;
        final off = daysBetween(weekStart, p.sessionDate);
        final minutes = p.actualDurationMin ?? p.plannedDurationMin;
        used[off] = (used[off] ?? 0) + 1;
        usedSports.putIfAbsent(off, () => <String>{}).add(p.sport);
        weekPlannedTrimp += p.plannedTrimp;
        weekPlannedMin += minutes;
        weekSessions++;
        sessionNumber++;
        dayMinutes[off] = (dayMinutes[off] ?? 0) + minutes;
        if (minutes >= 100) longDates[_day(p.sessionDate)] = minutes;
        if (p.sessionType == 'key' && p.sport != 'strength') {
          keyDates.add(_day(p.sessionDate));
        }
        dayStress.update(
          _day(p.sessionDate),
          (v) =>
              v +
              sessionStress(
                sport: p.sport,
                minutes: minutes,
                zone: p.primaryZone,
              ),
          ifAbsent: () => sessionStress(
            sport: p.sport,
            minutes: minutes,
            zone: p.primaryZone,
          ),
        );
        // A moved session that sits on an event, or hard next to one, stays
        // where the athlete put it, and the report says so.
        if (multi && (p.status == 'planned' || p.status == 'adapted')) {
          final load = goalSet.loadOn(p.sessionDate);
          final easy =
              p.sessionType == 'recovery' ||
              (p.plannedDurationMin <= 60 && p.primaryZone <= 2);
          if (load == DayLoad.blocked) {
            weekNotes.add('movedOntoEvent');
          } else if (load == DayLoad.easyOnly && !easy) {
            weekNotes.add('movedHardNearEvent');
          }
        }
      }
      for (final d in doneToday) {
        final off = daysBetween(weekStart, d.day);
        if (off < 0 || off > 6) continue;
        used[off] = (used[off] ?? 0) + 1;
        dayMinutes[off] = (dayMinutes[off] ?? 0) + d.minutes;
        weekPlannedMin += d.minutes;
        unmatchedMin += d.minutes;
      }
      // Time already spent that no slot stands for comes out of what is
      // planned: the least important sessions give way.
      if (multi && unmatchedMin > 0) {
        final room = PlanWorkoutBuilder.makeRoom(
          slots,
          weekBudget - unmatchedMin,
        );
        slots = room.kept;
        for (final d in room.removed) {
          dropped(d, 'time was already spent that week');
        }
      }

      // The ramp test takes the week's first hard session in its sport, or in
      // a recovery week an easy one late in the week: at the end of a
      // recovery week or the start of a block, rested. Never in a taper, a
      // race week or a first week back from illness or injury.
      PlanSessionSlot? rampSlot, rampOriginal;
      final due = nextRamp;
      if (due != null &&
          !_addDays(weekStart, 6).isBefore(due) &&
          !easingIn &&
          (phase == 'recovery' || weeksIntoBlock == 0) &&
          phase != 'taper' &&
          List.generate(7, (i) => _addDays(weekStart, i)).every(
            (d) => multi
                ? goalSet.loadOn(d) == DayLoad.free
                : d.isBefore(_addDays(raceDay, -6)),
          )) {
        // The sport tested longest ago first.
        final families = lastRamp.keys.toList()
          ..sort((a, b) {
            final x = lastRamp[a], y = lastRamp[b];
            if (x == null) return y == null ? 0 : -1;
            return y == null ? 1 : x.compareTo(y);
          });
        var i = -1;
        for (final family in families) {
          i = slots.indexWhere(
            (s) => s.sessionType == 'key' && rampFamilyOf(s.sport) == family,
          );
          if (i >= 0) break;
          for (var j = 0; j < slots.length; j++) {
            final s = slots[j];
            if (s.sessionType == 'recovery' &&
                rampFamilyOf(s.sport) == family &&
                (i < 0 || s.weekday > slots[i].weekday)) {
              i = j;
            }
          }
          if (i >= 0) break;
        }
        if (i >= 0) {
          final old = slots[i];
          rampOriginal = old;
          rampSlot = PlanSessionSlot(
            old.sport == 'trail_running' ? 'running' : old.sport,
            'key',
            rampTestSubType,
            4,
            old.sessionType == 'key' ? old.weekday : 5,
            goalId: old.goalId,
            goalRole: old.goalRole,
            objective: 'Ramp test',
            targetMin: 50,
            rank: old.rank,
            phase: old.phase,
          );
          slots[i] = rampSlot;
          // The test is the week's hard session: the others are easy, so
          // it is run rested and not next to another hard day.
          for (var j = 0; j < slots.length; j++) {
            final s = slots[j];
            if (j != i && s.sessionType == 'key' && s.sport != 'strength') {
              slots[j] = s.copyWith(
                sessionType: 'recovery',
                clearSubType: true,
                zone: 2,
              );
            }
          }
        }
      }

      // A long event raced to finish needs one short zone 5 dose a week, not
      // two: a second zone 5 slot for such a goal becomes threshold work.
      var topSlots = 0;
      for (var i = 0; i < slots.length; i++) {
        final s = slots[i];
        if (s.sessionType != 'key' || s.sport == 'strength' || s.zone < 5) {
          continue;
        }
        if (longFinish(s.goalId) && ++topSlots > 1) {
          slots[i] = s.copyWith(
            subType: s.sport == 'cycling_road' ? 'threshold' : 'tempo',
            zone: 4,
          );
        }
      }
      // Strength first: its days are fixed by the athlete, the rest of the
      // week arranges itself around them. Then the long sessions, so a key
      // session knows which days are heavy and keeps away from them.
      slots = [
        ...slots.where((s) => s.sport == 'strength'),
        ...slots.where((s) => s.sport != 'strength' && s.sessionType == 'long'),
        // Key sessions the hardest first (in a crowded week zone 5 is the
        // rarer one), then by their preferred day, so the second takes a day
        // two apart (Tuesday and Thursday).
        ...slots
            .where((s) => s.sport != 'strength' && s.sessionType == 'key')
            .toList()
          ..sort((a, b) {
            final byZone = b.zone.compareTo(a.zone);
            return byZone != 0 ? byZone : a.weekday.compareTo(b.weekday);
          }),
        ...slots.where(
          (s) =>
              s.sport != 'strength' &&
              s.sessionType != 'long' &&
              s.sessionType != 'key',
        ),
      ];
      for (var slot in slots) {
        final off = bestOffset(slot);
        // A key session that only fits next to a hard or very long day (a
        // race week, or the easy days after an event, leave few open days)
        // is run easy instead (§3 #5).
        if (off != null &&
            slot.sessionType == 'key' &&
            slot.sport != 'strength' &&
            slot.zone >= 3) {
          final day = _addDays(weekStart, off);
          final stress = plannedStress(slot);
          if (keyDates.contains(_addDays(day, -1)) ||
              keyDates.contains(_addDays(day, 1)) ||
              heavyNextTo(day, stress)) {
            slot = slot.copyWith(
              sessionType: 'recovery',
              clearSubType: true,
              zone: 2,
            );
          }
        }
        if (off == null) {
          log(
            '[Plan] w$w ${slot.sport}/${slot.sessionType}'
            '(p$phase,z${slot.zone}) → SKIP rest=$restDays used=$used',
          );
          continue;
        }
        final date = _addDays(weekStart, off);
        if (date.isBefore(today)) continue;
        // The ramp test needs its whole length, known thresholds and its
        // due date; otherwise the session it replaced is planned after all.
        final sportFit = await fitnessFor(slot.sport);
        final rampLt2 =
            sportFit.lt2Bpm ??
            sportFit.hrRangeForZone(5).low ??
            sportFit.hrRangeForZone(4).high;
        // A few days early is fine; a week early is not.
        if (identical(slot, rampSlot) &&
            (rampLt2 == null ||
                (capOn(date) ?? 999) < 50 ||
                date.isBefore(_addDays(due!, -3)))) {
          slot = rampOriginal!;
        }
        final ramp = identical(slot, rampSlot);
        // A long session that could not take its usual day is said, not
        // hidden: the athlete's rest days and the other sessions decided it.
        if (multi &&
            slot.sessionType == 'long' &&
            (slot.targetMin ?? 0) >= 150 &&
            slot.weekday != 0) {
          final apart = (date.weekday - slot.weekday).abs();
          if (math.min(apart, 7 - apart) >= 2) {
            weekNotes.add('longAwayFromUsualDay');
          }
        }

        // A slot from the season allocator already has the length its goal
        // and the athlete's history support; the rules below size the slots
        // of a weekly template.
        var duration =
            slot.targetMin ??
            _build.ctlScaledDuration(
              PlanWorkoutBuilder.baseDuration(slot.sessionType),
              slot.sessionType,
              fitness.tier,
              fitness.ctl,
            );
        // The longest long session the athlete's history supports, if any.
        int? historyLongCap;
        if (slot.targetMin == null) {
          if (phase == 'taper') duration = (duration * 0.7).round();
          if (phase == 'recovery') duration = (duration * 0.7).round();
          if (slot.sessionType == 'long' &&
              planFootSports.contains(slot.sport)) {
            duration = math.min(duration, longRunCap);
          }
          if (slot.sessionType == 'long' && phase == 'peak') {
            duration = (duration * 1.4).round();
            if (planFootSports.contains(slot.sport)) {
              duration = math.min(duration, longRunCap);
            }
          }
          final sportHistory = history.forSport(slot.sport);
          if (sportHistory != null && sportHistory.longestMin >= 20) {
            if (slot.sessionType == 'long') {
              // At most ~12% above the longest recent session, growing 5% per
              // week (8% back towards last year's longest).
              final growth = sportHistory.hasYearCapacity ? 0.08 : 0.05;
              var cap = sportHistory.longestMin * (1.12 + growth * w);
              if (sportHistory.hasYearCapacity) {
                cap = math.min(
                  cap,
                  math.max(
                    sportHistory.yearLongestMin,
                    sportHistory.longestMin * 1.12,
                  ),
                );
              }
              historyLongCap = cap.round();
              duration = math.min(duration, historyLongCap);
            } else if (slot.sessionType == 'recovery') {
              // Easy sessions sized like the athlete's usual sessions.
              duration = duration
                  .clamp(
                    (sportHistory.medianMin * 0.6).round(),
                    math.max(20, sportHistory.medianMin.round()),
                  )
                  .toInt();
            }
          }
          if (weekPlannedMin + duration > weeklyBudgetMin &&
              slot.sessionType != 'long') {
            duration = math.max(20, (weeklyBudgetMin - weekPlannedMin).round());
          }
        }
        duration = duration.clamp(slot.minMin ?? 20, slot.maxMin ?? 240);
        // A small week: every session, the long one too, gets its share of
        // the week's minutes and at least half an hour.
        final smallWeekShare = smallWeek
            ? math.max(30, weeklyBudgetMin / slots.length).round()
            : null;
        if (smallWeekShare != null) {
          duration = math.min(duration, smallWeekShare);
        }
        // No longer than the day's training window or a first week back,
        // and after an event no more than its recovery allows that day, all
        // sessions of the day together.
        var dayCap = capOn(date);
        if (dayCap != null && goalSet.volumeFactorOn(date) != null) {
          dayCap -= dayMinutes[off] ?? 0;
        }
        if (dayCap != null && duration > dayCap) {
          duration = math.max(20, dayCap);
        }

        // The workout is chosen first and its steps decide the duration, so
        // what the app shows, what the load estimate counts and what the watch
        // executes are the same. A steady session is fitted to the wanted
        // length; a structured one is chosen close to it and left whole.
        final slotPhase = slot.phase ?? phase;
        // Zones and thresholds are the sport's own, not the main sport's.
        final fit = await fitnessFor(slot.sport);
        var template = _build.pickTemplateFromCache(
          templates,
          slot.sport,
          slot.sessionType,
          slot.subType,
          slotPhase,
          duration,
          w + sessionNumber,
          // Endurance quality only: a strength session keeps its programme.
          minZone:
              slot.sessionType == 'key' &&
                  slot.sport != 'strength' &&
                  slot.zone >= 3
              ? math.min(slot.zone, slot.maxZone ?? 5)
              : null,
          maxZone5Min:
              slot.sessionType == 'key' &&
                  slot.sport != 'strength' &&
                  slot.zone >= 5
              ? (longFinish(slot.goalId) ? 25 : 40)
              : null,
          // The triathlon's bike alternates threshold and zone 5 also in base.
          baseIntervals: mainSport == 'triathlon',
        );
        String? stepsJson;
        var scaled = false;
        var semantics = const WorkoutSemantics();
        void compileSteps(String raw, int wantedMin) {
          final resolved = _build.resolveStepsJson(
            raw,
            ftp,
            fit,
            power: _usesPower(slot.sport, false),
          );
          final fitted = fitSteadyWorkout(resolved, wantedMin * 60.0);
          stepsJson = fitted.stepsJson;
          scaled = fitted.scaled;
          semantics = WorkoutSemantics.of(stepsJson, sport: slot.sport);
        }

        void compile(WorkoutTemplateView t, int wantedMin) =>
            compileSteps(t.stepsJson, wantedMin);

        if (template != null) compile(template, duration);
        if (ramp) {
          final lt2 = rampLt2!;
          final lt1 = fit.lt1Bpm ?? fit.hrRangeForZone(2).high ?? (lt2 - 30);
          int zoneOf(int hr) {
            for (var z = 5; z >= 1; z--) {
              final low = fit.hrRangeForZone(z).low;
              if (low != null && hr >= low) return z;
            }
            return hr >= lt2 ? 5 : (hr >= lt1 ? 3 : 2);
          }

          final usesPower = _usesPower(slot.sport, false) && ftp != null;
          template = null;
          stepsJson = _build.resolveStepsJson(
            jsonEncode(
              rampTestSteps(
                lt1: lt1,
                lt2: lt2,
                zoneOf: zoneOf,
                power: usesPower,
              ),
            ),
            ftp,
            fit,
            power: usesPower,
          );
          scaled = false;
          semantics = WorkoutSemantics.of(stepsJson, sport: slot.sport);
          nextRamp = _addDays(date, rampTestEvery.inDays);
          lastRamp[rampFamilyOf(slot.sport)!] = date;
        }
        // No template is as long as a long session the allocator asked for:
        // a steady one is built, so the plan never shows a length the steps
        // do not run.
        var synthetic = false;
        var steadyLead = 'Long endurance';
        final steady =
            slot.sessionType == 'recovery' ||
            (slot.sessionType == 'long' && slot.subType == 'endurance');
        // An easy session is asked for in its zone; a recovery template is
        // zone 1, so an easy endurance session gets a steady workout instead.
        final wrongZone =
            slot.sessionType == 'recovery' &&
            semantics.dominantZone != null &&
            semantics.dominantZone != slot.zone;
        if (slot.targetMin != null &&
            steady &&
            (template == null ||
                wrongZone ||
                (template.estimatedDurationMin - duration).abs() >
                    duration * (slot.sessionType == 'long' ? 0.3 : 0.25))) {
          compileSteps(
            PlanWorkoutBuilder.steadySteps(duration, slot.zone),
            duration,
          );
          template = null;
          synthetic = true;
        }
        // A hard session that would take the week over its load cap is
        // replaced by a lighter one of the same kind, not clipped on paper.
        if (template != null &&
            slot.sessionType == 'key' &&
            slotPhase != 'peak' &&
            weekPlannedTrimp + semantics.legacyLoad > weekTssCap) {
          final lighter = _build.pickTemplateFromCache(
            templates,
            slot.sport,
            slot.sessionType,
            slot.subType,
            slotPhase,
            (duration * 0.75).round(),
            w + sessionNumber,
          );
          if (lighter != null && lighter.id != template.id) {
            final before = semantics.legacyLoad;
            final previous = (template, stepsJson, scaled, semantics);
            compile(lighter, (duration * 0.75).round());
            if (semantics.legacyLoad < before) {
              template = lighter;
            } else {
              template = previous.$1;
              stepsJson = previous.$2;
              scaled = previous.$3;
              semantics = previous.$4;
            }
          }
        }
        // An athlete who rarely trains hard gets steady work, not intervals:
        // the finished steps are held to the zone limit, whatever the
        // template asked for.
        final limit = slot.maxZone;
        if (limit != null &&
            template != null &&
            semantics.mainZoneSeconds.entries.any(
              (e) => e.key > limit && e.value > 0,
            )) {
          compileSteps(
            PlanWorkoutBuilder.steadySteps(duration, limit),
            duration,
          );
          template = null;
          synthetic = true;
          steadyLead = 'Steady';
        }
        // Nor longer than an event's recovery allows that day: then a steady
        // session of the allowed length.
        if (dayCap != null &&
            goalSet.volumeFactorOn(date) != null &&
            semantics.totalMinutes > math.max(20, dayCap)) {
          compileSteps(
            PlanWorkoutBuilder.steadySteps(
              math.max(20, dayCap),
              math.min(slot.zone, 2),
            ),
            math.max(20, dayCap),
          );
          template = null;
          synthetic = true;
        }
        // A structured long session is left whole, but never longer than the
        // athlete's history allows: then a steady one of the allowed length.
        if (historyLongCap != null &&
            template != null &&
            semantics.totalMinutes > historyLongCap) {
          compileSteps(
            PlanWorkoutBuilder.steadySteps(duration, slot.zone),
            duration,
          );
          template = null;
          synthetic = true;
        }
        // The hours the athlete gave are a limit, not a hope: a workout whose
        // steps run longer than the week has left is made shorter, or left
        // out, and the report says which.
        if (multi && !ramp && slot.targetMin != null && weekBudget > 0) {
          final actual = semantics.isEmpty
              ? duration
              : semantics.totalMinutes.clamp(
                  1,
                  WeekAllocator.longestSessionMin,
                );
          final room = (weekBudget - weekPlannedMin).floor();
          if (actual > room) {
            final minimum = slot.minMin ?? 20;
            if (slot.sport != 'strength' && room >= minimum) {
              final zone = math.min(slot.zone, slot.maxZone ?? 4);
              compileSteps(PlanWorkoutBuilder.steadySteps(room, zone), room);
              template = null;
              synthetic = true;
              steadyLead = slot.sessionType == 'key'
                  ? (zone >= 4 ? 'Tempo' : 'Steady')
                  : 'Long endurance';
              duration = room;
            } else if (slot.sport == 'strength' && room >= minimum) {
              // A shorter strength workout, or none.
              final shorter = _build.pickTemplateFromCache(
                templates,
                slot.sport,
                slot.sessionType,
                slot.subType,
                slotPhase,
                room,
                w + sessionNumber,
              );
              if (shorter != null) compile(shorter, room);
              final after = semantics.isEmpty
                  ? room
                  : semantics.totalMinutes.clamp(
                      1,
                      WeekAllocator.longestSessionMin,
                    );
              if (shorter == null || after > room) {
                weekNotes.add('noRoom');
                dropped(slot, 'its workout ran longer than the time left');
                continue;
              }
              template = shorter;
            } else {
              weekNotes.add('noRoom');
              dropped(slot, 'its workout ran longer than the time left');
              continue;
            }
          }
        }
        // The share of a small week holds also when the chosen workout's
        // steps run longer: then a steady session of that length.
        if (smallWeekShare != null &&
            !ramp &&
            slot.sport != 'strength' &&
            semantics.totalMinutes > smallWeekShare) {
          compileSteps(
            PlanWorkoutBuilder.steadySteps(smallWeekShare, slot.zone),
            smallWeekShare,
          );
          template = null;
          synthetic = true;
          duration = smallWeekShare;
        }
        var title =
            template?.name ??
            '${slot.sessionType[0].toUpperCase()}${slot.sessionType.substring(1)} '
                '${slot.sport.replaceAll('_', ' ')}';
        var trimp = 0.0;
        if (semantics.isEmpty) {
          trimp = duration * planZoneWeights[(slot.zone - 1).clamp(0, 4)];
        } else {
          duration = semantics.totalMinutes.clamp(
            1,
            WeekAllocator.longestSessionMin,
          );
          trimp = semantics.legacyLoad;
          if (scaled) title = retimeTitle(title, duration);
        }
        if (ramp) title = rampTestTitle;
        if (synthetic) {
          title = PlanWorkoutBuilder.steadyTitle(
            slot.sport,
            duration,
            lead: slot.sessionType == 'recovery' ? 'Easy' : steadyLead,
          );
        }

        // A quality session is stored with the zone it works at; an easy one
        // with the zone it mostly is.
        var zone =
            (slot.sessionType == 'key' && slot.sport != 'strength'
                ? semantics.topZone
                : semantics.dominantZone) ??
            slot.zone;
        // An easy run is run in the lower half of zone 2, not in zone 1.
        final easyRun = fit.easyRunZ2 && zone == 1;
        if (easyRun) zone = 2;
        final hr = easyRun ? fit.easyRunRange() : fit.hrRangeForZone(zone);
        final hrJson = jsonEncode({
          'low': hr.low,
          'high': hr.high,
          'zone': zone,
          'lt2': fit.lt2Bpm,
          'lt1': fit.lt1Bpm,
        });

        String? paceJson;
        // Measured threshold pace first; without one, the goal pace gives an
        // estimate (and says so).
        final measuredPace = thresholdPaceMps;
        final paceProfile = PlanWorkoutBuilder.paceProfile(
          goalSet,
          slot,
          raceProfile,
          multi,
        );
        final pace = measuredPace ?? paceProfile?.estimatedThresholdSpeedMps;
        if ((slot.sport == 'running' || slot.sport == 'trail_running') &&
            pace != null &&
            pace > 0) {
          final z = planPaceZones[zone.clamp(1, 5)]!;
          paceJson = jsonEncode({
            'low_sec_per_km': (1000 / (pace * z.hi)).round(),
            'high_sec_per_km': (1000 / (pace * z.lo)).round(),
            'zone': zone,
            'basis': measuredPace != null ? 'threshold' : 'goal',
            if (paceProfile?.flatEquivalentPaceSecPerKm != null)
              'goal_sec_per_km': paceProfile!.flatEquivalentPaceSecPerKm!
                  .round(),
          });
        }
        String? powerJson;
        if (slot.sport.contains('cycl') && ftp != null) {
          final z = planPowerZones[zone.clamp(1, 5)]!;
          powerJson = jsonEncode({
            'low_watts': (ftp * z.lo).round(),
            'high_watts': (ftp * z.hi).round(),
            'zone': zone,
            'ftp': ftp,
          });
        }

        final warm = stepsJson == null
            ? (text: null, minutes: null)
            : _build.extractWarmUpDescription(stepsJson!);

        sessionNumber++;
        weekSessions++;
        weekPlannedTrimp += trimp.round();
        weekPlannedMin += duration;
        actualRows.add((
          sport: slot.sport,
          type: slot.sessionType,
          sub: slot.subType,
          minutes: duration,
        ));
        used[off] = (used[off] ?? 0) + 1;
        usedSports.putIfAbsent(off, () => <String>{}).add(slot.sport);
        dayMinutes[off] = (dayMinutes[off] ?? 0) + duration;
        if (duration >= 100) longDates[date] = duration;
        final stress = sessionStress(
          sport: slot.sport,
          minutes: duration,
          zone: zone,
        );
        dayStress.update(date, (v) => v + stress, ifAbsent: () => stress);
        if (slot.sessionType == 'key' && slot.sport != 'strength') {
          keyDates.add(date);
        }

        writes.add(
          GeneratedPlanSession(
            sessionDate: date,
            sessionNumber: sessionNumber,
            weekNumber: g + 1,
            sport: slot.sport,
            sessionType: slot.sessionType,
            // A strength session names the template it was made from, so
            // its type, title and exercises always agree.
            subType: slot.sport == 'strength'
                ? template?.subType ?? slot.subType
                : slot.subType,
            phase: slotPhase,
            primaryZone: zone,
            title: title,
            sessionNotes: ramp ? rampTestDescription : template?.description,
            mainSet: ramp ? rampTestCues : template?.coachingCues,
            warmUp: warm.text,
            warmUpDurationMin: warm.minutes,
            stepsJson: stepsJson,
            hrRangesJson: hrJson,
            paceRangesJson: paceJson,
            powerRangesJson: powerJson,
            plannedDurationMin: duration,
            plannedTrimp: trimp.round(),
            sessionLevel: PlanWorkoutBuilder.sessionLevel(
              slot.sessionType,
              zone,
              slotPhase,
            ),
            goalId:
                slot.goalId ?? (slot.sport == 'strength' ? null : raceGoalId),
            goalRole:
                slot.goalRole ??
                (slot.sport == 'strength' ? 'support' : 'primary'),
            goalObjective: slot.objective,
          ),
        );
      }

      if (multi && weekAllocation != null && reportAllocation != null) {
        reportAllocation
          ..clear()
          ..addAll(weekAllocation.toJsonActual(actualRows));
      }

      final weekStartMonday = weekStart.subtract(
        Duration(days: weekStart.weekday - 1),
      );
      writes.add(
        GeneratedWeekSummary(
          weekStart: weekStartMonday,
          weekNumber: g + 1,
          weekNumberOnUpdate: w + 1,
          phase: phase,
          plannedTrimp: weekPlannedTrimp,
          sessionsPlanned: weekSessions,
          ctl: fitness.ctl,
          tsb: fitness.tsb,
        ),
      );
    }

    // What the season decided, kept with the plan so the screens and the
    // coach can say why it looks as it does.
    final report = SeasonReport.build(
      goals: goalSet,
      weeks: weekReports,
      allocations: allocations,
      capacities: capacities,
      weeksPrepared: allocations.length,
    );
    return PlanGeneration(
      writes: writes,
      report: report,
      sessionNumber: sessionNumber,
    );
  }
}
