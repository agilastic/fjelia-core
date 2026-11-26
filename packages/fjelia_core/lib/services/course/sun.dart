import 'dart:math' as math;

/// Sunrise and sunset by the NOAA solar position formulas (Meeus,
/// "Astronomical Algorithms"; NOAA Solar Calculator), accurate to about a
/// minute away from the poles: enough to say which part of a race runs in
/// the dark.
///
/// Returns the sunrise and sunset of the UTC [day] at [lat], [lng]
/// (degrees, east positive), as UTC times. Null sunrise and sunset with
/// [polar] set when the sun does not rise ([polar] = night) or does not
/// set ([polar] = day) that day.
({DateTime? rise, DateTime? set, Polar? polar}) sunTimes(
  DateTime day,
  double lat,
  double lng,
) {
  final date = DateTime.utc(day.year, day.month, day.day);
  // Julian century of noon that day.
  final jd = date.millisecondsSinceEpoch / 86400000 + 2440587.5 + 0.5;
  final t = (jd - 2451545) / 36525;
  final l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360;
  final m = 357.52911 + t * (35999.05029 - 0.0001537 * t);
  final e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
  double rad(double d) => d * math.pi / 180;
  double deg(double r) => r * 180 / math.pi;
  final c =
      math.sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
      math.sin(rad(2 * m)) * (0.019993 - 0.000101 * t) +
      math.sin(rad(3 * m)) * 0.000289;
  final trueLong = l0 + c;
  final omega = 125.04 - 1934.136 * t;
  final lambda = trueLong - 0.00569 - 0.00478 * math.sin(rad(omega));
  final eps0 =
      23 +
      (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60;
  final eps = eps0 + 0.00256 * math.cos(rad(omega));
  final decl = deg(math.asin(math.sin(rad(eps)) * math.sin(rad(lambda))));
  final y = math.pow(math.tan(rad(eps / 2)), 2);
  final eqTime =
      4 *
      deg(
        y * math.sin(2 * rad(l0)) -
            2 * e * math.sin(rad(m)) +
            4 * e * y * math.sin(rad(m)) * math.cos(2 * rad(l0)) -
            0.5 * y * y * math.sin(4 * rad(l0)) -
            1.25 * e * e * math.sin(2 * rad(m)),
      );
  // The sun's centre 0.833° below the horizon: refraction and its radius.
  final cosH =
      (math.cos(rad(90.833)) - math.sin(rad(lat)) * math.sin(rad(decl))) /
      (math.cos(rad(lat)) * math.cos(rad(decl)));
  if (cosH > 1) return (rise: null, set: null, polar: Polar.night);
  if (cosH < -1) return (rise: null, set: null, polar: Polar.day);
  final h = deg(math.acos(cosH));
  final noon = 720 - 4 * lng - eqTime; // minutes after 00:00 UTC
  DateTime at(double minutes) =>
      date.add(Duration(milliseconds: (minutes * 60000).round()));
  return (rise: at(noon - 4 * h), set: at(noon + 4 * h), polar: null);
}

enum Polar { day, night }

/// Whether the sun is down at [time] at [lat], [lng].
bool isDark(DateTime time, double lat, double lng) {
  final utc = time.toUtc();
  // The local day can start on the UTC day before or after; check all
  // three so a night that spans UTC midnight is found.
  for (final offset in const [-1, 0, 1]) {
    final s = sunTimes(utc.add(Duration(days: offset)), lat, lng);
    switch (s.polar) {
      case Polar.night:
        if (offset == 0) return true;
      case Polar.day:
        if (offset == 0) return false;
      case null:
        if (!utc.isBefore(s.rise!) && utc.isBefore(s.set!)) return false;
    }
  }
  return true;
}

/// Hours of darkness between [from] and [to], sampled every five minutes.
double darkHours(DateTime from, DateTime to, double lat, double lng) {
  const step = Duration(minutes: 5);
  var dark = 0;
  var samples = 0;
  for (var t = from; t.isBefore(to); t = t.add(step)) {
    samples++;
    if (isDark(t, lat, lng)) dark++;
  }
  if (samples == 0) return 0;
  return to.difference(from).inSeconds / 3600 * dark / samples;
}
