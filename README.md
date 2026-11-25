# fjelia-core

Platform-independent Fjelia code shared by the mobile app (`fjelia`), the
desktop app (`fjelia-desktop`) and the backend worker (`fjelia-service`).

| Package | Contents |
| --- | --- |
| `packages/fjelia_core` | Domain models and algorithms: zones, load and form, HRV, ECG, sleep staging, FIT/GPX/TCX parsing, scores, planning, AI Coach context |
| `packages/fjelia_data` | The Drift database: schema, migrations and queries, shared by the mobile and desktop apps (opening it is each app's part) |
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

## Commands

Use the Dart SDK bundled with the app's Flutter version (3.47.7, Dart 3.13.5):

```bash
dart pub get
dart analyze packages/fjelia_core
cd packages/fjelia_core && dart test
```
