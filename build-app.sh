#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/build/TextS.app"
APP_ARCH="$(uname -m)"

cd "$ROOT"
cargo build --release
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
swiftc -parse-as-library -target "$APP_ARCH-apple-macosx13.0" -O -framework AppKit -framework Carbon -framework ServiceManagement "$ROOT/src/App.swift" "$ROOT/src/Updater.swift" -o "$APP/Contents/MacOS/TextS"
cp target/release/textsniper-rs "$APP/Contents/MacOS/textsniper-rs"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
print "Built $APP"
