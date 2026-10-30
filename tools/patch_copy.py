#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""
patch_copy.py — experimental proof-of-concept: patch and ad-hoc re-sign a COPY
of WeChat.app. It never writes to the source app.

This exists to make the feasibility test in docs/TEST-REPORT.md reproducible.
It is not an installer and it is not the final ExtraWeChat CLI.

What it does
------------
1. Copies the source app with `ditto` to --output.
2. Locates the anti-revoke points inside the copy's
   Contents/Resources/wechat.dylib using the same geometry as
   tools/locate_revoke.py.
3. Optionally applies the `silent` or `keeptip` patch:
     silent  : `cbz w0, SKIP` -> `b SKIP` (message stays, no recall tip)
     keeptip : restore the `cbz`, then `str x0,[x19,#newmsgid]` -> `str xzr,...`
               (message stays, private-chat tip still renders)
4. Optionally turns the copy into a multi-instance clone:
     --clone NAME changes CFBundleIdentifier/CFBundleDisplayName and strips
     the sandbox / application-identifier / app-group entitlements so the clone
     can use its own data directory. This is what made a second instance launch
     in the copy test.
5. Re-signs every signed code object, preserving the original entitlements and
   injecting the two Hardened Runtime exceptions needed by an ad-hoc build.
6. Verifies with `codesign --verify --deep --strict`.

Safety
------
- Refuses to use /Applications/WeChat.app as --output or to write inside the
  source bundle.
- Does not kill WeChat and does not launch the result.
- The copy is only as good as the patch-point table for its exact build. Wrong
  build -> expected-byte mismatch -> refusal before any write.

Usage
-----
    # anti-revoke test copy, keeps the original bundle ID and sandbox
    python3 tools/patch_copy.py \
        --output ~/Applications/WeChat-Test.app \
        --variant silent

    # isolated second instance (new bundle ID, own fake home)
    python3 tools/patch_copy.py \
        --output ~/Applications/WeChat-2.app \
        --variant none --clone 2

Then launch the printed command. The final ExtraWeChat CLI will wrap this in a
proper installer with backup/restore and a menu-bar UI.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import locate_revoke as L  # noqa: E402

INJECTED_ENTITLEMENTS = {
    "com.apple.security.cs.disable-library-validation": True,
    "com.apple.security.cs.allow-unsigned-executable-memory": True,
}
SANDBOX_KEYS = {
    "com.apple.security.app-sandbox",
    "com.apple.application-identifier",
    "com.apple.security.application-groups",
}
BUNDLE_EXTS = {".app", ".appex", ".bundle", ".framework", ".plugin", ".service", ".xpc"}
LOOSE_EXTS = {".dylib", ".so"}


class Error(RuntimeError):
    pass


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


def app_info(app: str) -> dict:
    info = L.read_app_info(app)
    if not info:
        raise Error(f"not a WeChat.app bundle: {app}")
    return info


def app_running(app: str) -> bool:
    needle = os.path.join(app, "Contents", "MacOS") + os.sep
    r = run(["/usr/bin/pgrep", "-f", needle])
    return r.returncode == 0


def copy_app(src: str, dst: str, force: bool) -> None:
    if os.path.exists(dst):
        if not force:
            raise Error(f"output already exists: {dst} (use --force to replace)")
        if os.path.isdir(dst) and not os.path.islink(dst):
            shutil.rmtree(dst)
        else:
            os.unlink(dst)
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    r = run(["/usr/bin/ditto", src, dst])
    if r.returncode != 0:
        raise Error(f"ditto failed:\n{r.stderr}")


def locate_in_dylib(dylib: str, build: str | None = None) -> dict:
    with open(dylib, "rb") as f:
        data = f.read()
    sl, slice_off, arch = L.macho_slice(data, "auto")
    segments, sections = L.parse_macho(sl)
    result = L.locate_with_profile(sl, segments, sections, build, arch)
    result["slice_offset"] = slice_off
    result["arch"] = arch
    return result


def patch_entries(dylib: str, entries: list[dict], label: str) -> None:
    """entries: [{"va": int, "expected": [hex, ...], "patch": hex}]."""
    with open(dylib, "r+b") as f:
        data = f.read()
        sl, slice_off, arch = L.macho_slice(data, "auto")
        if arch != "arm64":
            raise Error(f"{label}: unsupported target architecture {arch}")
        segments, _sections = L.parse_macho(sl)
        for entry in entries:
            va = int(entry["va"])
            replacement = bytes.fromhex(entry["patch"])
            accepted = [bytes.fromhex(x) for x in entry["expected"]]
            off = L.va_to_off(segments, va)
            if off is None:
                raise Error(f"{label}: VA 0x{va:x} is not file-backed")
            absolute = slice_off + off
            f.seek(absolute)
            original = f.read(len(replacement))
            if original == replacement:
                print(f"[{label}] VA 0x{va:x} already patched — skipping")
                continue
            if original not in accepted:
                raise Error(
                    f"{label}: unexpected bytes at VA 0x{va:x}: "
                    f"{original.hex().upper()} (want one of "
                    f"{' / '.join(x.hex().upper() for x in accepted)}) — wrong build? refusing to write"
                )
            f.seek(absolute)
            f.write(replacement)
            print(f"[{label}] VA 0x{va:x} -> 0x{absolute:x}: "
                  f"{original.hex().upper()} -> {replacement.hex().upper()}")
        f.flush()
        os.fsync(f.fileno())


