# fjelia-core

Platform-independent Fjelia code shared by the mobile app (`fjelia`), the
desktop app (`fjelia-desktop`) and the backend worker (`fjelia-service`).

| Package | Contents |
| --- | --- |
| `packages/fjelia_core` | Domain models and algorithms: zones, load and form, HRV, ECG, sleep staging, FIT/GPX/TCX parsing, scores |

`fjelia_core` depends on the Dart SDK and pure-Dart packages only.
`test/architecture/core_boundary_test.dart` enforces this.

## Layout on disk

Check out next to the app; the app depends on
`../fjelia-core/packages/fjelia_core`, and `fjelia_core` still takes
`fjelia_service_api` from `../fjelia/packages/` until that package moves here.

## Commands

Use the Dart SDK bundled with the app's Flutter version (3.47.7, Dart 3.13.5):

```bash
dart pub get
dart analyze packages/fjelia_core
cd packages/fjelia_core && dart test
```
