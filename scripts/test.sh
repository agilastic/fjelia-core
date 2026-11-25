#!/usr/bin/env bash
# Analyze and test fjelia_core and fjelia_data with the Dart SDK of the installed Flutter.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  -h|--help)
    echo "Usage: scripts/test.sh  (pub get, analyze and test fjelia_core and fjelia_data)"
    exit 0 ;;
  "") ;;
  *) echo "Usage: scripts/test.sh" >&2; exit 2 ;;
esac
# A standalone dart can be older than the SDK the apps need; Flutter's own
# Dart is the one the apps build with.
flutter_bin="$(command -v flutter)"
while [ -L "$flutter_bin" ]; do
  link="$(readlink "$flutter_bin")"
  case "$link" in /*) flutter_bin="$link" ;; *) flutter_bin="$(dirname "$flutter_bin")/$link" ;; esac
done
dart="$(dirname "$flutter_bin")/cache/dart-sdk/bin/dart"
[ -x "$dart" ] || { echo "Run flutter --version once to download its Dart SDK." >&2; exit 1; }
"$dart" --version
"$dart" pub get
"$dart" analyze --fatal-warnings packages/fjelia_core packages/fjelia_data
(cd packages/fjelia_core && "$dart" test)
(cd packages/fjelia_data && "$dart" test)
