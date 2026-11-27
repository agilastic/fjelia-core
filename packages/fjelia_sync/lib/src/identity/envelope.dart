/// Changes on their way through the relay, end to end encrypted
/// (docs/identity-and-sync-security.md, section 7.2).
library;

import 'dart:convert';
import 'dart:io' show gzip;

import 'crypto.dart';
import 'device_list.dart';

/// A device an envelope is encrypted for.
typedef Recipient = ({String device, List<int> encKey});

/// Why an envelope was dropped; nothing of it is applied.
class EnvelopeRejected implements Exception {
  EnvelopeRejected(this.reason);
  final String reason;
  @override
  String toString() => 'envelope dropped: $reason';
}

/// [payload] (JSON) for [recipients], signed by the sending device.
Map<String, Object> sealEnvelope({
  required KeyPair senderSign,
  required String person,
  required int seq,
  required Object payload,
  required List<Recipient> recipients,
  DateTime? now,
}) {
  final from = senderSign.id;
  final dataKey = randomBytes(32), nonce = randomBytes(12);
  final header = <String, Object>{
    'v': 1,
    'from': from,
    'person': person,
    'seq': seq,
    'sent': isoSeconds(now ?? DateTime.now()),
    'nonce': base64.encode(nonce),
  };
  final body = seal(
    dataKey,
    nonce,
    gzip.encode(utf8.encode(jsonEncode(payload))),
    utf8.encode(canonicalJson(header)),
  );
  final envelope = <String, Object>{
    ...header,
    'recipients': [
      for (final r in recipients)
        if (r.device != from) _wrap(dataKey, r, from),
    ],
    'body': base64.encode(body),
  };
  envelope['sig'] = base64.encode(
    senderSign.sign(utf8.encode(canonicalJson(envelope))),
  );
  return envelope;
}

Map<String, String> _wrap(List<int> dataKey, Recipient r, String from) {
  final ephemeral = KeyPair.generate();
  final key = hkdf(
    sharedSecret(ephemeral.private, r.encKey),
    r.device,
    'fjelia wrap v1',
  );
  final nonce = randomBytes(12);
  return {
    'device': r.device,
    'epk': base64.encode(ephemeral.spki),
    'nonce': base64.encode(nonce),
    'wrapped': base64.encode(seal(key, nonce, dataKey, utf8.encode(from))),
  };
}

/// The payload of [envelope] for this device ([device], [encKey]), checked in
/// the design's order. [senderKey] gives the signing key of a device allowed
/// to send for the envelope's person, or null for any other. Throws
/// [EnvelopeRejected].
Object? openEnvelope(
  Map<String, dynamic> envelope, {
  required String device,
  required KeyPair encKey,
  required List<int>? Function(String from, String person) senderKey,
}) {
  try {
    if (envelope['v'] != 1) throw EnvelopeRejected('unknown version');
    final from = envelope['from'] as String;
    final key = senderKey(from, envelope['person'] as String);
    if (key == null || idOf(key) != from) {
      throw EnvelopeRejected('sender not allowed');
    }
    final unsigned = Map<String, dynamic>.of(envelope)..remove('sig');
    if (!verify(
      key,
      utf8.encode(canonicalJson(unsigned)),
      base64.decode(envelope['sig'] as String),
    )) {
      throw EnvelopeRejected('bad signature');
    }
    final mine = (envelope['recipients'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['device'] == device)
        .firstOrNull;
    if (mine == null) throw EnvelopeRejected('not a recipient');
    final wrapKey = hkdf(
      sharedSecret(encKey.private, base64.decode(mine['epk'] as String)),
      device,
      'fjelia wrap v1',
    );
    final dataKey = open(
      wrapKey,
      base64.decode(mine['nonce'] as String),
      base64.decode(mine['wrapped'] as String),
      utf8.encode(from),
    );
    final header = Map<String, dynamic>.of(unsigned)
      ..remove('recipients')
      ..remove('body');
    final body = open(
      dataKey,
      base64.decode(envelope['nonce'] as String),
      base64.decode(envelope['body'] as String),
      utf8.encode(canonicalJson(header)),
    );
    return jsonDecode(utf8.decode(gzip.decode(body)));
  } on EnvelopeRejected {
    rethrow;
  } on Object catch (e) {
    throw EnvelopeRejected('does not open: ${e.runtimeType}');
  }
}
