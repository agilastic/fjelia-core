/// Read-only views of stored plan sessions and activities. The app's
/// database rows implement them, so core logic reads rows without knowing
/// the database.
library;

/// A session in the training plan.
abstract interface class PlannedSessionView {
  String get id;
  DateTime get sessionDate;
  String get sport;
  String get sessionType;
  String get title;
  String get status;
  int get primaryZone;
  int get plannedDurationMin;
  int get plannedTrimp;
  int get sessionLevel;
  String? get stepsJson;
  String? get plannedZonesJson;
  bool get indoor;
  String? get sessionNotes;
  String? get paceRangesJson;
  String? get goalObjective;
  String? get sessionDateOriginal;
  int? get actualDurationMin;
  String? get adaptationTrigger;
  String? get garminAlternativeId;
  String? get garminWorkoutId;
  String get phase;
  String? get subType;
  bool get tspAdjusted;
}

/// A recorded activity.
abstract interface class ActivityView {
  String get activityId;
  String get name;
  String get type;
  String? get source;
  DateTime get startDate;
  int get durationSeconds;
  int? get movingDurationSeconds;
  double? get distanceMeters;
  double? get totalElevation;
  double? get avgHeartRate;
  double? get maxHeartRate;
  double? get avgWatts;
  double? get avgRunCadence;
  double? get trainingLoad;
  double? get aerobicTrainingEffect;
  double? get anaerobicTrainingEffect;
  double? get vo2maxActivity;
  int? get recoveryTimeSeconds;
  String? get activityFeedbackPhrase;
  String? get hrZonesJson;
  String? get gpxJson;
  String? get metricsJson;
  String? get plannedWorkoutName;
  int? get plannedDurationSeconds;
  double? get plannedDistanceMeters;
  String? get plannedStepsJson;
  String? get athleteNote;
  double? get calories;
  double? get maxSpeedMps;
}

/// A race or event goal.
abstract interface class RaceGoalView {
  String get id;
  String get name;
  String get primarySport;
  DateTime get raceDate;
  double get distanceM;
  double? get elevationM;
  int? get targetFinishSeconds;
  String get priority;
  String get participation;
  String? get ambition;
}

/// A workout in the template library.
abstract interface class WorkoutTemplateView {
  String get id;
  String get sport;
  String get sessionType;
  String? get subType;
  String get targetPhase;
  String get stepsJson;
  int get estimatedDurationMin;
  String get name;
  String get description;
  String? get coachingCues;
}
