import 'dart:convert';
import 'dart:math' as math;

import '../models/plan_views.dart';
import 'activity_metrics.dart';
import 'sample_series.dart';
import 'training_load.dart';

/// The pure part of the context for chatting about one activity: the
/// activity with its details, the sessions around it, the 30 days before it
/// and the year's progression. Names and GPS are never included.
abstract final class ActivityCoachContext {
  static String buildFrom(
    ActivityView activity,
    List<ActivityView> all, {
    String? hrvLine,
  }) {
    final anchor = activity.startDate;
    final end = DateTime(anchor.year, anchor.month, anchor.day + 1);
    final start30 = end.subtract(const Duration(days: 30));
    final last30 = [
      for (final a in all)
        if (!a.startDate.isBefore(start30) && a.startDate.isBefore(end)) a,
    ];
    final sport = _sport(activity.type);
    final earlier = [
      for (final a in all)
        if (a.startDate.isBefore(anchor)) a.startDate,
    ]..sort();
    final out = <String>[
      '[Activity:${_date(anchor)} ${_weekday(anchor)},Sport:$sport,'
          '${_stats(activity)}]',
      // A long gap may be a pause or missing data: the model must not treat
      // it as rest.
      '[DataStatus:PreviousActivity:${earlier.isEmpty ? 'NoneInLoadedHistory' : '${_date(earlier.last)},DaysBefore:${DateTime(anchor.year, anchor.month, anchor.day).difference(DateTime(earlier.last.year, earlier.last.month, earlier.last.day)).inDays}'},'
          'MissingRecord:Unknown]',
      ?hrvLine,
      ?_detailLine(activity),
      ?_zonesLine(activity),
      ?_halvesLine(activity),
      ..._aroundLines(activity, all),
    ];

    // Last 30 days.
    final t = _Totals.of(last30);
    out.add(
      '[Last30d:${_date(start30)}..${_date(anchor)},Sessions:${t.n},'
      'ActiveDays:${last30.map((a) => _date(a.startDate)).toSet().length},'
      'H:${_dec(t.hours)},Km:${_int(t.km)},Load:${_int(t.load)}]',
    );
    final bySport = _groupBySport(last30);
    out.add(
      '[Last30d:Sports:${bySport.entries.map((e) {
        final s = _Totals.of(e.value);
        return '${e.key} ${s.n}x ${_dec(s.hours)}h ${_int(s.km)}km L${_int(s.load)}';
      }).join(';')}]',
    );
    final weeks = <String>[];
    for (var w = 3; w >= 0; w--) {
      final wEnd = end.subtract(Duration(days: 7 * w));
      final wStart = wEnd.subtract(const Duration(days: 7));
      final s = _Totals.of([
        for (final a in last30)
          if (!a.startDate.isBefore(wStart) && a.startDate.isBefore(wEnd)) a,
      ]);
      weeks.add('${_dec(s.hours)}h/L${_int(s.load)}');
    }
    out.add('[Last30d:Weeks(oldest..newest):${weeks.join(';')}]');

    // This activity vs other sessions of the same sport.
    final same = [
      for (final a in last30)
        if (_sport(a.type) == sport && a.activityId != activity.activityId) a,
    ];
    if (same.isNotEmpty) {
      final s = _Totals.of(same);
      final hr = _avg(same.map((a) => a.avgHeartRate));
      out.add(_compare(activity, sport, s, hr));
      out.add(
        '[Similar30d:$sport,N:${s.n},AvgMin:${_int(s.hours * 60 / s.n)},'
        'AvgKm:${_dec(s.km / s.n)},AvgHR:${_int(hr)},AvgLoad:${_int(s.load / s.n)}'
        '${_speedPart(sport, s.km, s.movingSeconds)}]',
      );
    }

    // Year progression up to the activity, against the same span last year.
    final year = anchor.year;
    bool inYearToDate(ActivityView a, int y) {
      final cutoff = DateTime(y, anchor.month, anchor.day + 1);
      return a.startDate.year == y && a.startDate.isBefore(cutoff);
    }

    for (final y in [year, year - 1]) {
      final ytd = [
        for (final a in all)
          if (inYearToDate(a, y)) a,
      ];
      final s = _Totals.of(ytd);
      out.add(
        '[Year:$y:ToDate(${anchor.month}/${anchor.day}),Sessions:${s.n},'
        'H:${_int(s.hours)},Km:${_int(s.km)},Load:${_int(s.load)}]',
      );
    }
    final months = <String>[];
    for (var m = 1; m <= anchor.month; m++) {
      final s = _Totals.of([
        for (final a in all)
          if (a.startDate.year == year && a.startDate.month == m) a,
      ]);
      months.add('${_monthNames[m - 1]} ${_int(s.hours)}h ${_int(s.km)}km');
    }
    out.add('[Year:$year:Months:${months.join(';')}]');
    final ytdSport = _groupBySport([
      for (final a in all)
        if (inYearToDate(a, year)) a,
    ]);
    out.add(
      '[Year:$year:Sports:${ytdSport.entries.map((e) {
        final s = _Totals.of(e.value);
        return '${e.key} ${s.n}x ${_int(s.hours)}h ${_int(s.km)}km';
      }).join(';')}]',
    );
    return out.join('\n');
  }

  /// This activity against the average of the other sessions of the sport:
  /// the figures and their ratios are worked out here, so a model does not
  /// have to compare numbers itself.
  static String _compare(
    ActivityView a,
    String sport,
    _Totals others,
    double? othersHr,
  ) {
    String ratio(double mine, double avg) =>
        avg > 0 ? ' (${(mine / avg).toStringAsFixed(1)}x)' : '';
    final minutes = a.durationSeconds / 60;
    final avgMinutes = others.hours * 60 / others.n;
    final km = (a.distanceMeters ?? 0) / 1000;
    final avgKm = others.km / others.n;
    final load = effectiveLoad(a);
    final avgLoad = others.load / others.n;
    final parts = <String>[
      'Min:${_int(minutes)} vs ${_int(avgMinutes)}${ratio(minutes, avgMinutes)}',
      if (km > 0 && avgKm > 0)
        'Km:${_dec(km)} vs ${_dec(avgKm)}${ratio(km, avgKm)}',
      'Load:${_int(load)} vs ${_int(avgLoad)}${ratio(load, avgLoad)}',
      if (a.avgHeartRate != null && othersHr != null)
        'AvgHR:${_int(a.avgHeartRate)} vs ${_int(othersHr)}'
            ' (${a.avgHeartRate! - othersHr >= 0 ? '+' : '-'}${(a.avgHeartRate! - othersHr).abs().round()} bpm)',
    ];
    return '[Compare:$sport,N:${others.n},${parts.join(',')}]';
  }

  /// What the watch said beyond the totals.
  static String? _detailLine(ActivityView a) {
    final km = (a.distanceMeters ?? 0) / 1000;
    final parts = [
      'Start:${a.startDate.hour.toString().padLeft(2, '0')}:${a.startDate.minute.toString().padLeft(2, '0')}',
      if (a.source != null) 'Source:${a.source}',
      if (a.movingDurationSeconds != null)
        'MovingMin:${_int(a.movingDurationSeconds! / 60)}',
      if (a.avgRunCadence != null) 'Cadence:${_int(a.avgRunCadence)}',
      if (a.recoveryTimeSeconds != null)
        'RecoveryH:${_int(a.recoveryTimeSeconds! / 3600)}',
      if (a.vo2maxActivity != null) 'VO2max:${_dec(a.vo2maxActivity)}',
      if (a.calories != null) 'Kcal:${_int(a.calories)}',
      if (a.maxSpeedMps != null) 'MaxKmh:${_dec(a.maxSpeedMps! * 3.6)}',
      if (a.activityFeedbackPhrase != null)
        'WatchFeedback:${a.activityFeedbackPhrase}',
      if (a.plannedDurationSeconds != null)
        'PlannedMin:${_int(a.plannedDurationSeconds! / 60)}',
      if (a.plannedDistanceMeters != null && km > 0)
        'PlannedKm:${_dec(a.plannedDistanceMeters! / 1000)}',
    ];
    return '[ActivityDetail:${parts.join(',')}]';
  }

  /// Time in heart-rate zones, in percent; stored as percent or seconds.
  static String? _zonesLine(ActivityView a) {
    final raw = a.hrZonesJson;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final values = [
        for (var i = 1; i <= 5; i++)
          (decoded['zone$i'] is num ? decoded['zone$i'] as num : 0).toDouble(),
      ];
      final total = values.fold<double>(0, (s, v) => s + v);
      if (total <= 0) return null;
      final pct = total <= 102.5
          ? values
          : [for (final v in values) v / total * 100];
      return '[HRZones%:${[for (var i = 0; i < 5; i++) 'Z${i + 1}:${pct[i].round()}'].join(',')}]';
    } catch (_) {
      return null;
    }
  }

  /// First half against second half of the recording: pace (or speed) and
  /// heart rate, and the aerobic decoupling (output per beat lost).
  static String? _halvesLine(ActivityView a) {
    final raw = a.metricsJson;
    if (raw == null || a.durationSeconds < 20 * 60) return null;
    try {
      final samples = [
        for (final s in jsonDecode(raw) as List)
          if (s is Map && s['t'] is num) s,
      ];
      if (samples.length < 20) return null;
      final t0 = (samples.first['t'] as num).toDouble();
      final t1 = (samples.last['t'] as num).toDouble();
      final mid = (t0 + t1) / 2;
      ({double? hr, double? speed}) half(bool first) {
        final part = [
          for (final s in samples)
            if (((s['t'] as num) < mid) == first) s,
        ];
        double? avg(String key, {double min = 0}) {
          final v = [
            for (final s in part)
              if (s[key] is num && (s[key] as num) > min)
                (s[key] as num).toDouble(),
          ];
          return v.isEmpty ? null : v.reduce((x, y) => x + y) / v.length;
        }

        // Stops do not count towards the moving speed.
        return (hr: avg('hr'), speed: avg('spd', min: .5));
      }

      final a1 = half(true), a2 = half(false);
      if (a1.hr == null || a2.hr == null) return null;
      final sport = _sport(a.type);
      final pace = const {'run', 'walk', 'hike'}.contains(sport);
      String move(double? mps) => mps == null
          ? 'na'
          : pace
          ? '${(1000 / mps / 60).floor()}:${((1000 / mps) % 60).round().toString().padLeft(2, '0')}/km'
          : '${_dec(mps * 3.6)}km/h';
      // Heart rate against output, warm-up left out: activity_metrics.
      final drift = aerobicEfficiency(SampleSeries.fromMetrics(raw))
          ?.decouplingPercent;
      return '[Halves:First:${move(a1.speed)},HR${_int(a1.hr)};'
          'Second:${move(a2.speed)},HR${_int(a2.hr)}'
          '${drift == null ? '' : ',Decoupling:${drift >= 0 ? '+' : ''}${_dec(drift)}%'}]';
    } catch (_) {
      return null;
    }
  }

  /// The sessions around the activity one by one: two weeks before, three
  /// days after, and the last five of the same sport, so the coach sees the
  /// pattern, not only totals.
  static List<String> _aroundLines(
    ActivityView activity,
    List<ActivityView> all,
  ) {
    final anchor = activity.startDate;
    final day = DateTime(anchor.year, anchor.month, anchor.day);
    String line(ActivityView a) {
      final d = DateTime(a.startDate.year, a.startDate.month, a.startDate.day);
      final offset = d.difference(day).inDays;
      return '- [D:${_date(a.startDate)} ${_weekday(a.startDate)}'
          '(${offset >= 0 ? '+' : ''}$offset),Sport:${_sport(a.type)},${_stats(a)}]';
    }

    final others = [
      for (final a in all)
        if (a.activityId != activity.activityId) a,
    ]..sort((a, b) => a.startDate.compareTo(b.startDate));
    final around = [
      for (final a in others)
        if (!a.startDate.isBefore(day.subtract(const Duration(days: 14))) &&
            a.startDate.isBefore(day.add(const Duration(days: 4))))
          a,
    ];
    final sport = _sport(activity.type);
    final sameBefore = [
      for (final a in others)
        if (_sport(a.type) == sport && a.startDate.isBefore(anchor)) a,
    ];
    final lastSame = sameBefore.sublist(math.max(0, sameBefore.length - 5));
    return [
      '[Around:14dBefore..3dAfter,N:${around.length}]',
      for (final a in around.take(30)) line(a),
      if (lastSame.isNotEmpty) ...[
        '[SameSport:$sport:Last${lastSame.length}Before]',
        for (final a in lastSame) line(a),
      ],
    ];
  }

  static String _stats(ActivityView a) {
    final km = (a.distanceMeters ?? 0) / 1000;
    final moving = a.movingDurationSeconds ?? a.durationSeconds;
    return [
      'Min:${_int(a.durationSeconds / 60)}',
      if (km > 0) 'Km:${_dec(km)}',
      if (km > 0) _speedPart(_sport(a.type), km, moving).replaceFirst(',', ''),
      if (a.avgHeartRate != null) 'AvgHR:${_int(a.avgHeartRate)}',
      if (a.maxHeartRate != null) 'MaxHR:${_int(a.maxHeartRate)}',
      'Load:${_int(effectiveLoad(a))}',
      if ((a.totalElevation ?? 0) > 0) 'ElevM:${_int(a.totalElevation)}',
      if (a.avgWatts != null) 'AvgW:${_int(a.avgWatts)}',
      if (a.aerobicTrainingEffect != null)
        'TE:${_dec(a.aerobicTrainingEffect)}/${_dec(a.anaerobicTrainingEffect)}',
    ].where((s) => s.isNotEmpty).join(',');
  }

  /// Pace for running/walking/hiking, speed otherwise; ',' prefixed.
  static String _speedPart(String sport, double km, int seconds) {
    if (km <= 0 || seconds <= 0) return '';
    if (sport == 'run' || sport == 'walk' || sport == 'hike') {
      final secPerKm = (seconds / km).round();
      return ',Pace:${secPerKm ~/ 60}:${(secPerKm % 60).toString().padLeft(2, '0')}/km';
    }
    return ',Kmh:${_dec(km / (seconds / 3600))}';
  }

  static Map<String, List<ActivityView>> _groupBySport(
    List<ActivityView> list,
  ) {
    final map = <String, List<ActivityView>>{};
    for (final a in list) {
      map.putIfAbsent(_sport(a.type), () => []).add(a);
    }
    final entries = map.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return Map.fromEntries(entries);
  }

  static String _sport(String type) {
    final t = type.toLowerCase();
    if (t.contains('run')) return 'run';
    if (t.contains('cycl') || t.contains('bik') || t.contains('ride')) {
      return 'ride';
    }
    if (t.contains('swim')) return 'swim';
    if (t.contains('walk')) return 'walk';
    if (t.contains('hik')) return 'hike';
    if (t.contains('strength') || t.contains('weight')) return 'strength';
    if (t.contains('ski')) return 'ski';
    if (t.contains('row')) return 'row';
    if (t.contains('yoga') || t.contains('mobility')) return 'mobility';
    return t.replaceAll('_', ' ');
  }

  static double? _avg(Iterable<double?> values) {
    final v = values.whereType<double>().toList();
    return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  }

  static const _monthNames = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _weekday(DateTime d) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];

  /// A whole number, or `na`.
  static String formatInt(num? v) => _int(v);

  /// One decimal, or `na`.
  static String formatDecimal(num? v) => _dec(v);

  static String _int(num? v) =>
      v == null || !v.isFinite ? 'na' : v.round().toString();

  static String _dec(num? v) =>
      v == null || !v.isFinite ? 'na' : v.toStringAsFixed(1);
}

