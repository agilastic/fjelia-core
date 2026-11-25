/// Training load and form (CTL, ATL, TSB) from daily loads.
library;

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// One day of the form chart.
class FormPoint {
  const FormPoint({
    required this.date,
    required this.ctl,
    required this.atl,
    required this.load,
    this.historyStart,
  });

  final DateTime date;
  final double ctl;
  final double atl;
  final double load;
  final DateTime? historyStart;

  /// Calendar days of available history, including rest days. Null for points
  /// supplied without initialization metadata (for example, imported series).
  int? get historyDays => historyStart == null
      ? null
      : DateTime.utc(date.year, date.month, date.day)
                .difference(
                  DateTime.utc(
                    historyStart!.year,
                    historyStart!.month,
                    historyStart!.day,
                  ),
                )
                .inDays +
            1;

  double get tsb => ctl - atl;
}

/// How the athlete's form (TSB) reads, from fresh to very fatigued.
enum FormStatus {
  noHistory,
  fresh,
  optimal,
  neutral,
  tired,
  veryFatigued;

  static FormStatus of(double? tsb) => switch (tsb) {
    null => noHistory,
    > 15 => fresh,
    > 5 => optimal,
    > -10 => neutral,
    > -20 => tired,
    _ => veryFatigued,
  };

  /// Whether the form is good to go (green), tiring (red) or in between.
  FormTone get tone => switch (this) {
    noHistory => FormTone.none,
    fresh || optimal => FormTone.good,
    neutral => FormTone.caution,
    tired || veryFatigued => FormTone.strained,
  };
}

enum FormTone { none, good, caution, strained }

/// Initialize from the earliest usable load record, then process every local
/// calendar day through [through]. The visible chart range never resets the
/// calculation. Keep the existing smoothing coefficients used by Fjelia.
List<FormPoint> buildTrainingFormSeries({
  required Map<DateTime, double> dailyLoads,
  required DateTime through,
}) {
  final end = _day(through);
  final daily = <DateTime, double>{};
  // Ignore Unix-epoch placeholder dates while retaining all real imported
  // history. A sentinel row otherwise makes the chart claim to start in 1970.
  final earliestUsableDate = DateTime(1970, 1, 2);
  for (final entry in dailyLoads.entries) {
    final d = _day(entry.key);
    final load = entry.value;
    if (d.isBefore(earliestUsableDate) ||
        d.isAfter(end) ||
        !load.isFinite ||
        load < 0) {
      continue;
    }
    daily[d] = (daily[d] ?? 0) + load;
  }
  if (daily.isEmpty) return [];
  final start = (daily.keys.toList()..sort()).first;
  final span = DateTime.utc(
    end.year,
    end.month,
    end.day,
  ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
  var ctl = 0.0, atl = 0.0;
  final points = <FormPoint>[];
  for (var i = 0; i <= span; i++) {
    final d = DateTime(start.year, start.month, start.day + i);
    final load = daily[d] ?? 0;
    ctl += (load - ctl) * (2 / 43);
    atl += (load - atl) * 0.25;
    points.add(
      FormPoint(date: d, ctl: ctl, atl: atl, load: load, historyStart: start),
    );
  }
  return points;
}

/// Fitness, fatigue and form for the [days] after [from]'s day: the
/// planned load per day from [planned], rest on the others. Same smoothing
/// as [buildTrainingFormSeries], so the forecast continues the chart.
List<FormPoint> projectTrainingForm(
  FormPoint from, {
  Map<DateTime, double> planned = const {},
  int days = 45,
}) {
  final plan = {for (final e in planned.entries) _day(e.key): e.value};
  var ctl = from.ctl, atl = from.atl;
  return [
    for (var i = 1; i <= days; i++)
      () {
        final d = DateTime(from.date.year, from.date.month, from.date.day + i);
        final load = plan[d] ?? 0;
        ctl += (load - ctl) * (2 / 43);
        atl += (load - atl) * 0.25;
        return FormPoint(date: d, ctl: ctl, atl: atl, load: load);
      }(),
  ];
}
