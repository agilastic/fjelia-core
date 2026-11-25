/// The sport family of an activity or session, from its sport key.
library;

enum ActivityKind {
  running,
  cycling,
  swimming,
  strength,
  rowing,
  hiking,
  walking,
  yoga,
  other,
}

ActivityKind activityKind(String sport) {
  final key = sport.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (RegExp('strength|weight|functional|kraft|gym|crossfit').hasMatch(key)) {
    return ActivityKind.strength;
  }
  if (RegExp('row|rudern').hasMatch(key)) return ActivityKind.rowing;
  // 'virtual_ride' (Garmin), 'Ride' (Strava); not 'stride'.
  if (RegExp(r'cycl|bik|mtb|gravel|radfahr|(?<!st)ride$').hasMatch(key)) {
    return ActivityKind.cycling;
  }
  if (RegExp('swim|schwimm|pool').hasMatch(key)) return ActivityKind.swimming;
  if (RegExp('hik|wander').hasMatch(key)) return ActivityKind.hiking;
  if (RegExp('walk|gehen').hasMatch(key)) return ActivityKind.walking;
  if (RegExp('yoga|pilates|mobility').hasMatch(key)) return ActivityKind.yoga;
  if (RegExp('run|jog|lauf|trail|treadmill').hasMatch(key)) {
    return ActivityKind.running;
  }
  return ActivityKind.other;
}
