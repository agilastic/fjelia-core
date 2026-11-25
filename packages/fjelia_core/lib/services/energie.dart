import '../models/health_views.dart';

/// One day of Energie: the evening level, the overnight charge and the
/// daytime drain.
class EnergieDay {
  const EnergieDay(this.end, this.charge, this.drain);

  final int end;
  final int charge;
  final int drain;
}

/// The days Energie is calculated from, keyed by local midnight.
class EnergieInputs {
  const EnergieInputs(this.hrv, this.sleep, this.wellness, this.load);

  final Map<DateTime, HrvDayView> hrv;
  final Map<DateTime, SleepNightView> sleep;
  final Map<DateTime, WellnessDayView> wellness;

  /// Training load per day.
  final Map<DateTime, double> load;
}

/// "Energie": Fjelia's own body-battery estimate. Each day starts from the
/// previous evening's level, is charged by sleep (quality, HRV, resting HR)
/// and drained by stress, training, calories and steps.
abstract final class Energie {
  /// [day] starting from the [previous] evening's level.
  static EnergieDay day(EnergieInputs maps, DateTime day, double previous) {
    final start = previous.clamp(5.0, 100.0);
    final sleep = maps.sleep[day];
    final hrv = maps.hrv[day];
    final wellness = maps.wellness[day];
    final avg7 = _avg7dayHrv(maps, day);
    final hrvToday = hrv?.hrvLastNight;

    // Overnight charge.
    var charge = 0.0;
    final total = sleep?.totalSleepSeconds ?? 0;
    if (sleep != null && total > 0) {
      final hours = total / 3600;
      final needHours = (sleep.sleepNeedSeconds ?? 8 * 3600) / 3600;
      final base = (hours / needHours * 50).clamp(0.0, 50.0);
      final stages =
          ((sleep.deepSleepSeconds + sleep.remSleepSeconds) / total / 0.35)
              .clamp(0.5, 1.3);
      final hrvFactor = hrvToday != null && avg7 != null && avg7 > 0
          ? (hrvToday / avg7).clamp(0.4, 1.4)
          : 1.0;
      final rhr = hrv?.restingHeartRate;
      final rhrFactor = rhr == null
          ? 1.0
          : rhr < 50
          ? 1.15
          : rhr > 70
          ? 0.8
          : 1.0;
      charge = (base * stages * hrvFactor * rhrFactor).clamp(0.0, 95.0);
    }
    final wake = (start + charge).clamp(5.0, 100.0);

    // Daytime drain.
    final strainFactor = hrvToday != null && hrvToday > 0 && avg7 != null
        ? (avg7 / hrvToday).clamp(0.5, 1.8)
        : 1.0;
    var drain = 12 * strainFactor;
    final stress = wellness?.averageStress;
    if (stress != null && stress > 25) {
      drain += (stress - 25) / 75 * 60 / 10;
    }
    final load = maps.load[day] ?? 0.0;
    if (load > 0) drain += (load / 350 * 40).clamp(0.0, 40.0);
    final calories = wellness?.activeCalories;
    if (calories != null && calories > 0) {
      drain += (calories / 800 * 30).clamp(0.0, 30.0);
    }
    final steps = wellness?.steps;
    if (steps != null && steps > 0) {
      drain += (steps / 15000 * 10).clamp(0.0, 10.0);
    }
    drain = drain.clamp(0.0, 55.0);

    final end = (wake - drain).clamp(5.0, 100.0);
    return EnergieDay(end.round(), charge.round(), drain.round());
  }

  static double? _avg7dayHrv(EnergieInputs maps, DateTime day) {
    var sum = 0.0;
    var n = 0;
    for (var i = 1; i <= 7; i++) {
      final v = maps.hrv[day.subtract(Duration(days: i))]?.hrvLastNight;
      if (v != null && v > 0) {
        sum += v;
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }
}
