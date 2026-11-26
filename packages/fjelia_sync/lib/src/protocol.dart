import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fjelia's own port, next to LocalSend's 53317 but not shared with it.
const defaultSyncPort = 53320;

const pairPath = '/v1/pair';
const cursorPath = '/v1/cursor';
const changesPath = '/v1/changes';
const wantedPath = '/v1/wanted';
const extraPath = '/v1/extra';

const deviceHeader = 'x-fjelia-device';

/// The Bonjour (DNS-SD) type a listening device advertises. Its TXT record
/// carries [bonjourDeviceKey], the device id, so a phone finds the one it
/// paired with whatever its address is now.
const bonjourServiceType = '_fjelia-sync._tcp';
const bonjourDeviceKey = 'id';

/// Finds a paired device on the local network. The apps implement it with
/// their platform's service discovery.
abstract interface class PeerLocator {
  /// `host:port` of the device [deviceId], or null when it is not found
  /// in time.
  Future<String?> locate(String deviceId);
}

/// Why a peer refused a request.
class SyncRefused implements Exception {
  const SyncRefused(this.status, this.reason);

  final int status;

  /// `token`, `unknown_device`, `schema` or `bad_request`.
  final String reason;

  @override
  String toString() => 'SyncRefused($status, $reason)';
}

/// The body of [request], gunzipped when sent compressed, at most
/// [maxBytes] once decoded.
Future<Object?> readJson(HttpRequest request, {required int maxBytes}) async {
  var body = request.cast<List<int>>();
  if (request.headers.value(HttpHeaders.contentEncodingHeader) == 'gzip') {
    body = body.transform(gzip.decoder);
  }
  final bytes = <int>[];
  await for (final chunk in body) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) throw const FormatException('too large');
  }
  return jsonDecode(utf8.decode(bytes));
}

Future<void> writeJson(HttpResponse response, int status, Object body) async {
  response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await response.close();
}
