import 'dart:convert';

import 'package:xml/xml.dart';

import '../../utils/geo.dart';
import 'race_plan.dart';

/// A point of a race course: where it is, how high, and how far along.
class CoursePoint {
  const CoursePoint(this.lat, this.lng, this.ele, this.distanceM);
  final double lat, lng;

  /// Metres above sea level; null where the file has no height.
  final double? ele;

  /// Metres from the start along the course.
  final double distanceM;

  List<num?> toJson() => [lat, lng, ele, distanceM];
  static CoursePoint fromJson(List j) => CoursePoint(
    (j[0] as num).toDouble(),
    (j[1] as num).toDouble(),
    (j[2] as num?)?.toDouble(),
    (j[3] as num).toDouble(),
  );
}

/// A checkpoint on the course: an aid station, a cut-off, the finish.
class CourseCheckpoint {
  const CourseCheckpoint({
    required this.name,
    required this.km,
    this.cutoff,
    this.aid = true,
  });
  final String name;
  final double km;

  /// When the checkpoint closes, where the race has a cut-off there.
  final DateTime? cutoff;

  /// Food and drink there; false for a timing point only.
  final bool aid;

  CourseCheckpoint copyWith({
    String? name,
    double? km,
    DateTime? Function()? cutoff,
    bool? aid,
  }) => CourseCheckpoint(
    name: name ?? this.name,
    km: km ?? this.km,
    cutoff: cutoff == null ? this.cutoff : cutoff(),
    aid: aid ?? this.aid,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'km': km,
    if (cutoff != null) 'cutoff': cutoff!.toUtc().toIso8601String(),
    if (!aid) 'aid': false,
  };
  static CourseCheckpoint fromJson(Map j) => CourseCheckpoint(
    name: '${j['name'] ?? ''}',
    km: (j['km'] as num).toDouble(),
    cutoff: DateTime.tryParse('${j['cutoff']}'),
    aid: j['aid'] != false,
  );
}

/// A race course: the track from a GPX file and its checkpoints.
class Course {
  const Course({
    required this.points,
    this.name,
    this.checkpoints = const [],
    this.settings = const RacePlanSettings(),
  });
  final String? name;
  final List<CoursePoint> points;
  final List<CourseCheckpoint> checkpoints;

  /// What the athlete expects of race day.
  final RacePlanSettings settings;

  double get distanceM => points.isEmpty ? 0 : points.last.distanceM;
  bool get hasElevation => points.any((p) => p.ele != null);

  Course withCheckpoints(List<CourseCheckpoint> c) => Course(
    points: points,
    name: name,
    checkpoints: [...c]..sort((a, b) => a.km.compareTo(b.km)),
    settings: settings,
  );

  Course withSettings(RacePlanSettings s) =>
      Course(points: points, name: name, checkpoints: checkpoints, settings: s);

  String toJson() => jsonEncode({
    'name': ?name,
    'points': [for (final p in points) p.toJson()],
    'checkpoints': [for (final c in checkpoints) c.toJson()],
    'plan': settings.toJson(),
  });

  static Course? fromJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map;
      return Course(
        name: j['name'] as String?,
        points: [
          for (final p in j['points'] as List) CoursePoint.fromJson(p as List),
        ],
        checkpoints: [
          for (final c in (j['checkpoints'] as List? ?? const []))
            CourseCheckpoint.fromJson(c as Map),
        ],
        settings: RacePlanSettings.fromJson(j['plan']),
      );
    } on Object {
      return null;
    }
  }
}

/// Reads a course from GPX: the track (or, without one, the route) and its
/// waypoints as checkpoints, placed where they lie closest to the track.
/// Timestamps are not needed. Null when the file has fewer than two points.
Course? parseCourseGpx(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException {
    return null;
  }
  Iterable<XmlElement> named(XmlNode n, String name) =>
      n.descendants.whereType<XmlElement>().where((e) => e.name.local == name);
  String? text(XmlElement parent, String name) => parent.childElements
      .where((e) => e.name.local == name)
      .firstOrNull
      ?.innerText
      .trim();
  (double, double)? position(XmlElement e) {
    final lat = double.tryParse(e.getAttribute('lat') ?? '');
    final lng = double.tryParse(e.getAttribute('lon') ?? '');
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
      return null;
    }
    return (lat, lng);
  }

  var raw = named(doc, 'trkpt').toList();
  if (raw.length < 2) raw = named(doc, 'rtept').toList();
  final points = <CoursePoint>[];
  for (final e in raw) {
    final p = position(e);
    if (p == null) continue;
    final ele = double.tryParse(text(e, 'ele') ?? '');
    final d = points.isEmpty
        ? 0.0
        : points.last.distanceM +
              greatCircleMeters(points.last.lat, points.last.lng, p.$1, p.$2);
    points.add(
      CoursePoint(p.$1, p.$2, ele != null && ele.isFinite ? ele : null, d),
    );
  }
  if (points.length < 2) return null;

  final checkpoints = <CourseCheckpoint>[];
  for (final w in named(doc, 'wpt')) {
    final p = position(w);
    if (p == null) continue;
    var best = points.first;
    var bestD = double.infinity;
    for (final q in points) {
      final d = greatCircleMeters(q.lat, q.lng, p.$1, p.$2);
      if (d < bestD) {
        bestD = d;
        best = q;
      }
    }
    // A waypoint far from the track is a landmark, not a checkpoint.
    if (bestD > 500) continue;
    checkpoints.add(
      CourseCheckpoint(
        name: text(w, 'name') ?? 'Checkpoint',
        km: (best.distanceM / 100).round() / 10,
      ),
    );
  }
  final meta = named(doc, 'metadata').firstOrNull;
  final trk = named(doc, 'trk').firstOrNull ?? named(doc, 'rte').firstOrNull;
  final name =
      (trk == null ? null : text(trk, 'name')) ??
      (meta == null ? null : text(meta, 'name'));
  return Course(
    name: name == null || name.isEmpty ? null : name,
    points: points,
    checkpoints: checkpoints..sort((a, b) => a.km.compareTo(b.km)),
  );
}
