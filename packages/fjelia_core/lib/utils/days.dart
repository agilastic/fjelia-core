/// Midnight at the start of [d]'s calendar day, in [d]'s time zone.
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whether [a] and [b] fall on the same calendar day.
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// [d]'s calendar day as `2026-11-27`.
String isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
