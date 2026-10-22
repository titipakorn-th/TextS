#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/version.txt")"
ARCH="$(uname -m)"
OUT="$ROOT/build/release-$VERSION"
DMG_STAGE="$OUT/dmg"
ZIP_STAGE="$OUT/zip/TextS-$VERSION"
NAME="TextS-$VERSION-macos-$ARCH"

cd "$ROOT"
./build-app.sh

mkdir -p "$DMG_STAGE" "$ZIP_STAGE"
ditto "$ROOT/build/TextS.app" "$DMG_STAGE/TextS.app"
ditto "$ROOT/build/TextS.app" "$ZIP_STAGE/TextS.app"
# The disk image opens to a drag-to-Applications layout.
ln -sfn /Applications "$DMG_STAGE/Applications"

hdiutil create -volname "TextS $VERSION" -srcfolder "$DMG_STAGE" -fs APFS -format UDZO -ov \
    "$OUT/$NAME.dmg" | tail -1
ditto -c -k --sequesterRsrc --keepParent "$ZIP_STAGE" "$OUT/$NAME.zip"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)

print "Packaged $VERSION in $OUT"
print "  $NAME.dmg"
print "  $NAME.zip"
print "  SHA256SUMS.txt"
