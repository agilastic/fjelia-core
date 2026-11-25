/// Read-only views of stored daily health data. The app's database rows
/// implement them, so core logic reads rows without knowing the database.
library;

/// One night's HRV and morning physiology.
abstract interface class HrvDayView {
  DateTime get date;
  double? get hrvLastNight;
  int? get restingHeartRate;
  double? get bodyBattery;
  double? get computedEnergie;
  double? get respirationRate;
  double? get skinTempDelta;
  double? get stressLevel;
  double? get spo2;
}

/// One night's sleep.
abstract interface class SleepNightView {
  DateTime get date;
  int get totalSleepSeconds;
  int get deepSleepSeconds;
  int get remSleepSeconds;
  double? get sleepScore;
  int? get sleepNeedSeconds;
}

/// One day's wellness summary.
abstract interface class WellnessDayView {
  DateTime get date;
  int? get steps;
  int? get activeCalories;
  double? get averageStress;
}
