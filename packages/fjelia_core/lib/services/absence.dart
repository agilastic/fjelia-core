import '../models/record_views.dart';

/// The absence that covers [day], if any.
T? absenceOn<T extends AbsenceView>(Iterable<T> absences, DateTime day) {
  final d = DateTime(day.year, day.month, day.day);
  for (final a in absences) {
    if (!d.isBefore(a.startDay) && !d.isAfter(a.endDay)) return a;
  }
  return null;
}
