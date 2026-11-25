import 'dart:convert';

/// Planned share of time per zone (fractions summing to 1).
List<double>? plannedZoneDistribution(String? json) {
  if (json == null) return null;
  final decoded = jsonDecode(json);
  List<double> values;
  if (decoded is List) {
    values = decoded.map((e) => (e as num).toDouble()).toList();
  } else if (decoded is Map) {
    values = [
      for (var i = 1; i <= 6; i++) ((decoded['z$i'] ?? 0) as num).toDouble(),
    ];
  } else {
    return null;
  }
  final sum = values.fold<double>(0.0, (a, b) => a + b);
  if (sum <= 0) return null;
  return values.map((v) => v / sum).toList();
}
