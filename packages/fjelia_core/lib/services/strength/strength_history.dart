import '../../models/strength_workout.dart';

/// One recorded session of an exercise, as progression reads it.
class StrengthHistoryEntry {
  const StrengthHistoryEntry({
    required this.activityId,
    required this.date,
    required this.source,
    required this.sets,
    required this.stale,
    this.logRevision = 0,
  });
  final String activityId;

  /// Revision of the log the sets came from.
  final int logRevision;
  final DateTime date;
  final String? source;

  /// Recorded working sets, in order.
  final List<StrengthSetResult> sets;
  final bool stale;

  /// The load used in the working sets, when one load was used throughout.
  StrengthLoad? get commonLoad {
    final loads = sets.map((s) => s.load).toList();
    if (loads.isEmpty || loads.any((l) => l == null)) return null;
    final kg = loads.first!.kg;
    return loads.every((l) => (l!.kg - kg).abs() < 1e-9) ? loads.first : null;
  }
}
