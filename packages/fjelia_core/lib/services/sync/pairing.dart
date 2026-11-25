/// What a device shows as a QR code so another device can pair with it.
library;

/// A one-time invitation to pair: who the offering device is, where it
/// listens, the fingerprint its certificate must have, and a token that
/// proves the other device saw the code.
class PairingOffer {
  const PairingOffer({
    required this.deviceId,
    required this.name,
    required this.fingerprint,
    required this.hosts,
    required this.port,
    required this.token,
  });

  static const version = 1;
  static const _scheme = 'fjelia';

  final String deviceId;
  final String name;

  /// SHA-256 of the offering device's certificate, lowercase hex.
  final String fingerprint;

  /// Addresses on the local network, the likeliest first.
  final List<String> hosts;
  final int port;
  final String token;

  Uri toUri() => Uri(
    scheme: _scheme,
    host: 'pair',
    queryParameters: {
      'v': '$version',
      'id': deviceId,
      'n': name,
      'fp': fingerprint,
      'h': hosts.join(','),
      'p': '$port',
      't': token,
    },
  );

  /// The offer in [text], or null when it is not a Fjelia pairing code of
  /// this version.
  static PairingOffer? parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != _scheme || uri.host != 'pair') {
      return null;
    }
    final q = uri.queryParameters;
    final port = int.tryParse(q['p'] ?? '');
    final hosts = (q['h'] ?? '').split(',').where((h) => h.isNotEmpty);
    if (q['v'] != '$version' ||
        port == null ||
        hosts.isEmpty ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(q['fp'] ?? '')) {
      return null;
    }
    for (final k in const ['id', 'n', 't']) {
      if ((q[k] ?? '').isEmpty) return null;
    }
    return PairingOffer(
      deviceId: q['id']!,
      name: q['n']!,
      fingerprint: q['fp']!,
      hosts: hosts.toList(),
      port: port,
      token: q['t']!,
    );
  }
}
