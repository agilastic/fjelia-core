import 'package:fjelia_core/services/compliance.dart';
import 'package:fjelia_core/services/readiness.dart';
import 'package:fjelia_core/services/training_form.dart';
import 'package:fjelia_data/database.dart';

import 'calendar.dart';
import 'diary.dart';
import 'today.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Why a coach should look at an athlete.
enum AthleteAlert {
  /// Two or more sessions missed in the last seven days.
  missedSessions,

  /// Today's morning check says recover.
  redReadiness,

  /// Form is deep in fatigue.
  veryFatigued,

  /// Nothing recorded for more than four days.
  quiet,
}

/// One day of an athlete's roster row.
class RosterDay {
  const RosterDay(this.date, this.compliance);
  final DateTime date;

  /// How each of the day's sessions and activities went, or will.
  final List<Compliance> compliance;
}

/// One athlete in a coach's roster.
class AthleteSummary {
  const AthleteSummary({
    required this.name,
    required this.past,
    required this.ahead,
    required this.form,
    required this.formStatus,
    required this.alerts,
    this.readiness,
    this.lastActivity,
    this.latestNote,
    this.nextGoal,
  });

  final String name;

  /// The last seven days, oldest first, today last.
  final List<RosterDay> past;

  /// The next seven days.
  final List<RosterDay> ahead;
  final double form;
  final FormStatus formStatus;
  final ReadinessLevel? readiness;
  final DateTime? lastActivity;

  /// The newest thing the athlete wrote.
  final DiaryEntry? latestNote;
  final GoalView? nextGoal;
  final Set<AthleteAlert> alerts;

  int get missed => past
      .expand((d) => d.compliance)
      .where((c) => c == Compliance.missed)
      .length;
}

/// The roster row of the athlete whose data is in [db].
Future<AthleteSummary> loadAthleteSummary(
  AppDatabase db,
  String name, {
  DateTime? now,
}) async {
  final today = _day(now ?? DateTime.now());
  final from = DateTime(today.year, today.month, today.day - 6);
  final view = await loadCalendar(
    db,
    start: from,
    weeks: 2,
    focusStart: from,
    focusEnd: DateTime(today.year, today.month, today.day + 8),
    now: now,
  );
  final days = [
    for (final d in view.weeks.expand((w) => w.days))
      RosterDay(d.date, [
        for (final e in d.entries)
          ?switch (e) {
            SessionEntry(:final compliance) => compliance,
            ActivityEntry(:final compliance) => compliance,
            _ => null,
          },
      ]),
  ];
  final todayView = await loadToday(db, now: now);
  final notes = await loadDiary(db);
  final activities = todayView.recent;
  final last = activities.isEmpty ? null : activities.first.start;
  final past = days.take(7).toList();
  final missed = past
      .expand((d) => d.compliance)
      .where((c) => c == Compliance.missed)
      .length;
  final readiness = todayView.readiness?.level;
  final formStatus = todayView.load.status;
  return AthleteSummary(
    name: name,
    past: past,
    ahead: days.skip(7).take(7).toList(),
    form: todayView.load.tsb,
    formStatus: formStatus,
    readiness: readiness,
    lastActivity: last,
    latestNote: notes.isEmpty ? null : notes.first,
    nextGoal: todayView.nextGoal,
    alerts: {
      if (missed >= 2) AthleteAlert.missedSessions,
      if (readiness == ReadinessLevel.red) AthleteAlert.redReadiness,
      if (formStatus == FormStatus.veryFatigued) AthleteAlert.veryFatigued,
      if (last == null || today.difference(_day(last)).inDays > 4)
        AthleteAlert.quiet,
    },
  );
}
