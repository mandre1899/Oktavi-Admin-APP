#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Oktavi Staff.app"

swift build --package-path "$ROOT" -c release
BIN_DIR=$(swift build --package-path "$ROOT" -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/OktaviStaff" "$APP/Contents/MacOS/OktaviStaff"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
printf '%s\n' "Created $APP"
