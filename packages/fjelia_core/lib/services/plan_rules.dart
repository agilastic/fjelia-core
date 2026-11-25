/// Planning rules: sports, week templates, phases, tiers, volume ramps
/// and the athlete snapshot the plan generator works from.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../models/plan_views.dart';
import 'season/season_timeline.dart';

/// Every sport the planner can schedule.
const planSupportedSports = {
  'running',
  'trail_running',
  'cycling_road',
  'cycling_gravel',
  'cycling_mtb',
  'swimming',
  'triathlon',
  'indoor_rowing',
  'hiking',
  'inline_skating',
  'nordic_skiing',
  'skate_skiing',
};

/// Sports whose fitness is judged by running-style HR/pace metrics.
const planFootSports = {
  'running',
  'trail_running',
  'hiking',
  'inline_skating',
  'nordic_skiing',
  'skate_skiing',
};

const planPhaseOrder = ['base', 'build', 'peak', 'taper', 'race', 'recovery'];

/// Garmin step type → index used for ordering / zone defaults.
const planStepTypeIndex = {
  'warmup': 0,
  'rest': 1,
  'interval': 2,
  'active': 2,
  'recovery': 3,
  'cooldown': 4,
};

/// Power zones as a fraction of FTP.
const planPowerZones = <int, ({double lo, double hi})>{
  1: (lo: 0.45, hi: 0.55),
  2: (lo: 0.56, hi: 0.75),
  3: (lo: 0.76, hi: 0.9),
  4: (lo: 0.91, hi: 1.05),
  5: (lo: 1.06, hi: 1.2),
};

/// Run pace zones as a fraction of threshold speed.
const planPaceZones = <int, ({double lo, double hi})>{
  1: (lo: 0.6, hi: 0.75),
  2: (lo: 0.76, hi: 0.82),
  3: (lo: 0.83, hi: 0.88),
  4: (lo: 0.89, hi: 0.94),
  5: (lo: 0.95, hi: 1.05),
};

const planZoneWeights = [1.0, 1.1, 1.2, 3.1, 8.0];

class PlanSessionSlot {
  const PlanSessionSlot(
    this.sport,
    this.sessionType,
    this.subType,
    this.zone,
    this.weekday, {
    this.goalId,
    this.goalRole,
    this.objective,
    this.targetMin,
    this.minMin,
    this.maxMin,
    this.rank,
    this.phase,
    this.maxZone,
  });

  /// Set when the season allocator made the slot: the goal it prepares for,
  /// how, why, how long, and the phase its workout is chosen for. Slots of the
  /// weekly templates carry none of it.
  final String? goalId, goalRole, objective, phase;
  final int? targetMin, minMin, maxMin, rank;

  /// The highest zone the finished workout may reach; null for no limit.
  final int? maxZone;

  final String sport;
  final String sessionType;
  final String? subType;
  final int zone;

  /// Preferred ISO weekday (1 = Monday); 0 means any day.
  final int weekday;

  PlanSessionSlot copyWith({
    String? sport,
    int? weekday,
    String? sessionType,
    String? subType,
    bool clearSubType = false,
    int? zone,
  }) => PlanSessionSlot(
    sport ?? this.sport,
    sessionType ?? this.sessionType,
    clearSubType ? null : subType ?? this.subType,
    zone ?? this.zone,
    weekday ?? this.weekday,
    goalId: goalId,
    goalRole: goalRole,
    objective: objective,
    targetMin: targetMin,
    minMin: minMin,
    maxMin: maxMin,
    rank: rank,
    phase: phase,
    maxZone: maxZone,
  );
}

const planStrengthFull = PlanSessionSlot(
  'strength',
  'key',
  'strengthFull',
  3,
  0,
);
const planStrengthLower = PlanSessionSlot(
  'strength',
  'key',
  'strengthLower',
  3,
  0,
);
const planStrengthCore = PlanSessionSlot(
  'strength',
  'key',
  'strengthCore',
  3,
  0,
);
const planYoga = PlanSessionSlot('yoga', 'recovery', null, 1, 5);

