import 'dart:math' as math;

enum ReadinessLevel { green, yellow, red }

enum TrainingSeverity { normal, tierDown, rest }

class TrainingSeverityResult {
  const TrainingSeverityResult(this.severity, [this.reason]);

  final TrainingSeverity severity;
  final String? reason;
}

/// Morning readiness: flags from today's physiology against personal
/// baselines, a 0–10 composite and the resulting traffic-light level.
class ReadinessResult {
  const ReadinessResult({
    required this.level,
    required this.flagCount,
    this.hrvLow = false,
    this.restingHrHigh = false,
    this.respirationHigh = false,
    this.stressHigh = false,
    this.spo2Low = false,
    this.sleepShort = false,
    this.remLow = false,
    this.deepLow = false,
    this.batteryLow = false,
    this.skinTempShift = false,
    this.fatigue = false,
    this.hrvToday,
    this.hrvBaseline,
    this.restingHrToday,
    this.restingHrBaseline,
    this.respirationRate,
    this.stressLevel,
    this.spo2,
    this.sleepScore,
    this.bodyBattery,
    this.skinTempDelta,
    this.tsb,
    this.compositeScore,
    this.severity = TrainingSeverity.normal,
  });

  final ReadinessLevel level;
  final int flagCount;
  final bool hrvLow;
  final bool restingHrHigh;
  final bool respirationHigh;
  final bool stressHigh;
  final bool spo2Low;
  final bool sleepShort;
  final bool remLow;
  final bool deepLow;
  final bool batteryLow;
  final bool skinTempShift;
  final bool fatigue;
  final double? hrvToday;
  final double? hrvBaseline;
  final double? restingHrToday;
  final double? restingHrBaseline;
  final double? respirationRate;
  final double? stressLevel;
  final double? spo2;
  final int? sleepScore;
  final int? bodyBattery;
  final double? skinTempDelta;
  final double? tsb;
  final double? compositeScore;
  final TrainingSeverity severity;

  String get adaptationReason {
    if (level == ReadinessLevel.green) return '';
    return [
      if (hrvLow) 'HRV lower than usual',
      if (restingHrHigh) 'resting HR elevated',
      if (respirationHigh) 'breathing rate elevated',
      if (stressHigh) 'stress load high',
      if (spo2Low) 'low blood oxygen',
      if (sleepShort) 'insufficient sleep',
      if (remLow) 'poor sleep quality (low REM)',
      if (deepLow) 'poor sleep quality (low deep)',
      if (batteryLow) 'body battery depleted',
      if (skinTempShift) 'skin temp shift',
      if (fatigue) 'accumulated fatigue',
    ].join(', ');
  }
}

/// One night's HRV and morning physiology, as readiness reads it.
class ReadinessHrvDay {
  const ReadinessHrvDay({
    required this.date,
    this.hrvLastNight,
    this.restingHeartRate,
    this.respirationRate,
    this.stressLevel,
    this.spo2,
    this.bodyBattery,
    this.computedEnergie,
    this.skinTempDelta,
  });

  final DateTime date;
  final double? hrvLastNight;
  final int? restingHeartRate;
  final double? respirationRate;
  final double? stressLevel;
  final double? spo2;
  final double? bodyBattery;
  final double? computedEnergie;
  final double? skinTempDelta;
}

/// One night's sleep, as readiness reads it.
class ReadinessSleepNight {
  const ReadinessSleepNight({
    required this.date,
    required this.totalSleepSeconds,
    required this.remSleepSeconds,
    required this.deepSleepSeconds,
    this.sleepNeedSeconds,
    this.sleepScore,
  });

  final DateTime date;
  final int totalSleepSeconds;
  final int remSleepSeconds;
  final int deepSleepSeconds;
  final int? sleepNeedSeconds;
  final double? sleepScore;
}

/// One day's wellness summary, as readiness reads it.
class ReadinessWellnessDay {
  const ReadinessWellnessDay({
    this.averageStress,
    this.avgSpo2,
    this.bodyBatteryHighest,
  });

  final double? averageStress;
  final double? avgSpo2;
  final double? bodyBatteryHighest;
}

