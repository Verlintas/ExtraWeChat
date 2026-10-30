#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""
install.py — install/restore ExtraWeChat's binary patches on a real WeChat.app.

This is the non-PoC installer used by the GUI. It:
  - backs up the original wechat.dylib and entitlements;
  - patches the anti-revoke point(s);
  - re-signs every code object with preserved entitlements;
  - verifies with codesign;
  - can restore the original dylib and re-sign.

It refuses to run while WeChat is running. For testing, point --app at a copy;
the GUI uses a copy by default for "test", and asks before touching
/Applications/WeChat.app.

Usage:
    python3 tools/install.py status [--app /Applications/WeChat.app] [--json]
    python3 tools/install.py install --variant silent|keeptip|none \
        [--app ...] [--allow-dyld-env] [--get-task-allow]
    python3 tools/install.py restore [--app ...]
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import locate_revoke as L  # noqa: E402
import patch_copy as P  # noqa: E402

DATA_DIR = os.path.expanduser("~/Library/Application Support/ExtraWeChat")
BACKUP_ROOT = os.path.join(DATA_DIR, "backups")
MANIFEST = "manifest.json"
ORIGINAL_DYLIB = "wechat.dylib.orig"
ENTITLEMENTS = "entitlements.json"


def permission_help(app: str) -> str:
    return f"""\
没有权限修改 {app}。

这通常是以下两种情况之一：

1. 微信安装在 /Applications，文件属主是 root:wheel，普通用户无法写入。
   - GUI：ExtraWeChat 会弹出 macOS 管理员授权对话框，以 root 执行安装/还原；
   - CLI：请使用 sudo 运行 install.py。
2. macOS「App 管理」权限（TCC）仍可能拦截：
   系统设置 → 隐私与安全性 → App 管理 → 打开 ExtraWeChat。
   如果列表里没有 ExtraWeChat：
   - 把 ExtraWeChat.app 放到 /Applications 并启动一次；
   - 再点一次安装，系统应弹出授权提示；
   - 仍然没有的话，点「+」手动添加 ExtraWeChat.app。
   命令行使用时，还需要给终端同样的权限。

注意：sudo 不能绕过「App 管理」权限；两步都需要满足。

如果两层权限都满足仍然被 macOS 拦截，请改用 ExtraWeChat 的「补丁副本」模式：
它不修改 /Applications/WeChat.app，不需要 root 或 App 管理权限。
"""


def is_permission_error(error: BaseException) -> bool:
    if isinstance(error, PermissionError):
        return True
    text = str(error).lower()
    return ("operation not permitted" in text
            or "permission denied" in text
            or "errno 1" in text
            or "errno 13" in text)


def app_info(app: str) -> dict:
    info = L.read_app_info(app)
    if not info:
        raise SystemExit(f"not a WeChat.app: {app}")
    return info


def dylib_path(app: str) -> str:
    return os.path.join(app, "Contents", "Resources", "wechat.dylib")


def backup_dir(app: str) -> str:
    info = app_info(app)
    build = info.get("build") or "unknown"
    bundle = (info.get("bundle_id") or "unknown").replace("/", "_")
    return os.path.join(BACKUP_ROOT, f"{bundle}-{build}")


def running(app: str) -> bool:
    return P.app_running(app)


def snapshot_entitlements(app: str) -> dict:
    out = {}
    for path in P.candidates(app):
        ent = P.entitlements(path)
        if ent is None:
            continue
        out[os.path.relpath(path, app)] = base64.b64encode(ent).decode("ascii")
    return out


def original_entitlements(app: str, bdir: str) -> list[tuple[str, bytes | None]] | None:
    """Load the exact entitlements snapshot taken before the first install."""
    path = os.path.join(bdir, ENTITLEMENTS)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return None
    snap: list[tuple[str, bytes | None]] = []
    for rel, encoded in data.items():
        target = os.path.join(app, rel)
        if not os.path.exists(target):
            continue
        snap.append((target, base64.b64decode(encoded)))
    return snap or None


