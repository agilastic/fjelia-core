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
  String? get plannedZonesJson;
  bool get indoor;
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
}