/// [ReadinessResult] plus the intermediate values the app stores with it.
class ReadinessEvaluation {
  const ReadinessEvaluation(
    this.result, {
    this.hrvDrop,
    this.restingHrElevation,
  });

  final ReadinessResult result;

  /// Fraction below the 7-day HRV baseline (0.1 = 10 % lower).
  final double? hrvDrop;

  /// Beats per minute above the 7-day resting-HR baseline.
  final double? restingHrElevation;
}

/// Readiness flags, composite score and severity from the day's data.
abstract final class Readiness {
  /// Flags for [hrvToday], [sleep] and [wellness] against the history before
  /// that day: [hrv7] (7 days) and [sleepHistory] (67 days).
  static ReadinessEvaluation evaluate({
    required List<ReadinessHrvDay> hrv7,
    required ReadinessHrvDay? hrvToday,
    required ReadinessSleepNight? sleep,
    required ReadinessWellnessDay? wellness,
    required List<ReadinessSleepNight> sleepHistory,
    required double? tsb,
    required double? composite,
    required TrainingSeverityResult severity,
  }) {
    // HRV drop vs 7-day baseline.
    final hrvBaseline = _mean(
      hrv7
          .where((r) => r.hrvLastNight != null)
          .map((r) => r.hrvLastNight!)
          .toList(),
    );
    final hrvNow = hrvToday?.hrvLastNight;
    double? hrvDrop;
    if (hrvBaseline != null && hrvNow != null && hrvBaseline > 0) {
      hrvDrop = (hrvBaseline - hrvNow) / hrvBaseline;
    }
    final hrvLow = hrvDrop != null && hrvDrop > 0.08;

    // Resting HR elevation.
    final rhrBaseline = _mean(
      hrv7
          .where((r) => r.restingHeartRate != null)
          .map((r) => r.restingHeartRate!.toDouble())
          .toList(),
    );
    final rhrNow = hrvToday?.restingHeartRate?.toDouble();
    final rhrElevation = rhrBaseline != null && rhrNow != null
        ? rhrNow - rhrBaseline
        : null;
    final rhrHigh = rhrElevation != null && rhrElevation > 5.0;

    // Breathing rate.
    final respBaseline = _mean(
      hrv7
          .where((r) => r.respirationRate != null)
          .map((r) => r.respirationRate!)
          .toList(),
    );
    final respNow = hrvToday?.respirationRate;
    final respHigh =
        respBaseline != null && respNow != null && respNow - respBaseline > 1.0;

    // Stress.
    final stressBaseline = _mean(
      hrv7
          .where((r) => r.stressLevel != null)
          .map((r) => r.stressLevel!)
          .toList(),
    );
    final stressNow = wellness?.averageStress ?? hrvToday?.stressLevel;
    final stressHigh =
        stressNow != null &&
        stressNow > 35.0 &&
        stressBaseline != null &&
        stressNow - stressBaseline > 8.0;

    // Blood oxygen.
    final spo2 = wellness?.avgSpo2 ?? hrvToday?.spo2;
    final spo2Low = spo2 != null && spo2 < 94.0;

    // Sleep quantity and architecture.
    final sleepScore = sleep?.sleepScore?.round();
    var sleepShort = false;
    var remLow = false;
    var deepLow = false;
    if (sleep != null && sleep.totalSleepSeconds > 0) {
      final need = sleep.sleepNeedSeconds;
      if (need != null && need > 0) {
        final ratio = (sleep.totalSleepSeconds / need).clamp(0.0, 1.5);
        sleepShort = ratio < 0.75 && (sleepScore == null || sleepScore < 70);
      }
      final valid = sleepHistory.where((s) => s.totalSleepSeconds > 0).toList();
      final remBase = _mean(
        valid.map((s) => s.remSleepSeconds / s.totalSleepSeconds).toList(),
      );
      final deepBase = _mean(
        valid.map((s) => s.deepSleepSeconds / s.totalSleepSeconds).toList(),
      );
      final remNow = sleep.remSleepSeconds / sleep.totalSleepSeconds;
      final deepNow = sleep.deepSleepSeconds / sleep.totalSleepSeconds;
      remLow = remBase != null && remBase > 0 && remNow < remBase * 0.5;
      deepLow = deepBase != null && deepBase > 0 && deepNow < deepBase * 0.5;
    }

    // Body battery.
    final battery =
        (wellness?.bodyBatteryHighest ??
                hrvToday?.bodyBattery ??
                hrvToday?.computedEnergie)
            ?.round();
    final batteryLow = battery != null && battery < 25;

    // Skin temperature.
    // Only a temperature: an HRV value is a different unit and no fallback.
    final skinTemp = hrvToday?.skinTempDelta;
    final skinShift =
        hrvToday?.skinTempDelta != null &&
        hrvToday!.skinTempDelta!.abs() >= 0.5;

    final fatigue = tsb != null && tsb < -20.0;

    final flags = [
      hrvLow,
      rhrHigh,
      respHigh,
      stressHigh,
      spo2Low,
      sleepShort,
      remLow,
      deepLow,
      batteryLow,
      skinShift,
      fatigue,
    ];
    final flagCount = flags.where((f) => f).length;

    ReadinessLevel level;
    if (severity.severity == TrainingSeverity.rest || flagCount >= 3) {
      level = ReadinessLevel.red;
    } else if (severity.severity == TrainingSeverity.tierDown ||
        flagCount >= 1) {
      level = composite != null && composite >= 7.0 && flagCount == 1
          ? ReadinessLevel.green
          : ReadinessLevel.yellow;
    } else {
      level = ReadinessLevel.green;
    }

    return ReadinessEvaluation(
      ReadinessResult(
        level: level,
        flagCount: flagCount,
        hrvLow: hrvLow,
        restingHrHigh: rhrHigh,
        respirationHigh: respHigh,
        stressHigh: stressHigh,
        spo2Low: spo2Low,
        sleepShort: sleepShort,
        remLow: remLow,
        deepLow: deepLow,
        batteryLow: batteryLow,
        skinTempShift: skinShift,
        fatigue: fatigue,
        hrvToday: hrvNow,
        hrvBaseline: hrvBaseline,
        restingHrToday: rhrNow,
        restingHrBaseline: rhrBaseline,
        respirationRate: respNow,
        stressLevel: stressNow,
        spo2: spo2,
        sleepScore: sleepScore,
        bodyBattery: battery,
        skinTempDelta: skinTemp,
        tsb: tsb,
        compositeScore: composite,
        severity: severity.severity,
      ),
      hrvDrop: hrvDrop,
      restingHrElevation: rhrElevation,
    );
  }

