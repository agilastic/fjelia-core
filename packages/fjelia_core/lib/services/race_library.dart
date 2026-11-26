/// The public race library at races.fjelia.com: what it answers, read the
/// same way on the phone and the computer. The apps fetch; this reads.
library;

/// The library's address.
final raceLibraryBase = Uri.parse('https://races.fjelia.com');

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
