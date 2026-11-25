import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fjelia's own port, next to LocalSend's 53317 but not shared with it.
const defaultSyncPort = 53320;

const pairPath = '/v1/pair';
const cursorPath = '/v1/cursor';
const changesPath = '/v1/changes';

const deviceHeader = 'x-fjelia-device';

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
