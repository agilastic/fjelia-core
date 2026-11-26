import 'package:fjelia_core/services/race_library.dart';
import 'package:test/test.dart';

void main() {
  test('a race distance brings its course, start and aid stations', () {
    final e = parseRaceEdition({
      'date_start': '2026-08-28',
      'event': {'title': 'UTMB', 'sport': 'trail'},
      'races': [
        {
          'id': 'utmb-2026-utmb',
          'name': 'UTMB',
          'distance_km': 174,
          'elevation_gain_m': 10000,
          'discipline': 'trail',
          'start_at': '2026-08-28T18:00:00+02:00',
          'course': {
            'gpx_url': '/v1/races/utmb-2026-utmb/course.gpx',
            'aid_stations': [
              {'name': 'Les Houches', 'km': 7.9, 'cutoff': null},
            ],
          },
        },
        {'id': 'ocC', 'distance_km': 57},
      ],
    })!;
    final utmb = e.races.first;
    expect(utmb.id, 'utmb-2026-utmb');
    expect(utmb.hasCourse, isTrue);
    expect(utmb.startAt, DateTime.utc(2026, 8, 28, 16));
    expect(utmb.aidStations, hasLength(1));
    expect(
      raceLibraryBase.resolve(utmb.gpxPath!).toString(),
      'https://races.fjelia.com/v1/races/utmb-2026-utmb/course.gpx',
    );
    expect(e.races.last.hasCourse, isFalse);
  });
}
