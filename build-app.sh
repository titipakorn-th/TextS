#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/build/TextS.app"
APP_ARCH="$(uname -m)"

cd "$ROOT"

# version.txt is the one place a new version is written. The files that need
# a literal are kept in step with it here, so a release only touches that
# one file.
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
BUILD="${VERSION##*.}"
if [[ "$BUILD" == "0" ]]; then BUILD=1; fi
sed -i '' "s/^version = \".*\"/version = \"$VERSION\"/" Cargo.toml
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist

cargo build --release
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
swiftc -parse-as-library -target "$APP_ARCH-apple-macosx13.0" -O -framework AppKit -framework Carbon -framework ServiceManagement "$ROOT/src/App.swift" "$ROOT/src/Updater.swift" -o "$APP/Contents/MacOS/TextS"
cp target/release/textsniper-rs "$APP/Contents/MacOS/textsniper-rs"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
print "Built $APP"
