#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH="${ARCH:-arm64}"
mkdir -p "$DIR/build"
clang -arch "$ARCH" -c "$DIR/vendor/fishhook.c" -o "$DIR/build/fishhook-$ARCH.o"
clang++ -arch "$ARCH" -std=c++17 -fobjc-arc -dynamiclib \
  -install_name @rpath/libExtraWeChatLogin.dylib \
  -framework Foundation -I"$DIR" \
  "$DIR/login_persist.mm" "$DIR/build/fishhook-$ARCH.o" \
  -o "$DIR/build/libExtraWeChatLogin.dylib"
codesign --force --sign - "$DIR/build/libExtraWeChatLogin.dylib"
echo "built: $DIR/build/libExtraWeChatLogin.dylib"
