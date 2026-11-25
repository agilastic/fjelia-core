import 'package:drift/drift.dart';
import 'package:fjelia_core/services/readiness.dart';
import 'package:fjelia_data/database.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// A value per day, oldest first.
typedef DailySeries = List<(DateTime, double)>;

/// One measure's latest value and how it compares with the week before.
class HealthMetric {
  const HealthMetric(this.series);

  final DailySeries series;

  (DateTime, double)? get latest => series.isEmpty ? null : series.last;

  /// The average of the 7 days before the latest value; null without them.
  double? get weekBefore {
    final last = latest;
    if (last == null) return null;
    final from = last.$1.subtract(const Duration(days: 8));
    final values = [
      for (final (d, v) in series)
        if (d.isAfter(from) && d.isBefore(last.$1)) v,
    ];
    return values.isEmpty
        ? null
        : values.reduce((a, b) => a + b) / values.length;
  }

  /// Latest minus [weekBefore].
  double? get change {
    final last = latest, before = weekBefore;
    return last == null || before == null ? null : last.$2 - before;
  }

  bool get isEmpty => series.isEmpty;
}

/// One night.
class SleepNight {
  const SleepNight({
    required this.date,
    required this.total,
    this.deep,
    this.rem,
    this.light,
    this.awake,
    this.score,
  });
  final DateTime date;
  final Duration total;
  final Duration? deep, rem, light, awake;
  final double? score;
}

/// A day's blood pressure.
class BloodPressureDay {
  const BloodPressureDay(this.date, this.systolic, this.diastolic, this.count);
  final DateTime date;
  final double systolic, diastolic;
  final int count;
}

/// An ECG recording, without its waveform.
class EcgItem {
  const EcgItem({
    required this.id,
    required this.recordedAt,
    required this.kind,
    required this.duration,
    this.device,
    this.note,
  });
  final String id;
  final DateTime recordedAt;

  /// `spot`, `sleep`, `workout` or the like, as the phone recorded it.
  final String kind;
  final Duration duration;
  final String? device;
  final String? note;
}

/// Everything the Health screen shows.
class HealthView {
  const HealthView({
    required this.days,
    required this.hrv,
    required this.restingHr,
    required this.sleepHours,
    required this.sleepScore,
    required this.nights,
    required this.steps,
    required this.weight,
    required this.bodyFat,
    required this.bloodPressure,
    required this.readiness,
    required this.ecg,
  });

  final int days;
  final HealthMetric hrv;
  final HealthMetric restingHr;
  final HealthMetric sleepHours;
  final HealthMetric sleepScore;

  /// The last 14 nights, newest last.
  final List<SleepNight> nights;
  final HealthMetric steps;
  final HealthMetric weight;
  final HealthMetric bodyFat;
  final List<BloodPressureDay> bloodPressure;

  /// The morning verdict per day.
  final Map<DateTime, ReadinessLevel> readiness;

  /// The newest recordings first.
  final List<EcgItem> ecg;

  bool get isEmpty =>
      hrv.isEmpty &&
      restingHr.isEmpty &&
      sleepHours.isEmpty &&
      weight.isEmpty &&
      bloodPressure.isEmpty &&
      ecg.isEmpty;
}

