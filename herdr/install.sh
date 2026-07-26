#!/usr/bin/env bash
# Puts the sidebar binary in bin/herdr-flutter.
#
#   install.sh              prebuilt from the release for this manifest version,
#                           falling back to a source build if none is usable
#   install.sh --prebuilt   prebuilt only, never build
#   install.sh --source     build from source only, never download
#
# This is the `[[build]]` step of `herdr plugin install`, so the default path must
# not need a Dart SDK. `herdr plugin link` skips build steps: for a local checkout
# run `bash herdr/install.sh --source` yourself, which is also what to use while
# developing, since the release asset would otherwise overwrite your build.
#
# The working directory of a build step is the plugin checkout, but the runtime
# env may be absent, so the root is resolved from this script's own location.
set -euo pipefail

# herdr runs plugin commands with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

NAME="herdr-flutter"
REPO="ablause/herdr-flutter"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
mode="${1:-auto}"

case "$mode" in
auto | --prebuilt | --source) ;;
*)
  printf '%s: unknown option %s (--prebuilt | --source)\n' "$NAME" "$mode" >&2
  exit 2
  ;;
esac

# The release tag follows the manifest version, so a checkout pulls its own release.
VERSION="$(grep -m1 '^version' "$ROOT/herdr-plugin.toml" | sed -E 's/.*"([^"]+)".*/\1/')"
TAG="v${VERSION}"

build_from_source() {
  if ! command -v dart >/dev/null 2>&1; then
    printf '%s: dart is not on PATH. Install Flutter, which ships the Dart SDK.\n' "$NAME" >&2
    return 1
  fi
  cd "$ROOT"
  dart pub get
  mkdir -p "$BIN_DIR"
  dart compile exe bin/herdr_flutter.dart -o "$BIN_DIR/$NAME"
  printf '%s: built %s/%s from source\n' "$NAME" "$BIN_DIR" "$NAME"
}

if [ "$mode" = --source ]; then
  build_from_source
  exit $?
fi

# Map the running platform to the release target.
os="$(uname -s)"
arch="$(uname -m)"
case "$os-$arch" in
Darwin-arm64) target="aarch64-apple-darwin" ;;
Darwin-x86_64) target="x86_64-apple-darwin" ;;
Linux-aarch64 | Linux-arm64) target="aarch64-unknown-linux-gnu" ;;
Linux-x86_64) target="x86_64-unknown-linux-gnu" ;;
*) target="" ;;
esac

fallback() {
  printf '%s: %s\n' "$NAME" "$1" >&2
  if [ "$mode" = --prebuilt ]; then
    exit 1
  fi
  printf '%s: building from source instead\n' "$NAME" >&2
  build_from_source
  exit $?
}

[ -n "$target" ] || fallback "no prebuilt binary for $os-$arch"

archive="${NAME}-${target}.tar.gz"
checksum="${NAME}-${target}.sha256"
base="https://github.com/${REPO}/releases/download/${TAG}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Release-asset downloads are eventually consistent: the CDN can 404 for a few
# minutes after a release is published, so retry even on 404. A private repo
# serves nothing to an anonymous curl, hence the authenticated gh fallback.
# curl's own errors are held back until the gh fallback has had its turn: on a
# private repository an anonymous download always 404s, and printing that as an
# error would make a perfectly good install look broken.
fetch() {
  local asset="$1"
  curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --retry-connrefused \
    "$base/$asset" -o "$tmp/$asset" 2>"$tmp/curl.err" && return 0
  if command -v gh >/dev/null 2>&1 &&
    gh release download "$TAG" --repo "$REPO" --pattern "$asset" --dir "$tmp" >/dev/null 2>&1; then
    return 0
  fi
  [ -s "$tmp/curl.err" ] && cat "$tmp/curl.err" >&2
  return 1
}

printf '%s: downloading %s (%s)\n' "$NAME" "$archive" "$TAG"
fetch "$archive" || fallback "could not download $archive from $TAG"
fetch "$checksum" || fallback "could not download $checksum from $TAG"

expected="$(awk '{print $1}' "$tmp/$checksum")"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')"
fi
if [ "$expected" != "$actual" ]; then
  # Never fall back to a source build here: a mismatch means the asset is not
  # what the release says it is, and that is worth stopping for.
  printf '%s: checksum mismatch (expected %s, got %s)\n' "$NAME" "$expected" "$actual" >&2
  exit 1
fi

tar -xzf "$tmp/$archive" -C "$tmp"
mkdir -p "$BIN_DIR"
install -m 0755 "$tmp/$NAME" "$BIN_DIR/$NAME"
printf '%s: installed %s/%s (%s, %s)\n' "$NAME" "$BIN_DIR" "$NAME" "$TAG" "$target"
