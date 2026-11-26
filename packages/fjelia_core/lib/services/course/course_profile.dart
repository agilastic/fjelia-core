import 'dart:math' as math;

import '../../utils/stats.dart';
import 'course.dart';

/// Metres between the points of the cleaned elevation profile.
const profileStepM = 10.0;

/// Half-width of the moving average that removes GPS and barometer jitter.
/// Fjelia's own setting: wide enough to flatten noise of a few metres,
/// narrow enough to keep short steep ramps.
const profileSmoothHalfM = 50.0;

/// A rise or fall counts once it exceeds this from the last turning point,
/// as in Fjelia's activity files (`parseGpx`).
const profileHysteresisM = 3.0;

/// Length over which a grade is measured for the gradient breakdown and the
/// steepest stretches.
const gradeWindowM = 100.0;

/// The grade bands of the breakdown, as fractions: [-∞, -0.2), [-0.2,
/// -0.1) … [0.2, ∞).
const gradeBandEdges = [-0.20, -0.10, -0.03, 0.03, 0.10, 0.20];

/// A climb or a descent of the course.
class CourseClimb {
  const CourseClimb({
    required this.startKm,
    required this.endKm,
    required this.metres,
    required this.steepest,
  });
  final double startKm, endKm;

  /// Height gained (or, for a descent, lost), positive.
  final double metres;

  /// Steepest 100 m within it, as a fraction, positive.
  final double steepest;

  double get km => endKm - startKm;

  /// Average grade as a fraction, positive.
  double get grade => km <= 0 ? 0 : metres / (km * 1000);
}

/// One point of the cleaned profile.
class ProfilePoint {
  const ProfilePoint(this.km, this.ele, this.grade);
  final double km, ele;

  /// Grade over the [gradeWindowM] ending here, as a fraction.
  final double grade;
}

/// Everything the course analysis shows, from fjelia_core so the phone and
/// the computer agree.
class CourseProfile {
  const CourseProfile({
    required this.distanceKm,
    required this.gain,
    required this.loss,
    required this.minEle,
    required this.maxEle,
    required this.profile,
    required this.bands,
    required this.climbs,
    required this.descents,
    required this.steepestUp,
    required this.steepestDown,
  });
  final double distanceKm, gain, loss, minEle, maxEle;
  final List<ProfilePoint> profile;

  /// Kilometres in each band of [gradeBandEdges], seven values.
  final List<double> bands;
  final List<CourseClimb> climbs, descents;

  /// The 95th percentile of the 100 m grades up and down, positive
  /// fractions: how steep the steep parts are, ignoring single spikes.
  final double steepestUp, steepestDown;

  /// ITRA's effort measure: kilometres plus one per 100 m of climbing.
  double get effortKm => distanceKm + gain / 100;
}

/// Cleans the elevation of [course] and describes it. Null without
/// elevation.
///
/// The profile is resampled every [profileStepM] along the course, smoothed
/// by a moving average of ±[profileSmoothHalfM], and gain and loss are
/// counted past a [profileHysteresisM] dead band. Climbs are rises of at
/// least [minClimbM] that do not drop back by more than a tenth of what
/// they gained (at least 10 m) on the way.
CourseProfile? analyseCourse(Course course, {double minClimbM = 50}) {
  final raw = [
    for (final p in course.points)
      if (p.ele != null) (d: p.distanceM, e: p.ele!),
  ];
  if (raw.length < 2) return null;
  final total = course.distanceM;
  // Resample by distance with linear interpolation.
  final n = (total / profileStepM).floor() + 1;
  final even = List<double>.filled(n, 0);
  var j = 0;
  for (var i = 0; i < n; i++) {
    final d = i * profileStepM;
    while (j < raw.length - 2 && raw[j + 1].d < d) {
      j++;
    }
    final a = raw[j], b = raw[math.min(j + 1, raw.length - 1)];
    final span = b.d - a.d;
    final t = span <= 0 ? 0.0 : ((d - a.d) / span).clamp(0.0, 1.0);
    even[i] = a.e + (b.e - a.e) * t;
  }
  // Moving average.
  final half = (profileSmoothHalfM / profileStepM).round();
  final smooth = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    var sum = 0.0;
    var count = 0;
    for (var k = math.max(0, i - half); k <= math.min(n - 1, i + half); k++) {
      sum += even[k];
      count++;
    }
    smooth[i] = sum / count;
  }
  // Gain and loss past the dead band.
  var gain = 0.0, loss = 0.0;
  var anchor = smooth.first;
  for (final e in smooth) {
    if (e - anchor >= profileHysteresisM) {
      gain += e - anchor;
      anchor = e;
    } else if (anchor - e >= profileHysteresisM) {
      loss += anchor - e;
      anchor = e;
    }
  }
  final w = (gradeWindowM / profileStepM).round();
  double gradeAt(int i) {
    final from = math.max(0, i - w);
    return i == from
        ? 0
        : (smooth[i] - smooth[from]) / ((i - from) * profileStepM);
  }

  final profile = [
    for (var i = 0; i < n; i++)
      ProfilePoint(i * profileStepM / 1000, smooth[i], gradeAt(i)),
  ];
  // Breakdown over whole windows.
  final bands = List<double>.filled(gradeBandEdges.length + 1, 0);
  final windowGrades = <double>[];
  for (var i = w; i < n; i += w) {
    final g = gradeAt(i);
    windowGrades.add(g);
    var band = 0;
    while (band < gradeBandEdges.length && g >= gradeBandEdges[band]) {
      band++;
    }
    bands[band] += gradeWindowM / 1000;
  }

  // Sliding 100 m grades for the steepest parts and per climb.
  final sliding = [for (var i = w; i < n; i++) gradeAt(i)];
  return CourseProfile(
    distanceKm: total / 1000,
    gain: gain,
    loss: loss,
    minEle: smooth.reduce(math.min),
    maxEle: smooth.reduce(math.max),
    profile: profile,
    bands: bands,
    climbs: _climbs(smooth, sliding, w, minClimbM, up: true),
    descents: _climbs(smooth, sliding, w, minClimbM, up: false),
    steepestUp:
        (percentile([
          for (final g in sliding)
            if (g > 0) g,
        ], 0.95) ??
        0),
    steepestDown:
        (percentile([
          for (final g in sliding)
            if (g < 0) -g,
        ], 0.95) ??
        0),
  );
}

