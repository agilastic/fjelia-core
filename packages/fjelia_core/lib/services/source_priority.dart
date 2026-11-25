/// Which sources win when several deliver the same kind of data.
library;

/// Which kind of data a priority list applies to.
enum SourceGroup { sleep, activity, body }

const defaultSourcePriorities = <String, List<String>>{
  'sleep': [
    'health_connect',
    'aktiia',
    'hilo_ble',
    'garmin_api',
    'coros',
    'polar',
    'suunto',
    'fjelia_ecg',
  ],
  'activity': [
    'garmin_api',
    'coros',
    'polar',
    'suunto',
    'mywhoosh',
    'health_connect',
  ],
  'body': [
    'health_connect',
    'garmin_api',
    'renpho',
    'coros',
    'polar',
    'suunto',
  ],
};

/// Whether data from [incoming] may replace data stored from [existing].
/// Earlier in [priority] wins; unknown incoming sources never overwrite.
bool shouldOverwrite(String? existing, String incoming, List<String> priority) {
  if (existing == null || existing.isEmpty) return true;
  if (existing == incoming) return true;
  final existingIdx = priority.indexOf(existing);
  final incomingIdx = priority.indexOf(incoming);
  if (incomingIdx == -1) return false;
  if (existingIdx == -1) return true;
  return incomingIdx < existingIdx;
}
