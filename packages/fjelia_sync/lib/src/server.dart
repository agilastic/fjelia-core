import 'dart:async';
import 'dart:io';

import 'package:fjelia_core/services/sync/pairing.dart';
import 'package:fjelia_core/services/sync/sync_change.dart';
import 'package:fjelia_core/services/sync/sync_tables.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/sync.dart';

import 'identity.dart';
import 'protocol.dart';

/// Something a paired device did.
sealed class SyncEvent {
  const SyncEvent(this.peer);
  final SyncPeer peer;
}

class PeerPaired extends SyncEvent {
  const PeerPaired(super.peer);
}

class ChangesReceived extends SyncEvent {
  const ChangesReceived(super.peer, this.count);
  final int count;
}

class PeerUnpaired extends SyncEvent {
  const PeerUnpaired(super.peer);
}

/// The peer handed over its FjeliaPro pass.
class ProPassReceived extends SyncEvent {
  const ProPassReceived(super.peer);
}

/// The listening side: the desktop. It offers pairing codes, accepts the
/// devices that present one, and takes in their changes.
class SyncServer {
  SyncServer({
    required this.db,
    required this.identity,
    required this.name,
    this.port = defaultSyncPort,
    this.offerLifetime = const Duration(minutes: 5),
    this.databaseOf,
    this.wanted,
  });

  /// Content sent only on request that this device wants from [peer], by
  /// kind: `ecg` lists ECG recording ids whose waveforms to send. By
  /// default what was asked for in the peer's database (`syncWanted`).
  final Future<Map<String, List<String>>> Function(SyncPeer peer)? wanted;

  /// Where the paired devices are kept, and the data of the athlete's own
  /// devices.
  final AppDatabase db;

  /// The database a peer's data lives in; on a coach's computer each
  /// athlete has their own. Without it, everything is in [db].
  final AppDatabase Function(SyncPeer peer)? databaseOf;
  AppDatabase _dataOf(SyncPeer peer) => databaseOf?.call(peer) ?? db;
  final DeviceIdentity identity;
  final String name;
  final int port;
  final Duration offerLifetime;

  HttpServer? _server;
  String? _token;
  var _role = PeerRole.self;
  DateTime? _tokenExpires;
  final _events = StreamController<SyncEvent>.broadcast();

  Stream<SyncEvent> get events => _events.stream;