List<CourseClimb> _climbs(
  List<double> ele,
  List<double> sliding,
  int w,
  double minClimbM, {
  required bool up,
}) {
  final s = up ? ele : [for (final e in ele) -e];
  final out = <CourseClimb>[];
  var low = 0, high = 0;
  void close() {
    // The climb starts where it leaves the low ground, not on the flat
    // before it.
    var start = low;
    for (var i = low; i < high; i++) {
      if (s[i] <= s[low] + profileHysteresisM) start = i;
    }
    low = start;
    final metres = s[high] - s[low];
    if (high > low && metres >= minClimbM) {
      var steepest = 0.0;
      for (var i = math.max(low + w, w); i <= high; i++) {
        final g = (up ? 1 : -1) * sliding[i - w];
        steepest = math.max(steepest, g);
      }
      out.add(
        CourseClimb(
          startKm: low * profileStepM / 1000,
          endKm: high * profileStepM / 1000,
          metres: metres,
          steepest: steepest,
        ),
      );
    }
  }

  for (var i = 1; i < s.length; i++) {
    if (s[i] > s[high]) high = i;
    final climbed = s[high] - s[low];
    final tolerance = math.max(10.0, climbed * 0.1);
    if (s[high] - s[i] > tolerance) {
      close();
      low = i;
      high = i;
    } else if (s[i] < s[low]) {
      // Below where it started: whatever rose before was no climb.
      low = i;
      high = i;
    }
  }
  close();
  return out;
}

/// `+8 %` or `−12 %` for a grade given as a fraction.
String formatGrade(double grade) =>
    '${grade >= 0 ? '+' : '−'}${(grade.abs() * 100).round()} %';

/// The colour of a grade as 0xAARRGGBB, the same on every screen: blue
/// going down steeply, green on the flat, red going up steeply, blended in
/// between.
int gradeArgb(double grade) {
  const stops = [
    (-0.20, 0xFF1E5BD8),
    (-0.08, 0xFF4FA8F0),
    (0.0, 0xFF34C759),
    (0.08, 0xFFFFB13D),
    (0.20, 0xFFE5383B),
  ];
  if (grade <= stops.first.$1) return stops.first.$2;
  if (grade >= stops.last.$1) return stops.last.$2;
  for (var i = 1; i < stops.length; i++) {
    if (grade <= stops[i].$1) {
      final t = (grade - stops[i - 1].$1) / (stops[i].$1 - stops[i - 1].$1);
      int channel(int shift) {
        final a = (stops[i - 1].$2 >> shift) & 0xFF;
        final b = (stops[i].$2 >> shift) & 0xFF;
        return (a + (b - a) * t).round();
      }

      return 0xFF000000 | channel(16) << 16 | channel(8) << 8 | channel(0);
    }
  }
  return stops.last.$2;
}