  /// Severity for the training plan: from the composite and TSB.
  static TrainingSeverityResult severity({
    required double? composite,
    required double? tsb,
  }) {
    if (composite != null) {
      if (composite < 3.5) {
        return TrainingSeverityResult(
          TrainingSeverity.rest,
          'Readiness ${composite.toStringAsFixed(1)}/10 — rest recommended',
        );
      }
      if (composite < 5.5) {
        return TrainingSeverityResult(
          TrainingSeverity.tierDown,
          'Readiness ${composite.toStringAsFixed(1)}/10 — reduced effort recommended',
        );
      }
      if (tsb == null || tsb >= -20) {
        return TrainingSeverityResult(
          TrainingSeverity.normal,
          'Readiness ${composite.toStringAsFixed(1)}/10 — good to train',
        );
      }
    }
    if (tsb != null && tsb < -20.0) {
      return TrainingSeverityResult(
        TrainingSeverity.tierDown,
        'TSB ${tsb.toStringAsFixed(1)} — accumulated fatigue',
      );
    }
    if (tsb != null && tsb > 10.0) {
      return TrainingSeverityResult(
        TrainingSeverity.normal,
        'TSB ${tsb.toStringAsFixed(1)} — fresh and primed',
      );
    }
    return const TrainingSeverityResult(TrainingSeverity.normal);
  }