  /// The port actually bound, which differs from [port] when that was 0.
  int get boundPort => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      port,
      identity.serverContext(),
    );
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// A new pairing code; an earlier one stops working. The device that
  /// pairs with it is the athlete's own, or with [role] an athlete's.
  Future<PairingOffer> offerPairing({
    List<String>? hosts,
    PeerRole role = PeerRole.self,
  }) async {
    _role = role;
    _token = randomToken(16);
    _tokenExpires = DateTime.now().add(offerLifetime);
    return PairingOffer(
      deviceId: identity.deviceId,
      name: name,
      fingerprint: identity.fingerprint,
      hosts: hosts ?? await localAddresses(),
      port: boundPort,
      token: _token!,
    );
  }

  /// Withdraws the current pairing code.
  void cancelPairing() => _token = null;

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == pairPath && request.method == 'POST') {
        return await _pair(request);
      }
      final peer = await _authenticate(request);
      if (peer == null) {
        return await writeJson(request.response, 401, {
          'error': 'unknown_device',
        });
      }
      switch ((request.method, path)) {
        case ('GET', cursorPath):
          await writeJson(request.response, 200, {
            'epoch': peer.peerLogEpoch,
            'seq': peer.receivedSeq,
            'schema': _dataOf(peer).schemaVersion,
          });
        case ('POST', changesPath):
          await _receive(request, peer);
        case ('GET', changesPath):
          await _send(request, peer);
        case ('GET', wantedPath):
          await writeJson(
            request.response,
            200,
            await (wanted?.call(peer) ?? _dataOf(peer).syncWanted()),
          );
        case ('POST', extraPath):
          await _receiveExtra(request, peer);
        case ('POST', proPath):
          // Kept as handed over; whoever relies on it checks it.
          final body = await readJson(request, maxBytes: 8 * 1024) as Map;
          final pass = body['pass'];
          await db.setSyncPeerProPass(
            peer.deviceId,
            pass is String && pass.length < 4096 ? pass : null,
          );
          _events.add(ProPassReceived(peer));
          await writeJson(request.response, 200, {'ok': true});
        case ('DELETE', pairPath):
          await db.removeSyncPeer(peer.deviceId);
          _events.add(PeerUnpaired(peer));
          await writeJson(request.response, 200, {});
        default:
          await writeJson(request.response, 404, {'error': 'bad_request'});
      }
    } on FormatException {
      await writeJson(request.response, 400, {'error': 'bad_request'});
    } on TypeError {
      await writeJson(request.response, 400, {'error': 'bad_request'});
    } on Object {
      await writeJson(request.response, 500, {'error': 'failed'});
    }
  }

  Future<void> _pair(HttpRequest request) async {
    final body = await readJson(request, maxBytes: 16 * 1024) as Map;
    final device = body['device'] as Map;
    final valid =
        _token != null &&
        body['token'] == _token &&
        DateTime.now().isBefore(_tokenExpires!);
    if (!valid) {
      return writeJson(request.response, 403, {'error': 'token'});
    }
    _token = null; // one device per code
    final secret = randomToken(32);
    final peer = SyncPeer(
      deviceId: device['id'] as String,
      name: device['name'] as String,
      fingerprint: device['fingerprint'] as String,
      pairedAt: DateTime.now(),
      // What this device would send back; the first release sends nothing.
      categories: _athleteCategories,
      secretHash: sha256Hex(secret),
      role: _role,
    );
    await db.saveSyncPeer(peer);
    _events.add(PeerPaired(peer));
    await writeJson(request.response, 200, {
      'device': {'id': identity.deviceId, 'name': name},
      'secret': secret,
    });
  }

  Future<SyncPeer?> _authenticate(HttpRequest request) async {
    final id = request.headers.value(deviceHeader);
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (id == null || auth == null || !auth.startsWith('Bearer ')) return null;
    final peer = await db.syncPeer(id);
    final hash = peer?.secretHash;
    if (hash == null || !_equal(hash, sha256Hex(auth.substring(7)))) {
      return null;
    }
    return peer;
  }

  Future<void> _receive(HttpRequest request, SyncPeer peer) async {
    final body = await readJson(request, maxBytes: 256 << 20) as Map;
    final data = _dataOf(peer);
    // An older phone is fine: what it lacks it does not send. A newer one
    // may send what this version cannot keep.
    if ((body['schema'] as int) > data.schemaVersion) {
      return writeJson(request.response, 409, {
        'error': 'schema',
        'schema': data.schemaVersion,
      });
    }
    final epoch = body['epoch'] as String;
    final changes = [
      for (final c in body['changes'] as List)
        SyncChange.fromJson((c as Map).cast<String, Object?>()),
    ];
    // A page that does not continue where the last one ended would leave a
    // gap; the sender asks for the cursor again.
    final from = body['from'] as int;
    final expected = epoch == peer.peerLogEpoch ? peer.receivedSeq : 0;
    if (from != expected) {
      return writeJson(request.response, 409, {
        'error': 'cursor',
        'epoch': peer.peerLogEpoch,
        'seq': peer.receivedSeq,
      });
    }
    // A new log from the phone resends what it has; what it dropped would
    // stay here, so what came from that phone starts again.
    final restarted =
        peer.peerLogEpoch != null && epoch != peer.peerLogEpoch && from == 0;
    if (restarted) await data.clearSyncedData(origin: peer.deviceId);
    await data.applySyncChanges(changes, fromDevice: peer.deviceId);
    // After the changes: a crash in between sends them again, and taking a
    // change twice changes nothing.
    await db.setSyncPeerCursor(
      peer.deviceId,
      epoch,
      changes.isEmpty ? from : changes.last.seq,
    );
    await db.setSyncPeerSynced(peer.deviceId, DateTime.now());
    _events.add(ChangesReceived(peer, changes.length));
    await writeJson(request.response, 200, {
      'seq': changes.isEmpty ? from : changes.last.seq,
    });
  }

  /// Content asked for, outside the log's order: no cursor moves.
  Future<void> _receiveExtra(HttpRequest request, SyncPeer peer) async {
    final body = await readJson(request, maxBytes: 256 << 20) as Map;
    final data = _dataOf(peer);
    if ((body['schema'] as int) > data.schemaVersion) {
      return writeJson(request.response, 409, {'error': 'schema'});
    }
    final changes = [
      for (final c in body['changes'] as List)
        SyncChange.fromJson((c as Map).cast<String, Object?>()),
    ];
    await data.applySyncChanges(changes, fromDevice: peer.deviceId);
    _events.add(ChangesReceived(peer, changes.length));
    await writeJson(request.response, 200, {'taken': changes.length});
  }

  /// What this device has that [peer] does not: its own changes and those
  /// of other devices, never the peer's own. A cursor from another log
  /// epoch starts again at 0.
  Future<void> _send(HttpRequest request, SyncPeer peer) async {
    final q = request.uri.queryParameters;
    final data = _dataOf(peer);
    final epoch = await data.syncLogEpoch();
    final after = q['epoch'] == epoch ? int.tryParse(q['after'] ?? '') ?? 0 : 0;
    final limit = (int.tryParse(q['limit'] ?? '') ?? 200).clamp(1, 1000);
    final changes = await data.syncChangesSince(
      after,
      limit: limit,
      categories: peer.categories,
      exceptOrigin: peer.deviceId,
    );
    await writeJson(request.response, 200, {
      'epoch': epoch,
      'from': after,
      'changes': [for (final c in changes) c.toJson()],
    });
  }

  static bool _equal(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Everything of the athlete's own; the coach's tables have their own phase.
final _athleteCategories = {...SyncCategory.values}..remove(SyncCategory.coach);

/// This device's IPv4 addresses on local networks, private ranges first.
Future<List<String>> localAddresses() async {
  final all = [
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
      for (final a in i.addresses)
        if (!a.isLoopback && !a.isLinkLocal) a.address,
  ];
  bool private(String a) =>
      a.startsWith('192.168.') ||
      a.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a);
  return [...all.where(private), ...all.where((a) => !private(a))];
}