def patch_anti_revoke(dylib: str, located: dict, variant: str) -> None:
    if variant == "none":
        print("[patch] anti-revoke disabled (--variant none)")
        return
    entries = located.get("entries", {}).get(variant, [])
    if not entries:
        raise Error(f"no {variant} patch entries for this WeChat build")
    patch_entries(dylib, entries, variant)


def set_plist_values(path: str, values: dict) -> None:
    with open(path, "rb") as f:
        data = plistlib.load(f)
    data.update(values)
    with open(path, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)


def candidates(app: str) -> list[str]:
    out = [app]
    seen = {os.path.realpath(app)}
    for root, dirs, files in os.walk(app, followlinks=False):
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
        for d in dirs:
            p = os.path.join(root, d)
            if os.path.splitext(d)[1].lower() in BUNDLE_EXTS:
                rp = os.path.realpath(p)
                if rp not in seen:
                    seen.add(rp)
                    out.append(p)
        for fn in files:
            p = os.path.join(root, fn)
            if os.path.islink(p):
                continue
            ext = os.path.splitext(fn)[1].lower()
            if ext in LOOSE_EXTS or (os.access(p, os.X_OK) and not fn.startswith(".")):
                rp = os.path.realpath(p)
                if rp not in seen:
                    seen.add(rp)
                    out.append(p)
    return out


def entitlements(path: str) -> bytes | None:
    r = run(["/usr/bin/codesign", "-d", "--entitlements", ":-", "--xml", path])
    if r.returncode != 0:
        return None  # unsigned or not code
    return r.stdout.encode() if r.stdout else b""


def normalize_entitlements(data: bytes | None, strip_sandbox: bool,
                           extra: dict | None = None) -> bytes | None:
    if not data or not data.strip():
        return data
    d = plistlib.loads(data)
    for k in list(d):
        if k.startswith("com.apple.developer."):
            del d[k]
        elif strip_sandbox and k in SANDBOX_KEYS:
            del d[k]
    for k, v in INJECTED_ENTITLEMENTS.items():
        d[k] = v
    if extra:
        for k, v in extra.items():
            d[k] = v
    return plistlib.dumps(d, fmt=plistlib.FMT_XML)


def codesign(path: str, ent: bytes | None) -> None:
    args = [
        "/usr/bin/codesign",
        "--force",
        "--sign", "-",
        "--preserve-metadata=identifier,flags,runtime",
    ]
    tmp = None
    if ent:
        fd, tmp = tempfile.mkstemp(suffix=".plist")
        with os.fdopen(fd, "wb") as f:
            f.write(ent)
        # macOS 15+ needs this to keep entitlements on nested libraries.
        major = int(platform.mac_ver()[0].split(".")[0])
        if major >= 15:
            args.append("--force-library-entitlements")
        args += ["--entitlements", tmp]
    args.append(path)
    r = run(args)
    if tmp:
        os.unlink(tmp)
    if r.returncode != 0:
        raise Error(f"codesign failed for {path}\n{r.stderr}\n{r.stdout}")


def prepare_signing(app: str, strip_sandbox: bool,
                    extra: dict | None = None) -> list[tuple[str, bytes | None]]:
    snap: list[tuple[str, bytes | None]] = []
    for path in candidates(app):
        ent = entitlements(path)
        if ent is None:
            continue
        snap.append((path, normalize_entitlements(ent, strip_sandbox, extra)))
    return snap


def sign_all(app: str, snap: list[tuple[str, bytes | None]]) -> None:
    # deepest first; root last. A second root pass is cheap and works around
    # the "nested code is modified or invalid" state observed after a single
    # root seal in the copy test.
    ordered = sorted(snap, key=lambda x: (x[0] != app, -x[0].count(os.sep), x[0]))
    print(f"[sign] {len(ordered)} code objects ({sum(1 for _, e in ordered if e)} with entitlements)")
    for path, ent in ordered:
        codesign(path, ent)
    root_ent = dict(ordered).get(app)
    codesign(app, root_ent)
    r = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    if r.returncode != 0:
        print("[sign] first verify failed; re-signing the root once")
        codesign(app, root_ent)
        r = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    print(r.stderr.strip())
    if r.returncode != 0:
        raise Error("codesign --verify --deep --strict failed; refusing to call this a success")


