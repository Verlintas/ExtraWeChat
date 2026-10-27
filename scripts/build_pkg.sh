#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ExtraWeChat.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/app/Resources/Info.plist")"
PKG="$ROOT/build/ExtraWeChat-${VERSION}-arm64.pkg"
STAGE="$ROOT/build/pkgroot"
SCRIPTS="$ROOT/scripts/pkg-scripts"

if [ ! -d "$APP" ]; then
  echo "==> app bundle missing; building it first"
  "$ROOT/scripts/build_app.sh"
fi

echo "==> stage package payload"
rm -rf "$STAGE"
mkdir -p "$STAGE/Applications"
ditto "$APP" "$STAGE/Applications/ExtraWeChat.app"

chmod 755 "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"

echo "==> pkgbuild"
rm -f "$PKG"
pkgbuild \
  --root "$STAGE" \
  --identifier "com.extrawechat.pkg" \
  --version "$VERSION" \
  --install-location "/" \
  --scripts "$SCRIPTS" \
  --ownership recommended \
  "$PKG"

# Ad-hoc signing of a flat package is not generally supported. Try it, but
# release the package unsigned if no Developer ID Installer identity exists.
SIGNED="$ROOT/build/ExtraWeChat-${VERSION}-arm64-signed.pkg"
rm -f "$SIGNED"
if productsign --sign - "$PKG" "$SIGNED" >/dev/null 2>&1; then
  mv "$SIGNED" "$PKG"
  echo "==> package signed (ad-hoc)"
else
  rm -f "$SIGNED"
  echo "==> package left unsigned (no Developer ID Installer identity)"
fi

echo "==> verify payload"
pkgutil --payload-files "$PKG" | head -20

echo
echo "Pkg: $PKG"
echo
echo "安装：双击 pkg，或："
echo "  sudo installer -pkg \"$PKG\" -target /"
