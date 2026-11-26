/// The median of [values]: the middle value, or the mean of the two middle
/// values for an even count. Null for none. [values] is not changed.
double? median(Iterable<double> values) {
  final s = [...values]..sort();
  if (s.isEmpty) return null;
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// The value [fraction] of the way through [values] (0.95 for the 95th
/// percentile), by the nearest rank. Null for none. [values] is not
/// changed.
double? percentile(Iterable<double> values, double fraction) {
  final s = [...values]..sort();
  if (s.isEmpty) return null;
  return s[((s.length - 1) * fraction).round()];
}
