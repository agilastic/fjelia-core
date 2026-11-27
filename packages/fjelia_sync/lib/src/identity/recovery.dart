/// The recovery code end to end (docs/identity-and-sync-security.md,
/// section 9): making one, and coming back with it on a new device.
library;

import '../identity.dart' show SecretStore;
import 'device_list.dart';
import 'person.dart';
import 'relay_client.dart';

const _lookup = 'fjelia.identity.recovery_lookup';

/// A new recovery code for [me], kept on the relay encrypted under itself;
/// the previous code stops working. Show it to the person once: it is not
/// kept anywhere readable.
Future<String> makeRecoveryCode(
  PersonIdentity me,
  RelayClient relay,
  SecretStore store,
) async {
  final r = me.newRecovery();
  await relay.uploadList(me.signedList);
  await relay.signIn(me);
  await relay.keepRecovery(
    r.lookup,
    r.blob,
    replaces: await store.read(_lookup),
  );
  await store.write(_lookup, r.lookup);
  return r.code;
}

/// Why coming back with a code did not work.
enum RestoreProblem { notACode, unknownCode, wrongCode }

/// This device becomes the person whose code [code] is: their key from the
/// relay, opened with the code, and their device list with this device
/// added. Replaces whatever identity this device had.
Future<({PersonIdentity? identity, RestoreProblem? problem})> restoreWithCode(
  String code, {
  required RelayClient relay,
  required SecretStore store,
  required String deviceName,
  required String platform,
}) async {
  final lookup = recoveryLookup(code);
  if (lookup == null) return (identity: null, problem: RestoreProblem.notACode);
  final blob = await relay.recovery(lookup);
  if (blob == null) {
    return (identity: null, problem: RestoreProblem.unknownCode);
  }
  final person = blob['person'] as String;
  final signed = await relay.list(person);
  final identity = await PersonIdentity.restore(
    store,
    blob: blob,
    code: code,
    deviceName: deviceName,
    platform: platform,
    lastKnown: signed == null
        ? null
        : DeviceList.verified(signed, person: person),
  );
  if (identity == null) {
    return (identity: null, problem: RestoreProblem.wrongCode);
  }
  await relay.uploadList(identity.signedList);
  await store.write(_lookup, lookup);
  return (identity: identity, problem: null);
}
