/// The public race library at races.fjelia.com, the same on the phone and
/// the computer. fjelia_core does no network I/O, so each app hands in how
/// to fetch a page; everything else is here.
library;

import 'dart:async';
import 'dart:convert';

/// The library's address.
final raceLibraryBase = Uri.parse('https://races.fjelia.com');

/// Fetches [url] and gives the body when the answer is 200, else null. The
/// app's HTTP client in a line.
typedef RaceLibraryFetch = Future<({int status, List<int> body})> Function(
  Uri url,
);

/// Typeahead for race names, an edition's distances, and a distance's
/// course GPX. Only the typed text goes out; nothing about the user. Any
/// failure gives nothing, so entering a race or a GPX file by hand always
/// works.
class RaceLibrary {
  RaceLibrary(this._fetch, {Uri? base}) : _base = base ?? raceLibraryBase;

  final RaceLibraryFetch _fetch;
  final Uri _base;
  static const _timeout = Duration(seconds: 8);

  /// Races whose name or town matches [query]; empty under 3 characters.
  Future<List<RaceHit>> search(String query) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final json = await _json('/v1/search', {
      'q': q.length > 80 ? q.substring(0, 80) : q,
      'limit': '8',
    });
    return json == null ? const [] : parseRaceHits(json);
  }

  /// The edition's races (distances), longest first; null when unavailable.
  Future<RaceEdition?> edition(String id) async {
    final json = await _json('/v1/editions/${Uri.encodeComponent(id)}', {});
    return json == null ? null : parseRaceEdition(json);
  }

  /// The course GPX of [race], or null when the library has none or it
  /// cannot be fetched. The library forwards to the organiser's file.
  Future<String?> courseGpx(RaceDistance race) async {
    final path = race.gpxPath;
    if (path == null) return null;
    final body = await _get(_base.resolve(path), const Duration(seconds: 30));
    return body == null ? null : utf8.decode(body, allowMalformed: true);
  }

  Future<Map<String, dynamic>?> _json(
    String path,
    Map<String, String> query,
  ) async {
    final body = await _get(
      _base.replace(path: path, queryParameters: query),
      _timeout,
    );
    if (body == null) return null;
    try {
      final json = jsonDecode(utf8.decode(body));
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    }
  }

  Future<List<int>?> _get(Uri url, Duration timeout) async {
    try {
      final r = await _fetch(url).timeout(timeout);
      return r.status == 200 ? r.body : null;
    } on Object {
      return null;
    }
  }
}

/// A search hit with its next (or latest) edition.
class RaceHit {
  const RaceHit({
    required this.eventId,
    required this.title,
    required this.sport,
    this.place,
    this.editionId,
    this.date,
    this.upcoming = false,
    this.distancesKm = const [],
    this.maxGainM,
  });

  final String eventId;

  /// "Name – Town".
  final String title;

  /// The app's sport id (`running`, `trail_running`, …), null when unknown.
  final String? sport;
  final String? place;
  final String? editionId;
  final DateTime? date;
  final bool upcoming;
  final List<double> distancesKm;
  final int? maxGainM;
}

class RaceEdition {
  const RaceEdition({
    required this.title,
    required this.date,
    required this.races,
    this.sport,
    this.sourceName,
    this.website,
  });

  final String title;
  final DateTime date;
  final String? sport;
  final List<RaceDistance> races;

  /// Where the facts come from, shown with them.
  final String? sourceName;
  final String? website;
}

class RaceDistance {
  const RaceDistance({
    required this.distanceKm,
    this.id,
    this.name,
    this.elevationGainM,
    this.sport,
    this.startAt,
    this.gpxPath,
    this.aidStations = const [],
  });

  /// The race's id in the library, for its course.
  final String? id;
  final String? name;
  final double distanceKm;
  final int? elevationGainM;
  final String? sport;

  /// The start, when the organiser published it.
  final DateTime? startAt;

  /// Where the library serves the course GPX (a path on the library's
  /// host), when it has one.
  final String? gpxPath;

  /// The course's aid stations as the library gives them (`name`, `km`,
  /// `cutoff`).
  final List<Object?> aidStations;

  bool get hasCourse => gpxPath != null;
}

/// Library sport → the race goal editor's sport id.
String? appSport(Object? sport) => switch (sport) {
  'run' => 'running',
  'trail' => 'trail_running',
  'triathlon' => 'triathlon',
  'road_bike' || 'brevet' => 'cycling_road',
  'gravel' => 'cycling_gravel',
  'mtb' => 'cycling_mtb',
  _ => null,
};

List<RaceHit> parseRaceHits(Map<String, dynamic> json) => [
  for (final hit in (json['hits'] as List? ?? const []).whereType<Map>())
    if (hit['event_id'] is String)
      RaceHit(
        eventId: hit['event_id'] as String,
        title: '${hit['title'] ?? hit['name'] ?? ''}',
        sport: appSport(hit['sport']),
        place: hit['place'] as String?,
        editionId: (hit['next_edition'] as Map?)?['id'] as String?,
        date: DateTime.tryParse(
          '${(hit['next_edition'] as Map?)?['date_start']}',
        ),
        upcoming: (hit['next_edition'] as Map?)?['upcoming'] == true,
        distancesKm: [
          for (final km
              in ((hit['next_edition'] as Map?)?['distances_km'] as List? ??
                      const [])
                  .whereType<num>())
            km.toDouble(),
        ],
        maxGainM: ((hit['next_edition'] as Map?)?['max_gain_m'] as num?)
            ?.round(),
      ),
];

RaceEdition? parseRaceEdition(Map<String, dynamic> json) {
  final date = DateTime.tryParse('${json['date_start']}');
  final event = json['event'];
  if (date == null || event is! Map) return null;
  return RaceEdition(
    title: '${event['title'] ?? event['name'] ?? ''}',
    date: date,
    sport: appSport(event['sport']),
    sourceName: (json['source'] as Map?)?['name'] as String?,
    website: event['website'] as String?,
    races: [
      for (final race in (json['races'] as List? ?? const []).whereType<Map>())
        if (race['distance_km'] is num)
          RaceDistance(
            id: race['id'] as String?,
            name: race['name'] as String?,
            distanceKm: (race['distance_km'] as num).toDouble(),
            elevationGainM: (race['elevation_gain_m'] as num?)?.round(),
            sport: appSport(race['discipline']),
            startAt: DateTime.tryParse('${race['start_at']}'),
            gpxPath: (race['course'] as Map?)?['gpx_url'] as String?,
            aidStations:
                ((race['course'] as Map?)?['aid_stations'] as List?) ??
                const [],
          ),
    ],
  );
}
