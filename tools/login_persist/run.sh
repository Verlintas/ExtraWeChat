#!/bin/bash
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-/Applications/WeChat.app}"
shift || true
DYLD_LIB="$DIR/build/libExtraWeChatLogin.dylib"
if [ ! -f "$DYLD_LIB" ]; then
  echo "missing $DYLD_LIB; run $DIR/build.sh first" >&2
  exit 1
fi
if pgrep -f "$APP/Contents/MacOS/WeChat" >/dev/null 2>&1; then
  echo "WeChat is still running. Quit it completely (⌘Q, wait for helpers), then rerun." >&2
  exit 1
fi
export DYLD_INSERT_LIBRARIES="$DYLD_LIB"
export EXTRAWECHAT_LOGIN_DEBUG="${EXTRAWECHAT_LOGIN_DEBUG:-0}"
exec "$APP/Contents/MacOS/WeChat" "$@"
