/// Which tables travel between an athlete's devices, and how.
///
/// Every table of the database is named here exactly once: synced, kept on
/// the device, or held back for the coach phase. A table missing from all
/// three fails the database's sync test, so a new table needs a decision.
library;

/// What kind of data a change is. Pairing and, later, coach access are
/// granted per category.
enum SyncCategory {
  activities,
  plan,
  health,
  ecg,
  aiCoach,
  nutrition,
  media,
  coach,
}

/// How two devices' versions of one record are reconciled.
enum SyncMerge {
  /// Written once by its source and never edited elsewhere: the copy from the
  /// device that recorded it wins.
  appendOnly,

  /// Edited by the athlete on any device: the newer change wins.
  newestWins,
}

/// One synced table.
///
/// Rows are identified across devices by [key], the SQL columns of a natural
/// key. A table without one gets a permanent random sync id per row, kept
/// beside the table, because its integer [rowId] is numbered per device.
class SyncTable {
  const SyncTable(
    this.name,
    this.category, {
    this.key = const [],
    this.rowId,
    this.merge = SyncMerge.appendOnly,
    this.onRequest = false,
    this.localRefs = const {},
  });

  /// SQL table name.
  final String name;
  final SyncCategory category;

  /// SQL columns of the natural key.
  final List<String> key;

  /// The integer id column each device numbers itself, if the table has one.
  /// Its value never leaves the device.
  final String? rowId;
  final SyncMerge merge;

  /// Content that is listed everywhere but only sent when a device asks for
  /// it, such as ECG waveforms.
  final bool onRequest;

  /// Columns holding another table's device-numbered id, by that table's
  /// name. They travel as that row's sync id.
  final Map<String, String> localRefs;

  /// Whether rows are identified by a generated sync id.
  bool get hasSyncId => key.isEmpty;
}

const _a = SyncCategory.activities;
const _p = SyncCategory.plan;
const _h = SyncCategory.health;
const _edited = SyncMerge.newestWins;