  /// Weighted z-scores of nine markers, mapped to 0–10 (5 = personal norm),
  /// against the 30 days before the day. Null when less than 40 % of the
  /// weight has data.
  static double? compositeScore({
    required List<ReadinessHrvDay> history,
    required ReadinessHrvDay? today,
    required ReadinessSleepNight? sleep,
    required List<ReadinessSleepNight> sleepHistory,
    required ReadinessWellnessDay? wellness,
  }) {
    double? score(double? value, List<double> baseline, {bool invert = false}) {
      if (value == null || baseline.length < 3) return null;
      final z = _zscore(value, baseline);
      return (5 + (invert ? -z : z) * 2.5).clamp(0.0, 10.0);
    }

    List<double> pick(double? Function(ReadinessHrvDay) f) =>
        history.map(f).whereType<double>().toList();

    final hrv = score(today?.hrvLastNight, pick((r) => r.hrvLastNight));
    final rhr = score(
      today?.restingHeartRate?.toDouble(),
      pick((r) => r.restingHeartRate?.toDouble()),
      invert: true,
    );
    final resp = score(
      today?.respirationRate,
      pick((r) => r.respirationRate),
      invert: true,
    );
    final stress = score(
      wellness?.averageStress ?? today?.stressLevel,
      pick((r) => r.stressLevel),
      invert: true,
    );
    final spo2Value = wellness?.avgSpo2 ?? today?.spo2;
    final spo2 = spo2Value == null
        ? null
        : ((spo2Value - 90) / 1.0).clamp(0.0, 10.0);
    final sleepScore = sleep?.sleepScore == null
        ? null
        : (sleep!.sleepScore! / 10).clamp(0.0, 10.0);
    final sleepDuration = sleep == null
        ? null
        : score(
            sleep.totalSleepSeconds.toDouble(),
            sleepHistory
                .where((s) => s.totalSleepSeconds > 0)
                .map((s) => s.totalSleepSeconds.toDouble())
                .toList(),
          );
    final battery = today?.bodyBattery == null
        ? null
        : (today!.bodyBattery! / 10).clamp(0.0, 10.0);
    final skin = today?.skinTempDelta == null
        ? null
        : (7 - today!.skinTempDelta!.abs() * 5).clamp(0.0, 10.0);

    final parts = <(double, double?)>[
      (0.25, hrv),
      (0.10, rhr),
      (0.10, resp),
      (0.08, stress),
      (0.05, spo2),
      (0.15, sleepScore),
      (0.15, sleepDuration),
      (0.10, battery),
      (0.02, skin),
    ];
    var sum = 0.0, weight = 0.0;
    for (final (w, v) in parts) {
      if (v == null) continue;
      sum += w * v;
      weight += w;
    }
    if (weight < 0.4) return null;
    return double.parse((sum / weight).toStringAsFixed(1));
  }

  /// Form (CTL − ATL) at the start of [day], from the daily strain before it
  /// only: a past date must not see later load. Null without any load.
  static double? formBefore(Map<DateTime, double> dailyLoad, DateTime day) {
    final load = <DateTime, double>{
      for (final e in dailyLoad.entries)
        DateTime(e.key.year, e.key.month, e.key.day): e.value,
    };
    if (load.isEmpty) return null;
    final days = load.keys.toList()..sort();
    var ctl = 0.0, atl = 0.0;
    const ctlAlpha = 2 / 43; // 42-day EWMA
    const atlAlpha = 0.25; // 7-day EWMA
    final end = DateTime(day.year, day.month, day.day);
    for (
      var d = days.first;
      d.isBefore(end);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      final l = load[d] ?? 0.0;
      ctl += ctlAlpha * (l - ctl);
      atl += atlAlpha * (l - atl);
    }
    return ctl - atl;
  }

  static double _zscore(double value, List<double> baseline) {
    final mean = _mean(baseline) ?? value;
    final sd = _stddev(baseline);
    if (sd == 0) return 0.0;
    return ((value - mean) / sd).clamp(-3.0, 3.0);
  }

  static double _stddev(List<double> values) {
    if (values.length < 2) return 0.0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance =
        values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
        values.length;
    return math.sqrt(variance);
  }

  static double? _mean(List<double> values) {
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }
}
