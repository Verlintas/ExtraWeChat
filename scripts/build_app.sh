#!/bin/bash
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ExtraWeChat.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/app/Resources/Info.plist")"

echo "==> build login dylib"
ARCH="${ARCH:-arm64}" "$ROOT/tools/login_persist/build.sh"

echo "==> build runtime dylib"
ARCH="${ARCH:-arm64}" "$ROOT/tools/runtime/build.sh"

echo "==> build Swift app"
swift build -c release --package-path "$ROOT/app"
BIN="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/ExtraWeChat"
test -x "$BIN"

echo "==> assemble app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/tools"
cp "$BIN" "$APP/Contents/MacOS/ExtraWeChat"
chmod +x "$APP/Contents/MacOS/ExtraWeChat"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"

# Menu-bar template icon (kept outside SwiftPM's resource bundle so the
# packaged app is independent of SwiftPM's bundle layout).
cp "$ROOT/app/Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"

# Python engine (install / patch / locate) + build/profile table
cp "$ROOT/tools/install.py" "$ROOT/tools/patch_copy.py" "$ROOT/tools/locate_revoke.py" \
   "$ROOT/tools/profile_update.py" "$ROOT/tools/switch_mode.py" "$ROOT/tools/backup_copy.py" \
   "$ROOT/tools/revoke_profiles.json" "$APP/Contents/Resources/tools/"
chmod 755 "$APP/Contents/Resources/tools/"*.py

# Login-persistence dylib + user docs
cp "$ROOT/tools/login_persist/build/libExtraWeChatLogin.dylib" \
   "$APP/Contents/Resources/libExtraWeChatLogin.dylib"
cp "$ROOT/tools/runtime/build/libExtraWeChatRuntime.dylib" \
   "$APP/Contents/Resources/libExtraWeChatRuntime.dylib"
cp "$ROOT/tools/login_persist/README.md" \
   "$APP/Contents/Resources/LOGIN-PERSISTENCE.md"
cp "$ROOT/LICENSE" "$ROOT/NOTICE.md" "$ROOT/README.md" "$APP/Contents/Resources/"

echo "==> icon"
ICON_PNG="$ROOT/app/Resources/AppIcon-1024.png"
if [ ! -f "$ICON_PNG" ]; then
  python3 "$ROOT/scripts/make_icon.py"
fi
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$ICON_PNG" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> sign (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> package"
ZIP="$ROOT/build/ExtraWeChat-${VERSION}-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "App: $APP"
echo "Zip: $ZIP"
echo
echo "第一次打开（未公证）请右键 → 打开，或："
echo "  xattr -dr com.apple.quarantine \"$APP\""