/// The tables that sync, in an order that applies referenced rows first.
const syncTables = <SyncTable>[
  // Health
  SyncTable(
    'summary_metric_origins',
    _h,
    key: ['summary_table', 'date', 'metric'],
  ),
  SyncTable('bp_measurements', _h, rowId: 'id'),
  SyncTable('daily_bp_summaries', _h, rowId: 'id'),
  SyncTable('hrv_records', _h, rowId: 'id'),
  SyncTable('sleep_records', _h, rowId: 'id'),
  SyncTable('wellness_records', _h, rowId: 'id'),
  SyncTable('renpho_records', _h, key: ['measured_at'], rowId: 'id'),
  SyncTable('day_score_records', _h, key: ['date'], rowId: 'id'),
  SyncTable('spot_hrv_measurements', _h, rowId: 'id'),
  SyncTable('grip_strength_records', _h, rowId: 'id'),
  SyncTable('waist_measurements', _h, rowId: 'id'),
  SyncTable('ocr_measurements', _h, rowId: 'id'),
  SyncTable('heat_daily_state_records', _h, key: ['date'], rowId: 'id'),
  SyncTable('threshold_records', _h, rowId: 'id'),
  SyncTable('hr_zone_definitions', _h, rowId: 'id', merge: _edited),
  SyncTable('athlete_thresholds', _h, key: ['athlete_id'], merge: _edited),
  SyncTable('daily_readiness_records', _h, key: ['id']),
  SyncTable('hrv_training_episodes', _h, key: ['episode_id']),
  SyncTable(
    'hrv_episode_aliases',
    _h,
    key: ['athlete_id', 'source', 'source_activity_id'],
  ),
  SyncTable('hrv_episode_measurements', _h, rowId: 'link_id'),
  SyncTable('hrv_episode_feedback', _h, key: ['feedback_uid'], merge: _edited),
  // ECG: the recording everywhere, its waveform on request.
  SyncTable('ecg_recordings', SyncCategory.ecg, key: ['recording_id']),
  SyncTable(
    'ecg_sample_chunks',
    SyncCategory.ecg,
    key: ['recording_id', 'sequence'],
    onRequest: true,
  ),
  // Activities
  SyncTable('activity_records', _a, key: ['activity_id'], rowId: 'id'),
  SyncTable('activity_titles', _a, key: ['activity_id'], merge: _edited),
  SyncTable('activity_sports', _a, key: ['activity_id'], merge: _edited),
  SyncTable('deleted_activities', _a, key: ['activity_id'], merge: _edited),
  SyncTable(
    'hr_zone_summaries',
    _a,
    key: ['activity_id'],
    localRefs: {'definition_id': 'hr_zone_definitions'},
  ),
  SyncTable('dfa_alpha1_results', _a, key: ['activity_id']),
  SyncTable('heat_workout_contexts', _a, key: ['activity_id'], rowId: 'id'),
  SyncTable('strength_activity_logs', _a, key: ['activity_id']),
  SyncTable('strength_performed_exercises', _a, key: ['id']),
  SyncTable('strength_performed_sets', _a, key: ['id']),
  // Plan
  SyncTable('race_goals', _p, key: ['id'], merge: _edited),
  SyncTable('training_plans', _p, key: ['id'], merge: _edited),
  SyncTable('plan_goals', _p, key: ['plan_id', 'goal_id'], merge: _edited),
  SyncTable('training_sessions', _p, key: ['id'], merge: _edited),
  SyncTable('session_actuals', _p, key: ['session_id'], merge: _edited),
  SyncTable('session_nts', _p, key: ['id'], merge: _edited),
  SyncTable('session_xp', _p, key: ['session_id'], merge: _edited),
  SyncTable('plan_adjustments', _p, key: ['id'], merge: _edited),
  SyncTable('session_adaptations', _p, key: ['id'], merge: _edited),
  SyncTable('week_summaries', _p, key: ['athlete_id', 'week_start']),
  SyncTable('workout_templates', _p, key: ['id'], merge: _edited),
  SyncTable('absences', _p, rowId: 'id', merge: _edited),
  SyncTable('scheduled_workout_records', _p, key: ['schedule_id'], rowId: 'id'),
  SyncTable('strength_exercise_variants', _p, key: ['id'], merge: _edited),
  SyncTable(
    'strength_equipment_increments',
    _p,
    key: ['context_key'],
    merge: _edited,
  ),
  SyncTable('strength_plan_revisions', _p, key: ['revision_id']),
  SyncTable(
    'strength_plan_heads',
    _p,
    key: ['owner_kind', 'owner_key'],
    merge: _edited,
  ),
  SyncTable(
    'strength_proposal_decisions',
    _p,
    key: ['fingerprint'],
    merge: _edited,
  ),
  SyncTable('strength_exercise_notes', _p, key: ['variant_id'], merge: _edited),
  // AI coach
  SyncTable(
    'coach_memories',
    SyncCategory.aiCoach,
    key: ['id'],
    merge: _edited,
  ),
  SyncTable('coach_messages', SyncCategory.aiCoach, rowId: 'id'),
  SyncTable('pro_reports', SyncCategory.aiCoach, key: ['id']),
  // Nutrition and media. Media files follow on request; the table lists them.
  SyncTable(
    'nutrition_records',
    SyncCategory.nutrition,
    key: ['record_key'],
    merge: _edited,
  ),
  SyncTable('media_items', SyncCategory.media, key: ['id'], merge: _edited),
  // Equipment: the athlete keeps it on any device.
  SyncTable('gear', _a, key: ['id'], merge: _edited),
  SyncTable('activity_gear', _a, key: ['activity_id'], merge: _edited),
];

/// Tables that stay on the device that wrote them: raw sensor streams,
/// recording checkpoints, caches, reminders and what was sent to which
/// watch platform.
const deviceOnlyTables = <String>{
  'heart_rate_samples',
  'indoor_recordings',
  'hrv_reminder_preferences',
  'hrv_post_reminders',
  'hrv_notification_operations',
  'hrv_notification_action_receipts',
  'hrv_native_cleanups',
  'provider_cleanups',
  'workout_deliveries',
  'weather_snapshot_records',
  'nutrition_reminder_records',
};

/// Coach tables. They sync with the coach phase, under the coach's own
/// rights, not between one athlete's devices.
const coachPhaseTables = <String>{
  'coach_profiles',
  'coach_athlete_relations',
  'coach_notes',
  'coach_reviews',
};

/// The synced table named [name], or null.
SyncTable? syncTableNamed(String name) => _byName[name];

final _byName = {for (final t in syncTables) t.name: t};
