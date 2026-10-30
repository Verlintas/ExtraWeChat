#!/bin/bash
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH="${ARCH:-arm64}"
mkdir -p "$DIR/build"

clang++ -arch "$ARCH" -std=c++17 -fobjc-arc -dynamiclib \
  -framework AppKit \
  -install_name @rpath/libExtraWeChatRuntime.dylib \
  "$DIR/window_privacy.mm" \
  -o "$DIR/build/libExtraWeChatRuntime.dylib"

codesign --force --sign - "$DIR/build/libExtraWeChatRuntime.dylib"
echo "built: $DIR/build/libExtraWeChatRuntime.dylib"