def restore_entitlements(app: str) -> list[tuple[str, bytes | None]]:
    """Re-sign with the original profiles minus debug-only entitlements."""
    snap: list[tuple[str, bytes | None]] = []
    for path in P.candidates(app):
        ent = P.entitlements(path)
        if ent is None:
            continue
        d = plistlib.loads(ent) if ent.strip() else {}
        d.pop("com.apple.security.cs.allow-dyld-environment-variables", None)
        d.pop("com.apple.security.get-task-allow", None)
        for k in list(d):
            if k.startswith("com.apple.developer."):
                del d[k]
        for k, v in P.INJECTED_ENTITLEMENTS.items():
            d[k] = v
        snap.append((path, plistlib.dumps(d, fmt=plistlib.FMT_XML)))
    return snap


def read_manifest(bdir: str) -> dict:
    path = os.path.join(bdir, MANIFEST)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def write_manifest(bdir: str, data: dict) -> None:
    os.makedirs(bdir, exist_ok=True)
    path = os.path.join(bdir, MANIFEST)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def ensure_backup(app: str) -> str:
    bdir = backup_dir(app)
    os.makedirs(bdir, exist_ok=True)
    orig = os.path.join(bdir, ORIGINAL_DYLIB)
    if not os.path.exists(orig):
        # Only back up a pristine dylib. If it is already patched by us, the
        # manifest/backup should already exist; otherwise refuse.
        info = app_info(app)
        located = P.locate_in_dylib(dylib_path(app), build=info.get("build"))
        silent_ok = located["silent_state"] == "pristine"
        keeptip_ok = located["keeptip_state"] in ("pristine", "unsupported")
        if not silent_ok or not keeptip_ok:
            raise SystemExit(
                "wechat.dylib is already patched but no original backup exists; "
                "reinstall WeChat or restore from a previous backup first"
            )
        shutil.copy2(dylib_path(app), orig)
        print(f"[backup] {orig}")
    ent_path = os.path.join(bdir, ENTITLEMENTS)
    if not os.path.exists(ent_path):
        with open(ent_path, "w", encoding="utf-8") as f:
            json.dump(snapshot_entitlements(app), f, ensure_ascii=False, indent=2)
    return bdir


def current_state(app: str) -> dict:
    dylib = dylib_path(app)
    info = app_info(app)
    bdir = backup_dir(app)
    manifest = read_manifest(bdir)
    result = {
        "app": app,
        "bundle_id": info.get("bundle_id"),
        "short_version": info.get("short_version"),
        "build": info.get("build"),
        "channel": info.get("channel"),
        "backup_dir": bdir,
        "has_backup": os.path.exists(os.path.join(bdir, ORIGINAL_DYLIB)),
        "manifest": manifest,
        "running": running(app),
    }
    try:
        located = P.locate_in_dylib(dylib, build=info.get("build"))
        result.update({
            "generation": located["generation"],
            "match": located.get("match"),
            "arch": located.get("arch"),
            "silent_va": f"{located['silent_va']:x}",
            "silent_state": located["silent_state"],
            "keeptip_state": located["keeptip_state"],
            "silent_current": located["silent_current"],
            "keeptip_current": located["keeptip_current"],
        })
        if located["silent_state"] == "patched-silent":
            result["patch_state"] = "silent"
        elif located["keeptip_state"] == "patched-keeptip":
            result["patch_state"] = "keeptip"
        else:
            result["patch_state"] = "pristine"
    except SystemExit as e:
        result["patch_state"] = "unsupported"
        result["error"] = str(e)
    return result


def verify(app: str) -> bool:
    r = P.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    print(r.stderr.strip())
    return r.returncode == 0


