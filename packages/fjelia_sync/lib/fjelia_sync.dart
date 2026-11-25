/// Nearby sync between an athlete's devices.
///
/// The desktop runs a [SyncServer] and shows a pairing code; the phone scans
/// it, pairs with a [SyncClient] and sends its changes. Each side has a
/// [DeviceIdentity] kept in the app's secure storage. The phone trusts only
/// the certificate the code names; the desktop trusts only devices that
/// present the secret it issued when they paired.
library;

export 'package:fjelia_core/services/sync/pairing.dart';
export 'package:fjelia_data/sync.dart' show SyncPeer, SyncStore;

export 'src/client.dart';
export 'src/identity.dart' show DeviceIdentity, SecretStore;
export 'src/protocol.dart' show SyncRefused, defaultSyncPort;
export 'src/server.dart';
