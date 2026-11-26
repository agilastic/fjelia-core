/// `21.1 km`, or `174 km` from 100 km on.
String formatKm(double meters) =>
    '${(meters / 1000).toStringAsFixed(meters >= 100000 ? 0 : 1)} km';
