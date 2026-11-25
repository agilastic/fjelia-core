# fjelia-core

Platform-independent Fjelia code shared by the mobile app (`fjelia`), the
desktop app (`fjelia-desktop`) and the backend worker (`fjelia-service`).

| Package | Contents |
| --- | --- |
| `packages/fjelia_core` | Domain models and algorithms: zones, load and form, HRV, ECG, sleep staging, FIT/GPX/TCX parsing, scores, planning, AI Coach context |
| `packages/fjelia_data` | The Drift database: schema, migrations and queries, shared by the mobile and desktop apps (opening it is each app's part) |
| `packages/fjelia_sync` | Nearby sync: device identity, pairing by QR code and the HTTPS transport between an athlete's devices (uses `dart:io`) |
| `packages/fjelia_views` | What each screen shows and when: reads `fjelia_data`, computes with `fjelia_core`, returns view models both apps render (they decide only how and where, and the wording) |
| `packages/fjelia_mcp` | Fjelia's tools for AI assistants (Model Context Protocol), transport-independent: read Today, the calendar, activities, analysis, season, health and diary; move, rest or add workouts through PlanEdits |
| `packages/fjelia_service_api` | Public interfaces of the optional private service package; the apps' public stub and the private implementation both build on it |

`fjelia_core` depends on the Dart SDK and pure-Dart packages only.
`test/architecture/core_boundary_test.dart` enforces this.

## Using it

The apps depend on a tag:

```yaml
fjelia_core:
  git:
    url: https://github.com/agilastic/fjelia-core.git
    ref: v0.2.0
    path: packages/fjelia_core
```

(the same with `path: packages/fjelia_service_api` and `path: packages/fjelia_data`; all three at the same commit). To work on the core and
an app together, check both out side by side and point the app at the
checkout in its git-ignored `pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  fjelia_core:
    path: ../fjelia-core/packages/fjelia_core
  fjelia_service_api:
    path: ../fjelia-core/packages/fjelia_service_api
  fjelia_data:
    path: ../fjelia-core/packages/fjelia_data
```

After a schema change, regenerate in `packages/fjelia_data` with
`dart run build_runner build --delete-conflicting-outputs` (Flutter's Dart).

## Sync between devices

`fjelia_core/services/sync/sync_tables.dart` names every table once: synced
(with its category, key and merge rule), kept on the device, or held back for
the coach phase. A new table fails `fjelia_data`'s sync test until it is
listed there. `fjelia_data/sync.dart` keeps the change log: triggers record
the newest change of each synced record, a peer asks for everything after
the last `seq` it received, and received changes are applied without being
logged as the receiving device's own. Rows without a natural key get a
permanent sync id, because their integer ids are numbered per device.

`fjelia_sync` moves the log. The desktop runs a `SyncServer` over HTTPS with
a self-signed certificate and shows a pairing code (`PairingOffer`, a
`fjelia://pair` link for a QR code) with its fingerprint, addresses and a
one-time token valid for five minutes. The phone's `SyncClient` accepts only
that certificate, presents the token and receives a secret, which it keeps in
the app's secure storage; the desktop stores only its hash. After that the
phone sends every change after the desktop's cursor, in gzip pages. Each app
supplies a `SecretStore` for the device identity and secrets.

## Commands

Use the Dart SDK bundled with the app's Flutter version (3.47.7, Dart 3.13.5):

```bash
dart pub get
dart analyze packages/fjelia_core
cd packages/fjelia_core && dart test
```
