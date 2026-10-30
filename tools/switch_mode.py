#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""
switch_mode.py — change silent/keeptip inside an existing patched copy.

Unlike patch_copy.py this does not copy the 1.5 GB WeChat.app. It only rewrites
the few patch bytes in the copy's wechat.dylib and re-signs the dylib + app root.
The copy must be quit first.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import locate_revoke as L  # noqa: E402
import patch_copy as P  # noqa: E402


def read_entries(dylib: str, entries: list[dict]) -> list[str]:
    with open(dylib, "rb") as f:
        data = f.read()
    sl, _slice_off, arch = L.macho_slice(data, "auto")
    if arch != "arm64":
        raise P.Error(f"unsupported target architecture {arch}")
    segments, _sections = L.parse_macho(sl)
    values = []
    for entry in entries:
        va = int(entry["va"])
        patch = bytes.fromhex(entry["patch"])
        off = L.va_to_off(segments, va)
        if off is None or off + len(patch) > len(sl):
            raise P.Error(f"VA 0x{va:x} is not file-backed")
        values.append(sl[off:off + len(patch)].hex().upper())
    return values


def sign_copy(app: str, dylib: str) -> None:
    dylib_ent = P.entitlements(dylib)
    app_ent = P.entitlements(app)
    P.codesign(dylib, dylib_ent)
    P.codesign(app, app_ent)
    result = P.run([
        "/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app
    ])
    if result.returncode != 0:
        raise P.Error(
            "codesign verification failed after re-signing:\n"
            + (result.stderr or result.stdout)
        )


def switch(app: str, variant: str, dry_run: bool = False) -> dict:
    app = os.path.abspath(os.path.expanduser(app))
    if not os.path.isdir(app):
        raise P.Error(f"not found: {app}")
    if P.app_running(app):
        raise P.Error("补丁副本仍在运行，请先完全退出副本")
    info = P.app_info(app)
    dylib = os.path.join(app, "Contents", "Resources", "wechat.dylib")
    if not os.path.exists(dylib):
        raise P.Error(f"missing dylib: {dylib}")

    located = P.locate_in_dylib(dylib, build=info.get("build"))
    entries = located.get("entries", {}).get(variant, [])
    if not entries:
        hint = "；该构建只支持 silent" if variant == "keeptip" else ""
        raise P.Error(f"no {variant} entries for build {info.get('build')}{hint}")

    before = read_entries(dylib, entries)
    already = all(a == e["patch"] for a, e in zip(before, entries))
    if already:
        return {
            "status": "already",
            "variant": variant,
            "build": info.get("build"),
            "app": app,
        }

    if dry_run:
        return {
            "status": "dry-run",
            "variant": variant,
            "build": info.get("build"),
            "app": app,
            "entries": len(entries),
            "current": before,
            "target": [e["patch"] for e in entries],
        }

    started = time.time()
    P.patch_anti_revoke(dylib, located, variant)
    try:
        sign_copy(app, dylib)
    except BaseException:
        # Put the previous bytes back and re-seal the copy.
        rollback = [
            {
                "va": entry["va"],
                "expected": [entry["patch"]],
                "patch": old,
            }
            for entry, old in zip(entries, before)
        ]
        try:
            P.patch_entries(dylib, rollback, "rollback")
            sign_copy(app, dylib)
        except Exception as rollback_error:
            raise P.Error(f"switch failed and rollback failed: {rollback_error}")
        raise

    return {
        "status": "switched",
        "variant": variant,
        "build": info.get("build"),
        "app": app,
        "seconds": round(time.time() - started, 2),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Switch anti-revoke mode in a copy")
    ap.add_argument("--app", required=True, help="patched copy of WeChat.app")
    ap.add_argument("--variant", choices=["silent", "keeptip"], required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    try:
        result = switch(args.app, args.variant, args.dry_run)
    except (P.Error, SystemExit) as error:
        if args.json:
            print(json.dumps({"status": "error", "error": str(error)},
                             ensure_ascii=False, indent=2))
        else:
            print(f"[error] {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"[switch] {result['status']} {result['variant']} "
              f"build={result['build']}")
        if "seconds" in result:
            print(f"[switch] took {result['seconds']}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
