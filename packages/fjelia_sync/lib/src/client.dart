import 'dart:async';
import 'dart:convert';
import 'dart:developer' show log;
import 'dart:io';

import 'package:fjelia_core/services/sync/pairing.dart';
import 'package:fjelia_core/services/sync/sync_tables.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/sync.dart';

import 'identity.dart';
import 'protocol.dart';

/// The connecting side: the phone. It pairs by a scanned code and sends its
/// changes to the paired device.
class SyncClient {
  SyncClient({
    required this.db,
    required this.identity,
    required this.name,
    required this.secrets,
    this.pageSize = 200,
    this.timeout = const Duration(seconds: 4),
    this.locator,
  });

  final AppDatabase db;
  final DeviceIdentity identity;
  final String name;
  final SecretStore secrets;
  final int pageSize;
  final Duration timeout;

  /// Finds a paired device whose address changed, such as by Bonjour.
  final PeerLocator? locator;

  static String _secretKey(String deviceId) => 'fjelia.sync.secret.$deviceId';

  /// Pairs with the device that showed [offer], trying its addresses in
  /// order. Only a device with the code's certificate is accepted.
  Future<SyncPeer> pair(PairingOffer offer) async {
    Object? lastError;
    for (final host in offer.hosts) {
      final client = _client(offer.fingerprint);
      try {
        final body = await _send(
          client,
          'POST',
          Uri(scheme: 'https', host: host, port: offer.port, path: pairPath),
          {
            'token': offer.token,
            'device': {
              'id': identity.deviceId,
              'name': name,
              'fingerprint': identity.fingerprint,
            },
          },
        );
        final device = body['device'] as Map;
        if (device['id'] != offer.deviceId) {
          throw const SyncRefused(403, 'unknown_device');
        }
        await secrets.write(
          _secretKey(offer.deviceId),
          body['secret'] as String,
        );
        final peer = SyncPeer(
          deviceId: offer.deviceId,
          name: device['name'] as String,
          fingerprint: offer.fingerprint,
          pairedAt: DateTime.now(),
          categories: {...SyncCategory.values}..remove(SyncCategory.coach),
          address: '$host:${offer.port}',
        );
        await db.saveSyncPeer(peer);
        return peer;
      } on SyncRefused {
        rethrow; // the device answered: another address will not help
      } on Object catch (e) {
        lastError = e;
      } finally {
        client.close(force: true);
      }
    }
    throw lastError ?? StateError('no address');
  }

  /// Sends [peer] every change it does not have yet and returns how many.
  /// [onPage] reports the number sent so far. When the peer is not at its
  /// last address any more, [locator] finds it by its device id and the new
  /// address is kept.
  Future<int> push(SyncPeer peer, {void Function(int sent)? onPage}) async {
    final secret = await secrets.read(_secretKey(peer.deviceId));
    if (secret == null) throw const SyncRefused(401, 'unknown_device');
    final known = peer.address;
    if (known != null) {
      try {
        return await _pushTo(known, peer, secret, onPage);
      } on SyncRefused {
        rethrow; // the peer answered
      } on Object catch (e) {
        if (locator == null) rethrow;
        log('[Sync] ${peer.name} not at $known ($e), looking for it');
      }
    }
    final found = await locator?.locate(peer.deviceId);
    if (found == null || found == known) {
      throw SocketException('${peer.name} is not on this network');
    }
    await db.setSyncPeerAddress(peer.deviceId, found);
    return _pushTo(found, peer, secret, onPage);
  }

  Future<int> _pushTo(
    String address,
    SyncPeer peer,
    String secret,
    void Function(int sent)? onPage,
  ) async {
    final base = Uri.parse('https://$address');
    final client = _client(peer.fingerprint);
    final headers = {
      deviceHeader: identity.deviceId,
      HttpHeaders.authorizationHeader: 'Bearer $secret',
    };
    try {
      final epoch = await db.syncLogEpoch();
      final cursor = await _send(
        client,
        'GET',
        base.replace(path: cursorPath),
        null,
        headers,
      );
      if (cursor['schema'] != db.schemaVersion) {
        throw const SyncRefused(409, 'schema');
      }
      var from = cursor['epoch'] == epoch ? cursor['seq'] as int : 0;
      var sent = 0;
      while (true) {
        final page = await db.syncChangesSince(
          from,
          limit: pageSize,
          categories: peer.categories,
        );
        if (page.isEmpty) return sent;
        await _send(client, 'POST', base.replace(path: changesPath), {
          'schema': db.schemaVersion,
          'epoch': epoch,
          'from': from,
          'changes': [for (final c in page) c.toJson()],
        }, headers);
        from = page.last.seq;
        sent += page.length;
        onPage?.call(sent);
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Ends the pairing on both devices; this device forgets it even when the
  /// other one cannot be reached.
  Future<void> unpair(SyncPeer peer) async {
    final secret = await secrets.read(_secretKey(peer.deviceId));
    final client = _client(peer.fingerprint);
    try {
      if (secret != null && peer.address != null) {
        await _send(
          client,
          'DELETE',
          Uri.parse('https://${peer.address}$pairPath'),
          null,
          {
            deviceHeader: identity.deviceId,
            HttpHeaders.authorizationHeader: 'Bearer $secret',
          },
        );
      }
    } on Object {
      // Unreachable: the other device keeps a pairing it can remove itself.
    } finally {
      client.close(force: true);
      await secrets.delete(_secretKey(peer.deviceId));
      await db.removeSyncPeer(peer.deviceId);
    }
  }

  /// A client that trusts exactly the certificate with [fingerprint].
  HttpClient _client(String fingerprint) =>
      HttpClient(context: SecurityContext(withTrustedRoots: false))
        ..connectionTimeout = timeout
        ..badCertificateCallback = (cert, host, port) =>
            fingerprintOfDer(cert.der) == fingerprint;

  Future<Map<String, Object?>> _send(
    HttpClient client,
    String method,
    Uri uri,
    Object? body, [
    Map<String, String> headers = const {},
  ]) async {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.contentEncodingHeader, 'gzip');
      request.add(gzip.encode(utf8.encode(jsonEncode(body))));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    final json = text.isEmpty
        ? <String, Object?>{}
        : (jsonDecode(text) as Map).cast<String, Object?>();
    if (response.statusCode != 200) {
      throw SyncRefused(
        response.statusCode,
        json['error'] as String? ?? 'bad_request',
      );
    }
    return json;
  }
}
