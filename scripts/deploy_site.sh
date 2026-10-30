#!/bin/bash
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  cd "$ROOT"
  git worktree remove --force "$TMP" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

cd "$ROOT"
git worktree add --detach "$TMP" >/dev/null
cd "$TMP"
git checkout --orphan gh-pages >/dev/null 2>&1
git rm -rf . >/dev/null 2>&1 || true
cp -R "$ROOT/site/." .
git add -A
git commit -m "Deploy ExtraWeChat website" >/dev/null
git push origin gh-pages --force

echo
echo "Deployed: https://verlintas.dev/ExtraWeChat/"