class _Totals {
  _Totals(this.n, this.hours, this.km, this.load, this.movingSeconds);

  factory _Totals.of(List<ActivityView> list) {
    var seconds = 0, moving = 0;
    var km = 0.0, load = 0.0;
    for (final a in list) {
      seconds += a.durationSeconds;
      moving += a.movingDurationSeconds ?? a.durationSeconds;
      km += (a.distanceMeters ?? 0) / 1000;
      load += effectiveLoad(a);
    }
    return _Totals(list.length, seconds / 3600, km, load, moving);
  }

  final int n;
  final double hours, km, load;
  final int movingSeconds;
}

/// One TOON line with the overnight HRV around an activity, the change
/// already worked out. The watch measures overnight HRV differently from the
/// chest strap, so this line carries no spot readings: those come from the
/// shared pair assessment on their own line.
String hrvAroundLine({
  required DateTime start,
  required DateTime end,
  double? preNight,
  DateTime? preDate,
  double? weeklyAverage,
  double? postNight,
  DateTime? postDate,
}) {
  String date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String ms(double v) => '${v.round()}ms';
  String change(double from, double to) {
    final d = (to - from).round();
    final pct = from > 0 ? ((to - from) / from * 100).round() : null;
    return '${d >= 0 ? '+' : '-'}${d.abs()}ms${pct == null ? '' : '(${pct >= 0 ? '+' : '-'}${pct.abs()}%)'}';
  }

  final parts = <String>[
    if (preNight != null && preDate != null)
      'PreNight:${ms(preNight)}(${date(preDate)})',
    if (postNight != null && postDate != null)
      'PostNight:${ms(postNight)}(${date(postDate)})',
    if (preNight != null && postNight != null)
      'NightChange:${change(preNight, postNight)}',
    if (weeklyAverage != null) 'WeeklyAvg:${ms(weeklyAverage)}',
  ];
  if (parts.isEmpty) return '[HRV:AroundActivity,Unavailable]';
  return '[HRV:AroundActivity,${parts.join(',')},Note:NightValuesAreWatchMeasuredNotComparableToSpotRMSSD]';
}
