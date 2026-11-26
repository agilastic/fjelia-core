import 'dart:math' as math;

/// Great-circle distance in metres between two points in degrees
/// (haversine, mean earth radius). The one place Fjelia computes it.
double greatCircleMeters(double lat1, double lng1, double lat2, double lng2) {
  const radius = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLng / 2), 2);
  return 2 * radius * math.asin(math.sqrt(a.clamp(0, 1)));
}
