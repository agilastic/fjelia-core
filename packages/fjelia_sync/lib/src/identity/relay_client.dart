/// The relay's HTTP API (fjelia-service push-server relay.py).
library;

import 'dart:convert';
import 'dart:io';

import 'crypto.dart';
import 'person.dart';

/// One HTTP exchange: the status and the JSON answer (null when empty).
typedef RelayTransport = Future<(int, Object?)> Function(
  String method,
  Uri url,
  Object? body,
  Map<String, String> headers,
);

class RelayError implements Exception {
  RelayError(this.status, this.detail);
  final int status;
  final Object? detail;
  @override
  String toString() => 'relay $status: $detail';
}

class RelayClient {
  RelayClient(this.base, {RelayTransport? transport})
    : _send = transport ?? _http;

  static final defaultBase = Uri.parse('https://push.fjelia.com');

  final Uri base;
  final RelayTransport _send;
  String? _token;
  int _expires = 0;

  Future<Object?> _call(
    String method,
    String path, {
    Object? body,
    bool signedIn = false,
  }) async {
    final (status, answer) = await _send(method, base.resolve(path), body, {
      'content-type': 'application/json',
      if (signedIn && _token != null) 'authorization': 'Bearer $_token',
    });
    if (status >= 300) throw RelayError(status, answer);
    return answer;
  }

  Future<void> uploadList(Map<String, Object> signed) =>
      _call('POST', '/v1/relay/lists', body: signed);

  /// [person]'s latest signed list, or null when the relay has none.
  Future<Map<String, dynamic>?> list(String person) async {
    try {
      return await _call('GET', '/v1/relay/lists/$person')
          as Map<String, dynamic>;
    } on RelayError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// Signs this device in with its device key, unless still signed in.
  Future<void> signIn(PersonIdentity me) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_token != null && _expires > now + 60) return;
    final c =
        (await _call(
              'POST',
              '/v1/relay/challenge',
              body: {'device': me.deviceId},
            ) as Map)['challenge']
            as String;
    final s = await _call(
      'POST',
      '/v1/relay/session',
      body: {
        'device': me.deviceId,
        'challenge': c,
        'sig': base64.encode(
          me.deviceSign.sign(utf8.encode('fjelia relay v1 $c')),
        ),
      },
    ) as Map;
    _token = s['token'] as String;
    _expires = s['expires'] as int;
  }

  Future<void> send(Map<String, Object> envelope) =>
      _call('POST', '/v1/relay/envelopes', body: envelope, signedIn: true);

  /// Waiting envelopes after [after]: (id, envelope) pairs, and whether more
  /// wait.
  Future<({List<(int, Map<String, dynamic>)> envelopes, bool more})> fetch(
    int after,
  ) async {
    final a = await _call(
      'GET',
      '/v1/relay/envelopes?after=$after',
      signedIn: true,
    ) as Map;
    return (
      envelopes: [
        for (final e in a['envelopes'] as List)
          (e['id'] as int, e['envelope'] as Map<String, dynamic>),
      ],
      more: a['more'] == true,
    );
  }

  Future<void> ack(int upTo) => _call(
    'POST',
    '/v1/relay/envelopes/ack',
    body: {'up_to': upTo},
    signedIn: true,
  );
}

final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);

Future<(int, Object?)> _http(
  String method,
  Uri url,
  Object? body,
  Map<String, String> headers,
) async {
  final request = await _client.openUrl(method, url);
  headers.forEach(request.headers.set);
  if (body != null) request.write(jsonEncode(body));
  final response = await request.close().timeout(const Duration(seconds: 30));
  final text = await response.transform(utf8.decoder).join();
  return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
}

/// For callers that only need the id of a signed list.
String personOfList(Map<String, dynamic> signed) =>
    idOf(base64.decode((signed['list'] as Map)['person_key'] as String));