def slugify(value: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-").lower()
    return slug or "2"


def main() -> None:
    ap = argparse.ArgumentParser(description="Patch and re-sign a COPY of WeChat.app (experimental)")
    ap.add_argument("--app", default="/Applications/WeChat.app", help="source WeChat.app")
    ap.add_argument("--output", required=True, help="destination .app (must differ from --app)")
    ap.add_argument("--variant", choices=["silent", "keeptip", "none"], default="silent",
                    help="anti-revoke variant; 'none' only clones/re-signs")
    ap.add_argument("--clone", metavar="NAME",
                    help="turn the copy into a multi-instance clone with a new bundle ID")
    ap.add_argument("--instance-home", help="data home for --clone (default: ~/Library/Application Support/ExtraWeChat/Instances/NAME)")
    ap.add_argument("--get-task-allow", action="store_true",
                    help="inject com.apple.security.get-task-allow (debug/Frida; experimental)")
    ap.add_argument("--allow-dyld-env", action="store_true",
                    help="inject com.apple.security.cs.allow-dyld-environment-variables "
                         "(needed for DYLD_INSERT_LIBRARIES login-persistence dylib)")
    ap.add_argument("--force", action="store_true", help="replace an existing --output")
    args = ap.parse_args()

    src = os.path.realpath(os.path.expanduser(args.app))
    dst = os.path.abspath(os.path.expanduser(args.output))
    if not os.path.isdir(src):
        raise SystemExit(f"source app not found: {src}")
    if src == dst or dst.startswith(src + os.sep):
        raise SystemExit("refusing to write inside the source app; choose a separate --output")
    if os.path.basename(dst) != "WeChat.app" and not dst.endswith(".app"):
        raise SystemExit("--output must be an .app bundle")
    if app_running(src):
        print("[note] WeChat is running. Copying is safe; the copy will not be launched by this tool.")

    info = app_info(src)
    print(f"[info] source: {src}")
    print(f"[info] WeChat {info.get('short_version')} build {info.get('build')} "
          f"({info.get('channel')}, {info.get('bundle_id')})")
    print(f"[info] output: {dst}")

    print("[copy] ditto …")
    copy_app(src, dst, args.force)

    dylib = os.path.join(dst, "Contents", "Resources", "wechat.dylib")
    located = None
    if args.variant != "none":
        located = locate_in_dylib(dylib, build=info.get("build"))
        print(f"[locate] {located['generation']}, E=0x{located['entry_va']:x}, "
              f"silent=0x{located['silent_va']:x}, keeptip=0x{located['keeptip_va']:x}")

    # Snapshot entitlements before changing Info.plist; the old signature still
    # carries them.
    strip_sandbox = bool(args.clone)
    extra_ent = {}
    if args.get_task_allow:
        extra_ent["com.apple.security.get-task-allow"] = True
    if args.allow_dyld_env:
        extra_ent["com.apple.security.cs.allow-dyld-environment-variables"] = True
    extra_ent = extra_ent or None
    snap = prepare_signing(dst, strip_sandbox, extra_ent)

    if args.clone:
        name = args.clone.strip()
        slug = slugify(name)
        new_id = f"com.tencent.xinWeChat.extrawechat.instance-{slug}"
        set_plist_values(os.path.join(dst, "Contents", "Info.plist"), {
            "CFBundleIdentifier": new_id,
            "CFBundleDisplayName": f"微信 ({name})",
            "CFBundleName": f"WeChat-{slug}",
        })
        print(f"[clone] bundle id -> {new_id}; sandbox/application-id/app-group entitlements stripped")
        if args.instance_home:
            home = os.path.abspath(os.path.expanduser(args.instance_home))
        else:
            home = os.path.expanduser(f"~/Library/Application Support/ExtraWeChat/Instances/{slug}")
        os.makedirs(os.path.join(home, "Documents"), exist_ok=True)
        os.makedirs(os.path.join(home, "Library", "Containers"), exist_ok=True)
        launch = (
            f"open -n --env CFFIXED_USER_HOME={shlex.quote(home)} "
            f"--env HOME={shlex.quote(home)} {shlex.quote(dst)}"
        )
        print(f"[clone] instance home: {home}")
    else:
        launch = f"open -n {shlex.quote(dst)}"

    patch_anti_revoke(dylib, located, args.variant)
    sign_all(dst, snap)

    print()
    print("[done] copy is patched, re-signed and verified.")
    print(f"[launch] {launch}")
    if args.clone:
        print("[note] the clone has its own data store and will ask you to log in.")
    else:
        print("[note] this copy shares the original bundle ID/container. Quit WeChat before launching it.")
    print("[note] real anti-revoke behaviour still needs a live incoming recall test.")
    print("[note] experimental copy only — do not distribute a patched WeChat.app.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(130)
    except (Error, SystemExit) as e:
        if isinstance(e, SystemExit):
            raise
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
