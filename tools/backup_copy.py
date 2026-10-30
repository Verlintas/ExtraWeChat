#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""
backup_copy.py — local backups of the patched WeChat copy (app bundle only).

It does NOT copy the WeChat data container, chat history, media or login keys.
Only ~/Applications/WeChatExtra.app is cloned, using APFS copy-on-write when
possible. Restore replaces only that app bundle; chat data is untouched.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patch_copy as P  # noqa: E402

DEFAULT_SOURCE = os.path.expanduser("~/Applications/WeChatExtra.app")
DEFAULT_ROOT = os.path.expanduser(
    "~/Library/Application Support/ExtraWeChat/backups/copies"
)


def clone_tree(src: str, dst: str) -> str:
    """APFS clone if possible, otherwise ditto. Returns method name."""
    r = subprocess.run(
        ["/bin/cp", "-cR", src, dst],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        return "apfs-clone"
    if os.path.exists(dst):
        shutil.rmtree(dst)
    r = subprocess.run(
        ["/usr/bin/ditto", src, dst],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise P.Error(f"copy failed: {r.stderr.strip()}")
    return "ditto"


def size_bytes(path: str) -> int:
    r = subprocess.run(
        ["/usr/bin/du", "-sk", path],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return 0
    try:
        return int(r.stdout.split()[0]) * 1024
    except (IndexError, ValueError):
        return 0


def read_manifest(backup_dir: str) -> dict:
    path = os.path.join(backup_dir, "manifest.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def write_manifest(backup_dir: str, data: dict) -> None:
    path = os.path.join(backup_dir, "manifest.json")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(path + ".tmp", path)


def safe_name(name: str) -> str:
    return "".join(c for c in name if c.isalnum() or c in "-_.").strip(".") or "backup"


def create(source: str, root: str, name: str | None = None) -> dict:
    source = os.path.abspath(os.path.expanduser(source))
    root = os.path.abspath(os.path.expanduser(root))
    if not os.path.isdir(source):
        raise P.Error(f"copy not found: {source}")
    if P.app_running(source):
        raise P.Error("补丁副本仍在运行，请先完全退出副本再备份")

    stamp = name or time.strftime("%Y%m%d-%H%M%S")
    base = safe_name(stamp)
    backup_dir = os.path.join(root, base)
    suffix = 1
    while os.path.exists(backup_dir):
        backup_dir = os.path.join(root, f"{base}-{suffix}")
        suffix += 1
    os.makedirs(backup_dir, mode=0o700)

    app_name = os.path.basename(source)
    dest_app = os.path.join(backup_dir, app_name)
    method = clone_tree(source, dest_app)
    info = P.app_info(source)
    manifest = {
        "name": os.path.basename(backup_dir),
        "created_at": int(time.time()),
        "source": source,
        "app": dest_app,
        "app_name": app_name,
        "bundle_id": info.get("bundle_id"),
        "short_version": info.get("short_version"),
        "build": info.get("build"),
        "size_bytes": size_bytes(dest_app),
        "method": method,
        "kind": "app-only",
        "path": backup_dir,
    }
    write_manifest(backup_dir, manifest)
    return manifest


def list_backups(root: str) -> list[dict]:
    root = os.path.abspath(os.path.expanduser(root))
    if not os.path.isdir(root):
        return []
    out = []
    for name in os.listdir(root):
        backup_dir = os.path.join(root, name)
        if not os.path.isdir(backup_dir) or name.startswith("."):
            continue
        manifest = read_manifest(backup_dir)
        if not manifest:
            continue
        manifest["path"] = backup_dir
        out.append(manifest)
    out.sort(key=lambda x: x.get("created_at", 0), reverse=True)
    return out


def delete(root: str, name: str) -> dict:
    root = os.path.abspath(os.path.expanduser(root))
    target = os.path.abspath(os.path.join(root, safe_name(name)))
    if os.path.dirname(target) != root or not os.path.isdir(target):
        raise P.Error(f"backup not found: {name}")
    shutil.rmtree(target)
    return {"status": "deleted", "name": os.path.basename(target)}


def verify_app(path: str) -> None:
    r = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", path],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise P.Error(
            "backup app signature verification failed:\n"
            + (r.stderr or r.stdout)
        )


def restore(source: str, root: str, name: str | None, latest: bool,
            skip_verify: bool = False) -> dict:
    source = os.path.abspath(os.path.expanduser(source))
    root = os.path.abspath(os.path.expanduser(root))
    if P.app_running(source):
        raise P.Error("补丁副本仍在运行，请先完全退出副本再恢复")
    backups = list_backups(root)
    if not backups:
        raise P.Error("没有可用的副本备份")
    if latest or not name:
        chosen = backups[0]
    else:
        chosen = next((b for b in backups if b["name"] == name), None)
        if chosen is None:
            raise P.Error(f"backup not found: {name}")
    backup_app = chosen.get("app") or os.path.join(chosen["path"], chosen["app_name"])
    if not os.path.isdir(backup_app):
        raise P.Error(f"backup app missing: {backup_app}")
    if not skip_verify:
        verify_app(backup_app)

    rollback = source + f".before-restore-{int(time.time())}"
    os.rename(source, rollback)
    try:
        method = clone_tree(backup_app, source)
        if not skip_verify:
            verify_app(source)
    except BaseException:
        if os.path.exists(source):
            shutil.rmtree(source, ignore_errors=True)
        os.rename(rollback, source)
        raise
    shutil.rmtree(rollback, ignore_errors=True)
    return {
        "status": "restored",
        "name": chosen["name"],
        "source": source,
        "build": chosen.get("build"),
        "method": method,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Backup/restore the patched WeChat copy")
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--source", default=DEFAULT_SOURCE)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("create")
    p.add_argument("--name")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("list")
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("restore")
    p.add_argument("--name")
    p.add_argument("--latest", action="store_true")
    p.add_argument("--skip-verify", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--json", action="store_true")

    p = sub.add_parser("delete")
    p.add_argument("--name", required=True)
    p.add_argument("--json", action="store_true")

    args = ap.parse_args()
    try:
        if args.cmd == "create":
            result = create(args.source, args.root, args.name)
        elif args.cmd == "list":
            result = list_backups(args.root)
        elif args.cmd == "restore":
            result = restore(args.source, args.root, args.name, args.latest,
                             args.skip_verify)
        else:
            result = delete(args.root, args.name)
    except (P.Error, OSError) as error:
        print(json.dumps({"status": "error", "error": str(error)},
                         ensure_ascii=False) if getattr(args, "json", False)
              else f"[error] {error}", file=sys.stderr)
        return 1

    if getattr(args, "json", False):
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif isinstance(result, list):
        for item in result:
            print(f"{item.get('name')}  {item.get('build')}  "
                  f"{item.get('size_bytes', 0) // 1024 // 1024} MB")
    else:
        print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
