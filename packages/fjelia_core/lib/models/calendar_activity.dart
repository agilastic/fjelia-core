class CalendarActivity {
  const CalendarActivity({
    required this.date,
    required this.sport,
    required this.title,
    required this.completed,
    this.phase,
    this.skipped = false,
    this.skipReason,
  });
  final DateTime date;
  final String sport, title;
  final bool completed;
  final String? phase;

  /// A planned session the athlete (or the readiness check) cancelled.
  final bool skipped;

  /// Why it was cancelled, when known.
  final String? skipReason;
}