/// Default week per sport: (sport, type, subType, zone, weekday).
const planWeekTemplates = <String, List<PlanSessionSlot>>{
  'running': [
    PlanSessionSlot('running', 'long', 'endurance', 2, 6),
    PlanSessionSlot('running', 'key', 'intervals', 5, 4),
    PlanSessionSlot('running', 'key', 'tempo', 4, 3),
    planStrengthFull,
    PlanSessionSlot('running', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('running', 'long', 'endurance', 2, 7),
  ],
  'trail_running': [
    PlanSessionSlot('trail_running', 'long', 'endurance', 2, 6),
    PlanSessionSlot('trail_running', 'key', 'hills', 4, 3),
    PlanSessionSlot('running', 'key', 'tempo', 3, 4),
    planStrengthLower,
    PlanSessionSlot('trail_running', 'recovery', null, 1, 2),
    PlanSessionSlot('trail_running', 'key', 'intervals', 5, 1),
    planYoga,
  ],
  'cycling_road': [
    PlanSessionSlot('cycling_road', 'long', 'endurance', 2, 6),
    PlanSessionSlot('cycling_road', 'key', 'intervals', 5, 4),
    PlanSessionSlot('cycling_road', 'key', 'tempo', 4, 3),
    planStrengthFull,
    PlanSessionSlot('cycling_road', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('cycling_road', 'long', 'endurance', 2, 7),
  ],
  'cycling_gravel': [
    PlanSessionSlot('cycling_gravel', 'long', 'endurance', 2, 6),
    PlanSessionSlot('cycling_road', 'key', 'intervals', 5, 4),
    PlanSessionSlot('cycling_road', 'key', 'tempo', 4, 3),
    planStrengthFull,
    PlanSessionSlot('cycling_gravel', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('cycling_gravel', 'long', 'endurance', 2, 7),
  ],
  'cycling_mtb': [
    PlanSessionSlot('cycling_mtb', 'long', 'endurance', 2, 6),
    PlanSessionSlot('cycling_mtb', 'key', 'intervals', 5, 3),
    PlanSessionSlot('cycling_road', 'key', 'tempo', 4, 4),
    planStrengthLower,
    PlanSessionSlot('cycling_mtb', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('cycling_mtb', 'long', 'endurance', 2, 7),
  ],
  'swimming': [
    PlanSessionSlot('swimming', 'long', 'poolSwim', 2, 6),
    PlanSessionSlot('swimming', 'key', 'poolSwim', 4, 4),
    PlanSessionSlot('swimming', 'key', 'poolSwim', 4, 3),
    planStrengthFull,
    PlanSessionSlot('swimming', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('swimming', 'long', 'poolSwim', 2, 7),
  ],
  'triathlon': [
    PlanSessionSlot('running', 'long', 'endurance', 2, 6),
    PlanSessionSlot('cycling_road', 'long', 'endurance', 2, 7),
    PlanSessionSlot('swimming', 'key', 'poolSwim', 4, 2),
    // The bike before the run: with two hard sessions allowed the bike keeps
    // its quality (and its zone 5 every other week), the run its long run.
    PlanSessionSlot('cycling_road', 'key', 'tempo', 4, 4),
    PlanSessionSlot('running', 'key', 'tempo', 4, 3),
    planStrengthCore,
  ],
  'indoor_rowing': [
    PlanSessionSlot('indoor_rowing', 'long', 'endurance', 2, 6),
    PlanSessionSlot('indoor_rowing', 'key', 'intervals', 5, 4),
    PlanSessionSlot('indoor_rowing', 'key', 'intervals', 4, 3),
    planStrengthFull,
    PlanSessionSlot('indoor_rowing', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('indoor_rowing', 'long', 'endurance', 2, 7),
  ],
  'hiking': [
    PlanSessionSlot('hiking', 'long', 'endurance', 2, 6),
    PlanSessionSlot('hiking', 'key', 'hills', 4, 3),
    PlanSessionSlot('hiking', 'recovery', null, 1, 2),
    planStrengthLower,
    planYoga,
    PlanSessionSlot('hiking', 'long', 'endurance', 2, 7),
  ],
  'inline_skating': [
    PlanSessionSlot('inline_skating', 'long', 'endurance', 2, 6),
    PlanSessionSlot('inline_skating', 'key', 'intervals', 5, 4),
    PlanSessionSlot('inline_skating', 'key', 'tempo', 3, 3),
    planStrengthFull,
    PlanSessionSlot('inline_skating', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('inline_skating', 'long', 'endurance', 2, 7),
  ],
  'nordic_skiing': [
    PlanSessionSlot('nordic_skiing', 'long', 'endurance', 2, 6),
    PlanSessionSlot('nordic_skiing', 'key', 'intervals', 5, 4),
    PlanSessionSlot('nordic_skiing', 'key', 'tempo', 3, 3),
    planStrengthFull,
    PlanSessionSlot('nordic_skiing', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('nordic_skiing', 'long', 'endurance', 2, 7),
  ],
  'skate_skiing': [
    PlanSessionSlot('skate_skiing', 'long', 'endurance', 2, 6),
    PlanSessionSlot('skate_skiing', 'key', 'intervals', 5, 4),
    PlanSessionSlot('skate_skiing', 'key', 'tempo', 3, 3),
    planStrengthFull,
    PlanSessionSlot('skate_skiing', 'recovery', null, 1, 2),
    planYoga,
    PlanSessionSlot('skate_skiing', 'long', 'endurance', 2, 7),
  ],
};

/// Sports that may appear in a plan: the ones the athlete chose plus the race
/// sport. A triathlon brings running, cycling and swimming with it.
Set<String> allowedPlanSports({
  required String mainSport,
  required List<String> chosen,
}) {
  final allowed = {mainSport, ...chosen};
  if (allowed.contains('triathlon')) {
    allowed.addAll(const ['running', 'cycling_road', 'swimming']);
  }
  return allowed;
}

/// Keeps a week's slots to the sports the athlete asked for. A slot of another
/// endurance sport (a road ride in a gravel week) becomes [mainSport]; yoga,
/// pilates and stretching are dropped unless chosen. Strength is planned only
/// with strength days, which are the athlete's own setting for it.
List<PlanSessionSlot> planRestrictSlotsToSports(
  List<PlanSessionSlot> slots, {
  required Set<String> allowed,
  required String mainSport,
  required bool strength,
}) {
  const optional = {'yoga', 'pilates', 'stretching'};
  final out = <PlanSessionSlot>[];
  for (final s in slots) {
    if (s.sport == 'strength') {
      if (strength || allowed.contains('strength')) out.add(s);
    } else if (allowed.contains(s.sport)) {
      out.add(s);
    } else if (optional.contains(s.sport)) {
      continue;
    } else {
      out.add(s.copyWith(sport: mainSport));
    }
  }
  return out;
}

/// Sports used for general athletic development; running-type sports first.
List<String> planGadSportRotation(List<String> sports) {
  final valid = sports.where(planSupportedSports.contains).toList();
  if (valid.isEmpty) return ['running'];
  final foot = valid.where(planFootSports.contains).toList();
  final other = valid.where((s) => !planFootSports.contains(s)).toList();
  return [...foot, ...other];
}

double planWeeklyTssFactor(String phase, String tier) {
  final phaseF = switch (phase) {
    'base' => 0.9,
    'build' => 1.1,
    'peak' => 1.15,
    'taper' => 0.6,
    'recovery' => 0.5,
    'race' => 0.4,
    _ => 0.9,
  };
  final easy = phase == 'taper' || phase == 'recovery' || phase == 'race';
  final tierF = easy
      ? 1.0
      : switch (tier) {
          'beginner' => 0.85,
          'advanced' => 1.05,
          _ => 1.0,
        };
  return (phaseF * tierF).clamp(0.5, 1.25);
}

/// Periodisation, see [seasonPhase].
String planPhase(int week, int totalWeeks, {int cycle = 4}) =>
    seasonPhase(week, totalWeeks, cycle: cycle);

/// A plan without a race is built this many days ahead, and again when it
/// runs short.
const casualHorizonDays = 29;

/// The first session of an athlete with no training history.
const firstCasualMinutes = 25;

String planTierFor(double ctl) => ctl < 35
    ? 'beginner'
    : ctl >= 50
    ? 'advanced'
    : 'intermediate';

String planDistanceCategory(double? meters) {
  if (meters == null || meters <= 0) return 'general';
  if (meters < 5000) return 'sprint';
  if (meters < 8000) return '5k';
  if (meters < 16000) return '10k';
  if (meters < 30000) return 'half';
  if (meters < 55000) return 'marathon';
  return 'ultra';
}

/// The longest long run for a race of [category]. With a target time the cap
/// follows it: about 85 % of the race time, but no less than 70 % and no more
/// than 120 % of the category's cap, so a slow marathon is not capped as for a
/// fast one and a six-hour ultra is not capped as for a four-hour one.
int maxLongRunMinutes(String category, {int? targetMin}) {
  final base = planMaxLongRunMin(category);
  if (targetMin == null || targetMin <= 0) return base;
  return (targetMin * 0.85).round().clamp(
    (base * 0.7).round(),
    (base * 1.2).round(),
  );
}

int planMaxLongRunMin(String category) => switch (category) {
  'sprint' => 45,
  '5k' => 60,
  '10k' => 90,
  'half' => 120,
  'marathon' => 180,
  'ultra' => 600,
  _ => 180,
};

/// The zone a share of FTP belongs to (Coggan: up to 55 %, 75 %, 90 %, 105 %,
/// above). Used for templates written as a share of FTP, which carry no zone.
int zoneForFtpFraction(double fraction) {
  if (fraction <= 0.55) return 1;
  if (fraction <= 0.75) return 2;
  if (fraction <= 0.90) return 3;
  if (fraction <= 1.05) return 4;
  return 5;
}

/// Athlete attributes from the user profile that shape the plan.
class PlanAthleteProfile {
  const PlanAthleteProfile({
    this.experienceLevel = 'intermediate',
    this.sex,
    this.age,
    this.levelFromData = false,
  });

  /// beginner | intermediate | advanced. The athlete's own answer only
  /// counts while there is too little training history; with enough, the
  /// level is derived from the data ([withDataLevel]).
  final String experienceLevel;

  /// [experienceLevel] was derived from the training data, not self-reported.
  final bool levelFromData;

  /// The level the plan uses, from the self-reported one and the data
  /// (step 3 of docs/training-plan-rethink.md). Load and fitness say what
  /// the athlete can do, not how used they are to structured hard training:
  /// a beginner with a good 10 km pace is still a beginner.
  /// - The data can lower the level ([tier] from CTL, once [enoughData]).
  /// - It raises it only one step at a time and only with proven training
  ///   experience: [activeWeeks] of the last year (26 for intermediate, 40
  ///   for advanced) and real intensity in the last 12 weeks, not
  ///   [mostlyEasy]. Missing experience never counts as experience.
  PlanAthleteProfile withDataLevel({
    required String tier,
    required bool enoughData,
    int activeWeeks = 0,
    bool mostlyEasy = true,
  }) {
    if (!enoughData) return this;
    const order = ['beginner', 'intermediate', 'advanced'];
    final own = order.indexOf(experienceLevel).clamp(0, 2);
    final data = order.indexOf(tier).clamp(0, 2);
    var level = own;
    if (data < own) {
      level = data;
    } else if (data > own && !mostlyEasy) {
      final next = own + 1;
      if (activeWeeks >= (next == 1 ? 26 : 40)) level = next;
    }
    if (level == own) return this;
    return PlanAthleteProfile(
      experienceLevel: order[level],
      sex: sex,
      age: age,
      levelFromData: true,
    );
  }

  /// 'm', 'f' or other; only used for the max-HR estimate.
  final String? sex;
  final int? age;

  bool get isBeginner => experienceLevel == 'beginner';
  bool get isAdvanced => experienceLevel == 'advanced';

  /// Hard (key) sessions per week; null keeps the week template's count.
  int? get maxKeySessions => isBeginner
      ? 1
      : isAdvanced
      ? 2
      : null;

  /// Load increase per week within a block.
  double get progressionPerWeek => isBeginner
      ? 0.04
      : isAdvanced
      ? 0.07
      : 0.06;

  /// Weekly volume ramp from current training towards the target hours.
  double get volumeRampPerWeek => isBeginner ? 0.08 : 0.10;

  /// Every n-th week of base/build is a recovery week.
  int get recoveryCycle => isBeginner || (age ?? 0) >= 50 ? 3 : 4;

  /// Tanaka (208 − 0.7·age), Gulati for women (206 − 0.88·age).
  int? get maxHrEstimate {
    final a = age;
    if (a == null || a <= 0) return null;
    return sex == 'f' ? (206 - 0.88 * a).round() : (208 - 0.7 * a).round();
  }

  /// Upper bounds of HR zones 1–4 from the estimated max HR.
  List<int> get estimatedHrZones {
    final max = maxHrEstimate;
    if (max == null) return const [];
    return [
      for (final f in const [0.68, 0.78, 0.86, 0.93]) (max * f).round(),
    ];
  }
}

/// Planner sport for an activity type, or null when it has no equivalent.
String? planPlannerSport(String type) {
  final t = type.toLowerCase();
  if (t.contains('trail')) return 'trail_running';
  if (t.contains('run')) return 'running';
  if (t.contains('gravel')) return 'cycling_gravel';
  if (t.contains('mountain') || t.contains('mtb')) return 'cycling_mtb';
  if (t.contains('cycl') || t.contains('bik') || t.contains('ride')) {
    return 'cycling_road';
  }
  if (t.contains('swim')) return 'swimming';
  if (t.contains('row')) return 'indoor_rowing';
  if (t.contains('hik')) return 'hiking';
  if (t.contains('inline')) return 'inline_skating';
  if (t.contains('skate_ski') || t.contains('skating_ski')) {
    return 'skate_skiing';
  }
  if (t.contains('ski')) return 'nordic_skiing';
  return null;
}

/// One sport's sessions: typical (last 12 weeks) and best (last year).
class PlanSportHistory {
  const PlanSportHistory(
    this.sessions,
    this.longestMin,
    this.medianMin,
    this.yearLongestMin,
  );
  final int sessions;

  /// Last 12 weeks.
  final double longestMin, medianMin;

  /// Longest session of the last year.
  final double yearLongestMin;

  /// Clearly longer sessions last year than now: rebuild faster.
  bool get hasYearCapacity => yearLongestMin > longestMin * 1.2;
}

/// What the athlete actually did, in three windows: the last 6 weeks
/// (current volume), 12 weeks (typical sessions and intensity) and a year
/// (peak volume and longest sessions, i.e. what they have handled before).
class PlanTrainingHistory {
  const PlanTrainingHistory({
    this.weeklyMinutes = 0,
    this.peakWeeklyMinutes = 0,
    this.sports = const {},
    this.hardShare,
    this.hardMinutesPerWeek,
    this.sessions12w = 0,
    this.activeWeeks12w = 0,
    this.activeWeeks52 = 0,
  });

  /// Weeks of the last year with at least an hour of training: how long
  /// the athlete has trained regularly.
  final int activeWeeks52;

  /// Sessions and distinct active weeks in the last 12 weeks.
  final int sessions12w, activeWeeks12w;

  /// Enough training history to judge the athlete's level from data.
  bool get enoughForLevel => sessions12w >= 12 && activeWeeks12w >= 6;

  /// Average of the last 6 weeks.
  final double weeklyMinutes;

  /// Highest 4-week average of the last year.
  final double peakWeeklyMinutes;
  final Map<String, PlanSportHistory> sports;

  /// Fraction of HR-zone time in zones 4–5 (last 12 weeks); null without
  /// zone data.
  final double? hardShare;

  /// Minutes in zones 4–5 per week over the last 12 weeks (or the weeks
  /// covered); null without zone data.
  final double? hardMinutesPerWeek;

  bool get isEmpty => sports.isEmpty;

  /// Rarely trains hard: introduce intensity gradually. Judged by the hard
  /// minutes themselves, not their share: long easy events make the share
  /// tiny even for an athlete who does intervals every week.
  bool get mostlyEasy => hardMinutesPerWeek != null && hardMinutesPerWeek! < 10;

  /// History for [sport], falling back to the closest related sport.
  PlanSportHistory? forSport(String sport) {
    final direct = sports[sport];
    if (direct != null) return direct;
    const related = {
      'trail_running': 'running',
      'running': 'trail_running',
      'cycling_gravel': 'cycling_road',
      'cycling_mtb': 'cycling_road',
      'cycling_road': 'cycling_gravel',
    };
    final alt = related[sport];
    return alt == null ? null : sports[alt];
  }

  static PlanTrainingHistory fromActivities(
    List<ActivityView> activities,
    DateTime now,
  ) {
    if (activities.isEmpty) return const PlanTrainingHistory();
    final six = now.subtract(const Duration(days: 42));
    final twelve = now.subtract(const Duration(days: 84));
    final recent = <String, List<double>>{};
    final yearLongest = <String, double>{};
    final weekMinutes = <int, double>{};
    var sixMin = 0.0, zoneMin = 0.0, hardMin = 0.0;
    var sessions12w = 0;
    final activeWeeks = <int>{};
    var earliest = now;
    for (final a in activities) {
      final minutes = a.durationSeconds / 60;
      if (minutes <= 0) continue;
      if (a.startDate.isBefore(earliest)) earliest = a.startDate;
      final week = now.difference(a.startDate).inDays ~/ 7;
      weekMinutes[week] = (weekMinutes[week] ?? 0) + minutes;
      final sport = planPlannerSport(a.type);
      if (sport != null) {
        yearLongest[sport] = math.max(yearLongest[sport] ?? 0, minutes);
      }
      if (a.startDate.isBefore(twelve)) continue;
      sessions12w++;
      activeWeeks.add(week);
      if (!a.startDate.isBefore(six)) sixMin += minutes;
      if (sport != null) recent.putIfAbsent(sport, () => []).add(minutes);
      final zonesJson = a.hrZonesJson;
      if (zonesJson == null) continue;
      try {
        final zones = jsonDecode(zonesJson) as Map<String, dynamic>;
        double pct(String k) => (zones[k] as num?)?.toDouble() ?? 0;
        final all = [
          'zone1',
          'zone2',
          'zone3',
          'zone4',
          'zone5',
        ].map(pct).fold<double>(0, (x, y) => x + y);
        if (all <= 0) continue;
        zoneMin += minutes;
        hardMin += minutes * (pct('zone4') + pct('zone5')) / all;
      } catch (_) {}
    }
    // Average over the weeks actually covered (at most 6).
    final sixWeeks = (now.difference(earliest).inDays / 7).ceil().clamp(1, 6);
    var peak = 0.0;
    for (var w = 0; w + 3 <= 52; w++) {
      final sum = [for (var i = w; i < w + 4; i++) weekMinutes[i] ?? 0]
          .fold<double>(0, (a, b) => a + b);
      peak = math.max(peak, sum / 4);
    }
    return PlanTrainingHistory(
      weeklyMinutes: sixMin / sixWeeks,
      peakWeeklyMinutes: peak,
      sports: {
        for (final e in recent.entries)
          e.key: PlanSportHistory(
            e.value.length,
            e.value.reduce(math.max),
            (List.of(e.value)..sort())[e.value.length ~/ 2],
            yearLongest[e.key] ?? e.value.reduce(math.max),
          ),
      },
      hardShare: zoneMin > 0 ? hardMin / zoneMin : null,
      activeWeeks52: weekMinutes.values.where((m) => m >= 60).length,
      hardMinutesPerWeek: zoneMin > 0
          ? hardMin / (now.difference(earliest).inDays / 7).ceil().clamp(1, 12)
          : null,
      sessions12w: sessions12w,
      activeWeeks12w: activeWeeks.length,
    );
  }
}

/// Weekly ramp rate: volume handled within the last year ([peakMin]) can be
/// rebuilt faster (15 %/week), otherwise the experience-based rate.
double volumeRampRate({
  required double targetMin,
  required double peakMin,
  required PlanAthleteProfile athlete,
}) => targetMin <= peakMin * 1.05 ? 0.15 : athlete.volumeRampPerWeek;

/// Weekly minutes for week [week]: from current volume towards [targetMin],
/// growing by [rate] per week. Without history start at 70% of the target.
double rampedWeeklyMinutes({
  required double targetMin,
  required double recentMin,
  required int week,
  required double rate,
}) {
  final start = recentMin > 0
      ? math.min(targetMin, recentMin * (1 + rate))
      : targetMin * 0.7;
  return math.min(targetMin, start * math.pow(1 + rate, week)).toDouble();
}

class PlanAthleteFitnessSnapshot {
  const PlanAthleteFitnessSnapshot({
    required this.ctl,
    required this.tsb,
    this.vo2max,
    this.lt2Bpm,
    this.lt1Bpm,
    this.hrZones = const [],
    this.hrFloors = const [],
    this.maxHr,
    required this.tier,
    this.hrvRatio = 1.0,
    this.sleepScore,
    this.weeklyTss = 0,
    this.easyRunZ2 = false,
  });

  final double ctl;
  final double tsb;
  final double? vo2max;
  final int? lt2Bpm;
  final int? lt1Bpm;

  /// Upper HR bound of zones 1–4 (zone 5 is open-ended).
  final List<int> hrZones;

  /// Lower HR bound of zones 1 to 5, when known. Preferred over [hrZones]:
  /// a zone then runs from its floor to the next floor minus one.
  final List<int> hrFloors;

  /// The athlete's maximum heart rate, the upper end of zone 5.
  final int? maxHr;
  final String tier;
  final double hrvRatio;
  final int? sleepScore;
  final double weeklyTss;

  /// Running at zone-1 heart rate is close to walking and few runners can do
  /// it. For runs, an "easy" zone 1 is therefore planned as the lower half of
  /// zone 2, which is where an easy run really sits.
  final bool easyRunZ2;

  /// The lower half of zone 2: where a recovery or easy run is run.
  ({int? low, int? high}) easyRunRange() {
    final z2 = hrRangeForZone(2);
    if (z2.low == null || z2.high == null) return z2;
    return (low: z2.low, high: z2.low! + ((z2.high! - z2.low!) / 2).round());
  }

  bool get isFatigued => tsb < -20;

  PlanAthleteFitnessSnapshot withHrZones(List<int> zones) =>
      PlanAthleteFitnessSnapshot(
        ctl: ctl,
        tsb: tsb,
        vo2max: vo2max,
        lt2Bpm: lt2Bpm,
        lt1Bpm: lt1Bpm,
        hrZones: zones,
        hrFloors: hrFloors,
        maxHr: maxHr,
        tier: tier,
        hrvRatio: hrvRatio,
        sleepScore: sleepScore,
        weeklyTss: weeklyTss,
        easyRunZ2: easyRunZ2,
      );

  ({int? low, int? high}) hrRangeForZone(int zone) {
    if (hrFloors.length >= 5 && zone >= 1) {
      final z = zone.clamp(1, 5);
      final low = hrFloors[z - 1];
      final high = z == 5
          ? (maxHr != null && maxHr! > low ? maxHr : null)
          : hrFloors[z] - 1;
      return (low: low, high: high);
    }
    if (hrZones.length < 4 || zone < 1) return (low: null, high: null);
    final z = zone.clamp(1, 5);
    final low = z == 1 ? null : hrZones[z - 2];
    final high = z == 5 ? null : hrZones[z - 1];
    return (low: low, high: high);
  }
}