def do_install(args) -> int:
    app = os.path.abspath(os.path.expanduser(args.app))
    if not os.path.isdir(app):
        raise SystemExit(f"not found: {app}")
    if running(app):
        raise SystemExit("WeChat is running; quit it completely before install")
    info = app_info(app)
    dylib = dylib_path(app)
    located = P.locate_in_dylib(dylib, build=info.get("build"))
    bdir = ensure_backup(app)
    print(f"[info] {info.get('short_version')} build {info.get('build')} ({info.get('channel')})")
    print(f"[info] variant={args.variant} allow_dyld_env={args.allow_dyld_env}")

    extra = {}
    if args.allow_dyld_env:
        extra["com.apple.security.cs.allow-dyld-environment-variables"] = True
    if args.get_task_allow:
        extra["com.apple.security.get-task-allow"] = True
    extra = extra or None

    orig = os.path.join(bdir, ORIGINAL_DYLIB)
    try:
        if args.variant != "none":
            P.patch_anti_revoke(dylib, located, args.variant)
        snap = P.prepare_signing(app, strip_sandbox=False, extra=extra)
        P.sign_all(app, snap)
        if not verify(app):
            raise SystemExit("codesign verification failed")
    except BaseException:
        # Never leave a patched-but-unsealed app behind. Prefer the original
        # dylib plus the exact entitlements snapshot; fall back to a fresh
        # signature if the snapshot is unavailable.
        if os.path.exists(orig):
            print("[rollback] restoring original dylib and signature", file=sys.stderr)
            try:
                shutil.copy2(orig, dylib)
                rollback_snap = original_entitlements(app, bdir) or restore_entitlements(app)
                P.sign_all(app, rollback_snap)
                verify(app)
            except Exception as rollback_error:
                print(f"[rollback] failed: {rollback_error}", file=sys.stderr)
        raise
    write_manifest(bdir, {
        "app": app,
        "bundle_id": info.get("bundle_id"),
        "build": info.get("build"),
        "variant": args.variant,
        "allow_dyld_env": bool(args.allow_dyld_env),
        "get_task_allow": bool(args.get_task_allow),
        "installed_at": int(time.time()),
        "backup_dir": bdir,
    })
    print("[done] installed and verified")
    return 0


def do_restore(args) -> int:
    app = os.path.abspath(os.path.expanduser(args.app))
    if running(app):
        raise SystemExit("WeChat is running; quit it completely before restore")
    bdir = backup_dir(app)
    orig = os.path.join(bdir, ORIGINAL_DYLIB)
    if not os.path.exists(orig):
        raise SystemExit(f"no backup found at {orig}; reinstall WeChat if needed")
    shutil.copy2(orig, dylib_path(app))
    print(f"[restore] wrote {orig} -> {dylib_path(app)}")
    snap = original_entitlements(app, bdir) or restore_entitlements(app)
    P.sign_all(app, snap)
    if not verify(app):
        raise SystemExit("codesign verification failed")
    manifest = read_manifest(bdir)
    manifest["restored_at"] = int(time.time())
    manifest["variant"] = "none"
    write_manifest(bdir, manifest)
    print("[done] restored and verified")
    return 0


def do_status(args) -> int:
    app = os.path.abspath(os.path.expanduser(args.app))
    result = current_state(app)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"App:        {result['app']}")
        print(f"WeChat:     {result.get('short_version')} build {result.get('build')} ({result.get('channel')})")
        print(f"Running:    {result['running']}")
        print(f"Patch:      {result.get('patch_state')} ({result.get('generation', 'n/a')})")
        print(f"Backup:     {result['backup_dir']} ({'yes' if result['has_backup'] else 'no'})")
        print(f"Manifest:   {result.get('manifest')}")
        if result.get("error"):
            print(f"Error:      {result['error']}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Install/restore ExtraWeChat patches")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("install")
    p.add_argument("--app", default="/Applications/WeChat.app")
    p.add_argument("--variant", choices=["silent", "keeptip", "none"], default="silent")
    p.add_argument("--allow-dyld-env", action="store_true")
    p.add_argument("--get-task-allow", action="store_true")
    p.set_defaults(func=do_install)

    p = sub.add_parser("restore")
    p.add_argument("--app", default="/Applications/WeChat.app")
    p.set_defaults(func=do_restore)

    p = sub.add_parser("status")
    p.add_argument("--app", default="/Applications/WeChat.app")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=do_status)

    args = ap.parse_args()
    try:
        return args.func(args)
    except SystemExit:
        raise
    except Exception as error:
        if is_permission_error(error):
            print(permission_help(getattr(args, "app", "/Applications/WeChat.app")),
                  file=sys.stderr)
            return 3
        if isinstance(error, P.Error):
            print(f"[error] {error}", file=sys.stderr)
            return 1
        raise


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
