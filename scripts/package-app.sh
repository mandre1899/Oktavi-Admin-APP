#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Oktavi Staff.app"

swift build --package-path "$ROOT" -c release
BIN_DIR=$(swift build --package-path "$ROOT" -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OktaviStaff" "$APP/Contents/MacOS/OktaviStaff"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/OktaviStaff.icns" "$APP/Contents/Resources/OktaviStaff.icns"

codesign --force --deep --sign - "$APP"
printf '%s\n' "Created $APP"
