#!/bin/zsh
# Puts the sherpa-onnx dylibs used for (experimental) speaker separation into Vendor/sherpa-onnx/lib,
# where build-app.sh picks them up. Not in git (≈ 31 MB). Without them the app still builds and runs;
# the feature just shows as unavailable.
#   scripts/fetch-sherpa.sh                  download from the GitHub release
#   scripts/fetch-sherpa.sh path/to.tar.bz2  use an already downloaded archive
set -euo pipefail
cd "${0:A:h}/.."
VERSION=2.0.1
NAME="sherpa-onnx-v$VERSION-osx-arm64-shared-no-tts"
SHA256=4fcc6c77c8d8d2e2f04cfdc17c6fd224c01469b78529370eb9d8e0e5ec97ac79
DEST=Vendor/sherpa-onnx
mkdir -p "$DEST/cache"
ARCHIVE="${1:-$DEST/cache/$NAME.tar.bz2}"
if [[ ! -f "$ARCHIVE" ]]; then
  # Resumes if interrupted (GitHub downloads can be slow).
  until curl -fL -C - --retry 5 -o "$ARCHIVE" \
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$VERSION/$NAME.tar.bz2"; do
    echo "retrying…"; sleep 2
  done
fi
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c -
rm -rf "$DEST/lib" && mkdir -p "$DEST/lib"
tar -xjf "$ARCHIVE" -C "$DEST/cache" "$NAME/lib/libsherpa-onnx-c-api.dylib" "$NAME/lib/libonnxruntime.dylib"
mv "$DEST/cache/$NAME/lib/"*.dylib "$DEST/lib/"
rm -rf "$DEST/cache/$NAME"
ls -la "$DEST/lib"
