#!/bin/bash
# Build Questions as a proper .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

echo "Building Questions..."
swift build 2>&1

APP_DIR=".build/Questions.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS"

cp .build/debug/Questions "$MACOS/Questions"
cp Resources/Info.plist "$CONTENTS/Info.plist"

# The window renders option labels and code previews through Components'
# AppFont, which probes Contents/Resources/Fonts first and falls back to the
# system stack. Without these the previews lose their monospace alignment.
mkdir -p "$CONTENTS/Resources/Fonts"
cp ../../../barry/bags/sessions/sessions-macos/app/Resources/Fonts/*.ttf "$CONTENTS/Resources/Fonts/"

# Bind the ad-hoc signature to the assembled bundle. `swift build` signs the
# bare binary and seals resources, but the resources are copied in above —
# leaving the bundle unverifiable, which macOS refuses to launch.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"

echo "Built: $APP_DIR"
