/// How a day's training compares with its plan, for colouring calendars.
library;

/// A planned session or an activity in the calendar. The bands are
/// [ExecutionScoring.verdict]'s, so every screen agrees with the score the
/// phone gave.
enum Compliance {
  /// Done within the planned duration's band.
  onTarget,

  /// Done, but clearly shorter or longer than planned.
  partly,

  /// Done, but far from the plan (less than 40 % of it).
  offPlan,

  /// Planned, the day is over and nothing was done.
  missed,

  /// Done without a plan.
  unplanned,

  /// Planned for today or later.
  upcoming;

  /// A planned session with [status] (`planned`, `adapted`, `completed`,
  /// `skipped`) and, when done, the stored execution [verdict]; [isPast]
  /// when its day is over.
  static Compliance ofSession({
    required String status,
    required bool isPast,
    String? verdict,
  }) {
    if (status == 'completed') {
      return switch (verdict) {
        'off_plan' => offPlan,
        'under' || 'over' => partly,
        _ => onTarget,
      };
    }
    if (status == 'skipped') return missed;
    return isPast ? missed : upcoming;
  }
}