Future<HealthView> loadHealth(
  AppDatabase db, {
  int days = 90,
  DateTime? now,
}) async {
  final today = _day(now ?? DateTime.now());
  final from = DateTime(today.year, today.month, today.day - days + 1);
  final until = DateTime(today.year, today.month, today.day + 1);
  DailySeries series(Iterable<(DateTime, double?)> raw) {
    final byDay = <DateTime, double>{};
    for (final (d, v) in raw) {
      if (v == null || !v.isFinite || v <= 0) continue;
      byDay[_day(d.toLocal())] = v;
    }
    final keys = byDay.keys.toList()..sort();
    return [for (final k in keys) (k, byDay[k]!)];
  }

  final hrvRows =
      await (db.select(db.hrvRecords)..where(
            (t) =>
                t.date.isBiggerOrEqualValue(from) &
                t.date.isSmallerThanValue(until),
          ))
          .get();
  final sleepRows =
      await (db.select(db.sleepRecords)
            ..where(
              (t) =>
                  t.date.isBiggerOrEqualValue(from) &
                  t.date.isSmallerThanValue(until),
            )
            ..orderBy([(t) => OrderingTerm(expression: t.date)]))
          .get();
  final wellness =
      await (db.select(db.wellnessRecords)..where(
            (t) =>
                t.date.isBiggerOrEqualValue(from) &
                t.date.isSmallerThanValue(until),
          ))
          .get();
  final scale =
      await (db.select(db.renphoRecords)..where(
            (t) =>
                t.measuredAt.isBiggerOrEqualValue(from) &
                t.measuredAt.isSmallerThanValue(until),
          ))
          .get();
  final bp =
      await (db.select(db.dailyBpSummaries)
            ..where(
              (t) =>
                  t.date.isBiggerOrEqualValue(from) &
                  t.date.isSmallerThanValue(until),
            )
            ..orderBy([(t) => OrderingTerm(expression: t.date)]))
          .get();
  final readiness = <DateTime, ReadinessLevel>{};
  for (final r
      in await (db.select(db.dailyReadinessRecords)..where(
            (t) =>
                t.athleteId.equals('self') &
                t.date.isBiggerOrEqualValue(from) &
                t.date.isSmallerThanValue(until),
          ))
          .get()) {
    if (ReadinessLevel.values.asNameMap()[r.level] case final level?) {
      readiness[_day(r.date.toLocal())] = level;
    }
  }
  final ecg =
      await (db.select(db.ecgRecordings)
            ..orderBy([(t) => OrderingTerm.desc(t.recordedAt)])
            ..limit(30))
          .get();

  final nights = [
    for (final s in sleepRows)
      if (s.totalSleepSeconds > 0)
        SleepNight(
          date: _day(s.date.toLocal()),
          total: Duration(seconds: s.totalSleepSeconds),
          deep: _seconds(s.deepSleepSeconds),
          rem: _seconds(s.remSleepSeconds),
          light: _seconds(s.lightSleepSeconds),
          awake: _seconds(s.awakeSleepSeconds),
          score: s.sleepScore,
        ),
  ];
  return HealthView(
    days: days,
    hrv: HealthMetric(
      series([for (final r in hrvRows) (r.date, r.hrvLastNight)]),
    ),
    restingHr: HealthMetric(
      series([
        for (final r in hrvRows) (r.date, r.restingHeartRate?.toDouble()),
      ]),
    ),
    sleepHours: HealthMetric(
      series([for (final n in nights) (n.date, n.total.inMinutes / 60)]),
    ),
    sleepScore: HealthMetric(
      series([for (final n in nights) (n.date, n.score)]),
    ),
    nights: nights.length > 14 ? nights.sublist(nights.length - 14) : nights,
    steps: HealthMetric(
      series([for (final w in wellness) (w.date, w.steps?.toDouble())]),
    ),
    weight: HealthMetric(
      series([for (final s in scale) (s.measuredAt, s.weight)]),
    ),
    bodyFat: HealthMetric(
      series([for (final s in scale) (s.measuredAt, s.bodyFat)]),
    ),
    bloodPressure: [
      for (final b in bp)
        if (b.avgSystolic > 0)
          BloodPressureDay(
            _day(b.date.toLocal()),
            b.avgSystolic,
            b.avgDiastolic,
            b.count,
          ),
    ],
    readiness: readiness,
    ecg: [
      for (final e in ecg)
        EcgItem(
          id: e.recordingId,
          recordedAt: e.recordedAt.toLocal(),
          kind: e.kind,
          duration: Duration(milliseconds: e.durationMs),
          device: e.deviceName,
          note: e.note,
        ),
    ],
  );
}

Duration? _seconds(int? s) => s == null || s <= 0 ? null : Duration(seconds: s);
