#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""
profile_update.py — fetch and validate the remote anti-revoke build profile table.

The app ships with tools/revoke_profiles.json. This tool can replace it with a
newer table from the ExtraWeChat main branch without shipping a new app:

  ~/Library/Application Support/ExtraWeChat/profiles/revoke_profiles.json

The remote JSON and its .sha256 are fetched over HTTPS; the SHA is checked
before the file is written. The locator still verifies every patch byte against
the actual WeChat dylib before writing anything.

Usage:
    python3 tools/profile_update.py check --json
    python3 tools/profile_update.py update --json
    python3 tools/profile_update.py update --from-file /path/to/profiles.json
    python3 tools/profile_update.py reset
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

DEFAULT_URL = (
    "https://raw.githubusercontent.com/Verlintas/ExtraWeChat/main/"
    "tools/revoke_profiles.json"
)
DEFAULT_SHA_URL = DEFAULT_URL + ".sha256"
LOCAL_DIR = os.path.expanduser(
    "~/Library/Application Support/ExtraWeChat/profiles"
)
LOCAL_PATH = os.path.join(LOCAL_DIR, "revoke_profiles.json")
META_PATH = os.path.join(LOCAL_DIR, "profile-meta.json")
BUNDLED_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "revoke_profiles.json"
)


def read_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def canonical_bytes(doc: dict) -> bytes:
    return json.dumps(doc, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def validate_doc(doc: dict) -> tuple[int, int]:
    if not isinstance(doc, dict):
        raise ValueError("profile root is not an object")
    builds = doc.get("builds")
    generations = doc.get("generations")
    if not isinstance(builds, dict) or not builds:
        raise ValueError("missing builds table")
    if not isinstance(generations, list) or not generations:
        raise ValueError("missing generation table")
    try:
        int(str(doc.get("off_cbz", "0x270")), 16)
    except ValueError:
        raise ValueError("invalid off_cbz")

    for build, arches in builds.items():
        if not isinstance(arches, dict):
            raise ValueError(f"{build}: architectures is not an object")
        for arch, profile in arches.items():
            if arch not in ("arm64", "x86_64"):
                raise ValueError(f"{build}: unknown arch {arch}")
            if not isinstance(profile, dict):
                raise ValueError(f"{build}/{arch}: profile is not an object")
            for variant in ("silent", "keeptip"):
                entries = profile.get(variant, [])
                if not isinstance(entries, list):
                    raise ValueError(f"{build}/{arch}/{variant}: not a list")
                for entry in entries:
                    addr = entry.get("addr", "")
                    try:
                        int(addr, 16)
                    except ValueError:
                        raise ValueError(f"{build}/{arch}: bad addr {addr!r}")
                    expected = entry.get("expected")
                    asm = entry.get("asm")
                    if isinstance(expected, str):
                        expected = [expected]
                    if not isinstance(expected, list) or not expected:
                        raise ValueError(f"{build}/{arch}: missing expected")
                    if not isinstance(asm, str) or not asm:
                        raise ValueError(f"{build}/{arch}: missing asm")
                    if len(asm) % 2:
                        raise ValueError(f"{build}/{arch}: odd asm length")
                    for value in expected:
                        if not isinstance(value, str) or len(value) % 2:
                            raise ValueError(f"{build}/{arch}: bad expected")
    return len(builds), len(generations)


def fetch(url: str, timeout: int = 20) -> bytes:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "ExtraWeChat-profile-updater/1.0"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.read()


def remote_sha(url: str) -> str:
    text = fetch(url).decode("utf-8", errors="replace").strip()
    token = text.split()[0] if text else ""
    if len(token) != 64 or any(c not in "0123456789abcdefABCDEF" for c in token):
        raise ValueError("remote .sha256 is malformed")
    return token.lower()


def current_doc() -> tuple[dict, str]:
    for path in (LOCAL_PATH, BUNDLED_PATH):
        if os.path.exists(path):
            try:
                return read_json(path), path
            except Exception:
                continue
    return {}, ""


def check(from_file: str | None = None) -> dict:
    remote_doc = None
    remote_digest = None
    remote_url = os.environ.get("EXTRAWECHAT_PROFILES_URL", DEFAULT_URL)
    sha_url = os.environ.get("EXTRAWECHAT_PROFILES_SHA_URL", DEFAULT_SHA_URL)

    if from_file:
        remote_doc = read_json(from_file)
        remote_digest = sha256_bytes(canonical_bytes(remote_doc))
    else:
        remote_bytes = fetch(remote_url)
        expected = remote_sha(sha_url)
        raw_digest = sha256_bytes(remote_bytes)
        if raw_digest != expected:
            raise ValueError(
                f"remote SHA mismatch: got {raw_digest}, expected {expected}"
            )
        remote_doc = json.loads(remote_bytes.decode("utf-8"))
        remote_digest = sha256_bytes(canonical_bytes(remote_doc))

    remote_builds, remote_gens = validate_doc(remote_doc)
    local_doc, local_path = current_doc()
    local_builds = len(local_doc.get("builds", {})) if local_doc else 0
    local_digest = sha256_bytes(canonical_bytes(local_doc)) if local_doc else ""

    return {
        "status": "update-available" if remote_digest != local_digest else "up-to-date",
        "remote_digest": remote_digest,
        "local_digest": local_digest,
        "remote_builds": remote_builds,
        "remote_generations": remote_gens,
        "local_builds": local_builds,
        "local_path": local_path,
        "source": remote_url if not from_file else from_file,
        "doc": remote_doc,
    }


def update(from_file: str | None = None) -> dict:
    result = check(from_file=from_file)
    if result["remote_builds"] < result["local_builds"]:
        result["status"] = "remote-older"
        return result
    os.makedirs(LOCAL_DIR, exist_ok=True)
    os.chmod(LOCAL_DIR, 0o700)
    tmp = LOCAL_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(result["doc"], f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, LOCAL_PATH)
    meta = {
        "digest": result["remote_digest"],
        "builds": result["remote_builds"],
        "generations": result["remote_generations"],
        "source": result["source"],
        "updated_at": int(time.time()),
    }
    with open(META_PATH + ".tmp", "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(META_PATH + ".tmp", META_PATH)
    result["installed_to"] = LOCAL_PATH
    result["status"] = "installed"
    return result


def reset() -> dict:
    removed = False
    for path in (LOCAL_PATH, META_PATH):
        if os.path.exists(path):
            os.remove(path)
            removed = True
    return {"status": "reset" if removed else "nothing-to-reset"}


def main() -> int:
    ap = argparse.ArgumentParser(description="Update ExtraWeChat WeChat build profiles")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("check", "update"):
        p = sub.add_parser(name)
        p.add_argument("--from-file", help="use a local JSON instead of the network")
        p.add_argument("--json", action="store_true")
    p = sub.add_parser("reset")
    p.add_argument("--json", action="store_true")
    args = ap.parse_args()

    try:
        if args.cmd == "reset":
            result = reset()
        elif args.cmd == "update":
            result = update(args.from_file)
        else:
            result = check(args.from_file)
    except (urllib.error.URLError, TimeoutError, ValueError, OSError) as error:
        result = {"status": "error", "error": str(error)}

    public = {k: v for k, v in result.items() if k != "doc"}
    if getattr(args, "json", False):
        print(json.dumps(public, ensure_ascii=False, indent=2))
    else:
        print(f"status: {public.get('status')}")
        for key in ("local_builds", "remote_builds", "local_path",
                    "installed_to", "error"):
            if key in public:
                print(f"{key}: {public[key]}")
    return 0 if public.get("status") != "error" else 1


if __name__ == "__main__":
    raise SystemExit(main())
