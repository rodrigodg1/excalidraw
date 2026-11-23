#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Excalidraw"
MACOS_SRC_DIR="$ROOT_DIR/macos-app"
WEB_BUILD_DIR="$ROOT_DIR/excalidraw-app/build"
DIST_DIR="$MACOS_SRC_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$MACOS_SRC_DIR/AppIcon.iconset"
SRC_ICON="$ROOT_DIR/public/android-chrome-512x512.png"

echo "==> 1. Building Excalidraw web app..."
if [[ "${SKIP_WEB_BUILD:-0}" != "1" ]]; then
  (cd "$ROOT_DIR/excalidraw-app" && npx vite build --config vite.config.mts)
fi

if [[ ! -f "$WEB_BUILD_DIR/index.html" ]]; then
  echo "Error: $WEB_BUILD_DIR/index.html not found." >&2
  exit 1
fi

echo "==> 2. Generating macOS AppIcon.icns..."
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
sips -z 16 16     "$SRC_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32     "$SRC_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SRC_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64     "$SRC_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SRC_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256   "$SRC_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512   "$SRC_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$SRC_ICON"    "$ICONSET_DIR/icon_512x512@2x.png"

echo "==> 3. Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/web"
cp "$MACOS_SRC_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "==> 4. Copying web bundle into app Resources..."
cp -R "$WEB_BUILD_DIR/"* "$RESOURCES_DIR/web/"

echo "==> 5. Compiling native Swift launcher + embedded HTTP server..."
swiftc \
  -O \
  -framework Cocoa \
  -framework WebKit \
  -framework Network \
  "$MACOS_SRC_DIR/Sources/main.swift" \
  -o "$MACOS_DIR/$APP_NAME"

echo "==> 6. Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Done! Built: $APP_BUNDLE"
echo "To install in Applications: cp -R \"$APP_BUNDLE\" /Applications/"
