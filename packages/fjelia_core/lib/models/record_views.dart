/// Read-only views of stored records the AI Coach context reads. The app's
/// database rows implement them.
library;

/// An absence the athlete entered: illness, injury, holiday or off-season.
abstract interface class AbsenceView {
  DateTime get startDay;
  DateTime get endDay;
  String get kind;
}

/// A workout scheduled on the athlete's watch platform.
abstract interface class ScheduledWorkoutView {
  String get workoutId;
  String get scheduleId;
  DateTime get scheduledDate;
  String get sportType;
  String? get stepsJson;
  int? get estimatedDurationSeconds;
  double? get estimatedDistanceMeters;
}

/// A blood-pressure reading.
abstract interface class BpMeasurementView {
  DateTime get measuredAt;
  int get systolic;
  int get diastolic;
  int get heartRate;
}

/// A smart-scale reading.
abstract interface class BodyCompositionView {
  DateTime get measuredAt;
  double? get weight;
  double? get bmi;
  double? get bodyFat;
  double? get bodyWater;
  double? get muscleMass;
  double? get visceralFat;
  double? get bmr;
  double? get bodyAge;
}

/// The day's scores.
abstract interface class DayScoreView {
  DateTime get date;
  double? get readinessScore;
  double? get recoveryScore;
  String? get recoveryLevel;
  double? get sleepScore;
  double? get strainScore;
  double? get bpScore;
}

/// A grip-strength measurement.
abstract interface class GripStrengthView {
  DateTime get measuredAt;
  double? get leftKg;
  double? get rightKg;
}

/// A lactate-threshold result.
abstract interface class ThresholdTestView {
  DateTime get date;
  String get source;
  int? get lt1Bpm;
  int? get lt2Bpm;
  int? get lt2PaceSec;
  int? get vo2PaceSec;
}

/// A stored morning readiness result.
abstract interface class ReadinessRecordView {
  String get level;
  int get flagCount;
  bool get flagHrv;
  bool get flagHr;
  bool get flagSleep;
  bool get flagBattery;
  bool get flagSkinTemp;
  bool get flagFatigue;
}

/// The day's heat-acclimation state.
abstract interface class HeatStateView {
  double get score;
  String get status;
  String? get recommendation;
}
