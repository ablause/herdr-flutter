#!/usr/bin/env bash
# Build step for `herdr plugin install`, and the one-time step for a local
# checkout linked with `herdr plugin link`.
#
# Compiles the sidebar to a single native executable, so the pane starts without
# a Dart VM warm-up and without needing the SDK on PATH at run time.
set -euo pipefail

# herdr runs plugin commands with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v dart >/dev/null 2>&1; then
  printf 'herdr-flutter: dart is not on PATH. Install Flutter (which ships the Dart SDK) and retry.\n' >&2
  exit 1
fi

dart pub get
dart compile exe bin/herdr_flutter.dart -o bin/herdr-flutter
printf 'herdr-flutter: built %s/bin/herdr-flutter\n' "$root"
