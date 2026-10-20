#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/.build/test"
ARCH="$(uname -m)"
mkdir -p "$BUILD"

# The app sources are built as a module so the check drives the code the app
# ships, not a copy of it.
swiftc -parse-as-library -enable-testing -emit-module -emit-library \
  -module-name TextS -target "$ARCH-apple-macosx13.0" -O \
  -framework AppKit -framework Carbon -framework ServiceManagement \
  "$ROOT/src/App.swift" "$ROOT/src/Updater.swift" \
  -emit-module-path "$BUILD/TextS.swiftmodule" -o "$BUILD/libTextS.dylib"

swiftc -enable-testing -module-name OCRTimeoutCheck \
  -target "$ARCH-apple-macosx13.0" -I "$BUILD" -L "$BUILD" -lTextS \
  "$ROOT/tests/main.swift" -o "$BUILD/ocr-timeout-check"

"$BUILD/ocr-timeout-check"
