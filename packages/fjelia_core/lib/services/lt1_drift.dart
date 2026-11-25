import 'dart:convert';

/// Aerobic-threshold test: a steady hour at constant HR. If HR drifts less
/// than ~5 % between halves, the average HR is at or below LT1.
class Lt1DriftResult {
  const Lt1DriftResult({
    required this.lt1,
    required this.h1,
    required this.h2,
    required this.drift,
    required this.pace,
    required this.at,
    required this.activityId,
  });

  final int lt1;
  final int h1;
  final int h2;

  /// HR change second half vs first half, percent.
  final double drift;

  /// Seconds per km.
  final int? pace;
  final DateTime at;
  final String activityId;

  String? get lt1Pace {
    final p = pace;
    if (p == null) return null;
    return '${p ~/ 60}:${(p % 60).toString().padLeft(2, '0')}/km';
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    json['lt1'] = lt1;
    json['h1'] = h1;
    json['h2'] = h2;
    json['drift'] = drift;
    json['pace'] = pace;
    json['at'] = at.toIso8601String();
    json['aid'] = activityId;
    return json;
  }

  static Lt1DriftResult fromJson(Map<String, dynamic> json) => Lt1DriftResult(
    lt1: json['lt1'] as int,
    h1: json['h1'] as int,
    h2: json['h2'] as int,
    drift: (json['drift'] as num).toDouble(),
    pace: json['pace'] as int?,
    at: DateTime.parse(json['at'] as String),
    activityId: json['aid'] as String,
  );
}

/// The LT1 drift test: heart-rate drift over a steady run.
abstract final class Lt1DriftTest {
  /// Splits the first hour into two 30-minute halves and compares HR.
  static Lt1DriftResult? calculate(String metricsJson, String activityId) {
    final samples = (jsonDecode(metricsJson) as List)
        .cast<Map<String, dynamic>>();
    final firstHalf = <int>[];
    final secondHalf = <int>[];
    final firstDist = <double>[];
    final lastDist = <double>[];
    var t = 0.0;
    var prevD = 0.0;
    for (final s in samples) {
      final d = (s['d'] as num?)?.toDouble();
      final hr = (s['hr'] as num?)?.toInt();
      final spd = (s['spd'] as num?)?.toDouble();
      if (d == null || spd == null || spd <= 0.1) continue;
      t += (d - prevD).abs() / spd;
      prevD = d;
      if (hr == null || hr <= 0) continue;
      if (t < 1800.0) {
        firstHalf.add(hr);
        firstDist.add(d);
      } else if (t < 3600.0) {
        secondHalf.add(hr);
        lastDist.add(d);
      }
    }
    if (firstHalf.isEmpty || secondHalf.isEmpty) return null;

    final h1 = (firstHalf.reduce((a, b) => a + b) / firstHalf.length).round();
    final h2 = (secondHalf.reduce((a, b) => a + b) / secondHalf.length).round();
    final drift = (h2 - h1) / h1 * 100;
    final all = firstHalf + secondHalf;
    final lt1 = (all.reduce((a, b) => a + b) / all.length).round();

    final dist = lastDist.last - firstDist.first;
    final pace = dist > 0 ? (3600.0 / (dist / 1000.0)).round() : null;
    return Lt1DriftResult(
      lt1: lt1,
      h1: h1,
      h2: h2,
      drift: drift,
      pace: pace,
      at: DateTime.now(),
      activityId: activityId,
    );
  }
}
