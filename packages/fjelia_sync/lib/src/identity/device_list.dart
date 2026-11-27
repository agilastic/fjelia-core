/// The person's devices, signed with the person key
/// (docs/identity-and-sync-security.md, section 5).
library;

import 'dart:convert';

import 'crypto.dart';

const maxDevices = 10;

/// Times as the formats write them: ISO 8601 UTC with Z, whole seconds.
String isoSeconds(DateTime t) =>
    '${t.toUtc().toIso8601String().split('.').first.replaceAll('Z', '')}Z';

class ListedDevice {
  const ListedDevice({
    required this.signKey,
    required this.encKey,
    required this.name,
    required this.platform,
    required this.added,
  });

  factory ListedDevice.fromJson(Map<String, dynamic> j) => ListedDevice(
    signKey: base64.decode(j['sign_key'] as String),
    encKey: base64.decode(j['enc_key'] as String),
    name: j['name'] as String,
    platform: j['platform'] as String,
    added: j['added'] as String,
  );

  final List<int> signKey, encKey;
  final String name, platform, added;

  String get id => idOf(signKey);

  Map<String, Object> toJson() => {
    'id': id,
    'sign_key': base64.encode(signKey),
    'enc_key': base64.encode(encKey),
    'name': name,
    'platform': platform,
    'added': added,
  };
}

class DeviceList {
  const DeviceList({
    required this.personKey,
    required this.version,
    required this.issued,
    required this.devices,
    this.removed = const [],
  });

  final List<int> personKey;
  final int version;
  final String issued;
  final List<ListedDevice> devices;
  final List<String> removed;

  String get person => idOf(personKey);

  ListedDevice? device(String id) =>
      devices.where((d) => d.id == id).firstOrNull;

  Map<String, Object> toJson() => {
    'v': 1,
    'person': person,
    'person_key': base64.encode(personKey),
    'version': version,
    'issued': issued,
    'devices': [for (final d in devices) d.toJson()],
    'removed': removed,
  };

  /// `{"list": …, "sig": …}`, signed with [personKey]'s private half.
  Map<String, Object> signed(KeyPair person) {
    if (idOf(person.spki) != this.person) {
      throw ArgumentError('not this list\'s person key');
    }
    final list = toJson();
    return {
      'list': list,
      'sig': base64.encode(person.sign(utf8.encode(canonicalJson(list)))),
    };
  }

  /// The next version with [device] added.
  DeviceList adding(ListedDevice device, DateTime now) {
    if (devices.any((d) => d.id == device.id)) return this;
    if (removed.contains(device.id)) {
      throw StateError('a removed device does not come back');
    }
    if (devices.length >= maxDevices) {
      throw StateError('at most $maxDevices devices');
    }
    return DeviceList(
      personKey: personKey,
      version: version + 1,
      issued: isoSeconds(now),
      devices: [...devices, device],
      removed: removed,
    );
  }

  /// The next version without the device [id]; it stays in [removed].
  DeviceList removing(String id, DateTime now) => DeviceList(
    personKey: personKey,
    version: version + 1,
    issued: isoSeconds(now),
    devices: [
      for (final d in devices)
        if (d.id != id) d,
    ],
    removed: [...removed, if (!removed.contains(id)) id],
  );

  /// The list inside [signed] if its signature, ids and limits hold; else
  /// null. [person], when given, must be the list's person.
  static DeviceList? verified(Map<String, dynamic> signed, {String? person}) {
    try {
      final list = signed['list'] as Map<String, dynamic>;
      if (list['v'] != 1) return null;
      final key = base64.decode(list['person_key'] as String);
      if (list['person'] != idOf(key)) return null;
      if (person != null && list['person'] != person) return null;
      if (!verify(
        key,
        utf8.encode(canonicalJson(list)),
        base64.decode(signed['sig'] as String),
      )) {
        return null;
      }
      final devices = [
        for (final d in list['devices'] as List)
          ListedDevice.fromJson(d as Map<String, dynamic>),
      ];
      final ids = [for (final d in list['devices'] as List) d['id']];
      if ([for (final d in devices) d.id].join() != ids.join()) return null;
      if (devices.length > maxDevices) return null;
      final removed = [for (final r in list['removed'] as List) r as String];
      if (devices.any((d) => removed.contains(d.id))) return null;
      return DeviceList(
        personKey: key,
        version: list['version'] as int,
        issued: list['issued'] as String,
        devices: devices,
        removed: removed,
      );
    } on Object {
      return null;
    }
  }

  /// [incoming] if it is a valid newer list of the same person than
  /// [current]; otherwise [current]. Older versions never win, so a removed
  /// device cannot be brought back by an old list.
  static DeviceList? newer(DeviceList? current, Map<String, dynamic> incoming) {
    final next = verified(incoming, person: current?.person);
    if (next == null) return current;
    if (current != null && next.version <= current.version) return current;
    return next;
  }
}
