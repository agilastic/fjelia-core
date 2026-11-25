import 'package:fjelia_data/database.dart';

/// Where a diary entry was written.
enum DiaryKind {
  /// The athlete's note on an activity.
  activity,

  /// A note on a planned session.
  session,

  /// How a workout felt (effort 1–10 and a note).
  feeling,

  /// A note to the AI coach.
  coachNote,

  /// The note on a time away (illness, injury, vacation).
  absence,

  /// The note on an ECG recording.
  ecg,
}

class DiaryEntry {
  const DiaryEntry({
    required this.at,
    required this.kind,
    required this.text,
    this.title,
    this.effort,
    this.activityId,
  });

  final DateTime at;
  final DiaryKind kind;
  final String text;

  /// What the note is about: the activity's or session's name.
  final String? title;

  /// Perceived effort, 1–10.
  final int? effort;

  /// The activity to open, when there is one.
  final String? activityId;
}

/// The athlete's own notes from everywhere in the app, newest first. With
/// [query], only those that contain it (in the note or what it is about);
/// with [kinds], only those kinds.
Future<List<DiaryEntry>> loadDiary(
  AppDatabase db, {
  String query = '',
  Set<DiaryKind> kinds = const {...DiaryKind.values},
}) async {
  final entries = <DiaryEntry>[];
  bool filled(String? s) => s != null && s.trim().isNotEmpty;

  if (kinds.contains(DiaryKind.activity)) {
    final a = db.activityRecords;
    for (final r
        in await (db.selectOnly(a)
              ..addColumns([a.activityId, a.name, a.startDate, a.athleteNote])
              ..where(a.athleteNote.isNotNull()))
            .get()) {
      final note = r.read(a.athleteNote);
      if (!filled(note)) continue;
      entries.add(
        DiaryEntry(
          at: r.read(a.startDate)!.toLocal(),
          kind: DiaryKind.activity,
          text: note!.trim(),
          title: r.read(a.name),
          activityId: r.read(a.activityId),
        ),
      );
    }
  }
  if (kinds.contains(DiaryKind.session)) {
    for (final s in await (db.select(
      db.trainingSessions,
    )..where((t) => t.athleteNotes.isNotNull())).get()) {
      if (!filled(s.athleteNotes)) continue;
      entries.add(
        DiaryEntry(
          at: s.sessionDate.toLocal(),
          kind: DiaryKind.session,
          text: s.athleteNotes!.trim(),
          title: s.title,
        ),
      );
    }
  }
  if (kinds.contains(DiaryKind.feeling)) {
    final episodes = {
      for (final e in await db.select(db.hrvTrainingEpisodes).get())
        e.episodeId: e.primaryActivityId,
    };
    for (final f in await db.select(db.hrvEpisodeFeedback).get()) {
      if (!filled(f.note) && f.rpe == null) continue;
      entries.add(
        DiaryEntry(
          at: f.recordedAtUtc.toLocal(),
          kind: DiaryKind.feeling,
          text: f.note?.trim() ?? '',
          effort: f.rpe,
          activityId: episodes[f.episodeId],
        ),
      );
    }
  }
  if (kinds.contains(DiaryKind.coachNote)) {
    for (final m in await db.select(db.coachMemories).get()) {
      if (!filled(m.body)) continue;
      entries.add(
        DiaryEntry(
          at: m.updatedAt.toLocal(),
          kind: DiaryKind.coachNote,
          text: m.body.trim(),
          title: m.title,
        ),
      );
    }
  }
  if (kinds.contains(DiaryKind.absence)) {
    for (final a in await db.select(db.absences).get()) {
      if (!filled(a.note)) continue;
      entries.add(
        DiaryEntry(
          at: a.startDay.toLocal(),
          kind: DiaryKind.absence,
          text: a.note!.trim(),
          title: a.kind,
        ),
      );
    }
  }
  if (kinds.contains(DiaryKind.ecg)) {
    for (final e in await (db.select(
      db.ecgRecordings,
    )..where((t) => t.note.isNotNull())).get()) {
      if (!filled(e.note)) continue;
      entries.add(
        DiaryEntry(
          at: e.recordedAt.toLocal(),
          kind: DiaryKind.ecg,
          text: e.note!.trim(),
          activityId: e.activityId,
        ),
      );
    }
  }

  final q = query.trim().toLowerCase();
  final kept = q.isEmpty
      ? entries
      : [
          for (final e in entries)
            if (e.text.toLowerCase().contains(q) ||
                (e.title?.toLowerCase().contains(q) ?? false))
              e,
        ];
  return kept..sort((a, b) => b.at.compareTo(a.at));
}
