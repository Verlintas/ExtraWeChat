#!/usr/bin/env python3
"""
Experimental login-persistence host for WeChat 4.x (macOS).

It spawns a *copy* of WeChat under Frida and loads agent.js. The agent hooks
owl::v9::ini_file::get in the WeChat process, captures non-empty
kTdiKeyAutoauthKey / kTdiKeyAutoauthEncKey values, and can inject a saved value
when the app would otherwise fall back to manual (phone) login.

This is a research tool, not an installer. It does not modify /Applications
/WeChat.app. The target app must be a copy re-signed with
`com.apple.security.get-task-allow` (tools/patch_copy.py --get-task-allow).

Usage:
    # build a test copy first (example)
    python3 tools/patch_copy.py --app /Applications/WeChat.app \
        --output ~/Applications/WeChat-LoginTest.app --variant none \
        --clone login-test --get-task-allow

    # run with persistence (stores captured keys under Application Support)
    python3 tools/login_persist/host.py run \
        --app ~/Applications/WeChat-LoginTest.app \
        --home ~/Library/Application\\ Support/ExtraWeChat/Instances/login-test \
        --persist --timeout 90

    # diagnostic only: never stores raw keys
    python3 tools/login_persist/host.py diagnose \
        --app ~/Applications/WeChat-LoginTest.app \
        --home ~/Library/Application\\ Support/ExtraWeChat/Instances/login-test \
        --timeout 60

    # clear saved keys
    python3 tools/login_persist/host.py clear

WARNING: the key is a login credential. The prototype stores it in a 0600 file
under ~/Library/Application Support/ExtraWeChat/login_keys.json. The final
product should move it to Keychain. Only use this on your own machine/account.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import time

try:
    import frida
except ImportError:
    print("frida is required: python3 -m pip install 'frida<17'", file=sys.stderr)
    raise SystemExit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT_PATH = os.path.join(HERE, "agent.js")
STORE_DIR = os.path.expanduser("~/Library/Application Support/ExtraWeChat")
STORE_PATH = os.path.join(STORE_DIR, "login_keys.json")


def app_binary(app: str) -> str:
    app = os.path.abspath(os.path.expanduser(app))
    binary = os.path.join(app, "Contents", "MacOS", "WeChat")
    if not os.path.isfile(binary):
        raise SystemExit(f"not a WeChat.app: {app}")
    return binary


def load_store() -> list[dict]:
    if not os.path.exists(STORE_PATH):
        return []
    try:
        with open(STORE_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception as e:
        print(f"[store] cannot read {STORE_PATH}: {e}", file=sys.stderr)
        return []


def save_store(keys: list[dict]) -> None:
    os.makedirs(STORE_DIR, exist_ok=True)
    os.chmod(STORE_DIR, 0o700)
    tmp = STORE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(keys, f, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STORE_PATH)


def key_fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def message_handler(persist: bool, store: list[dict], seen: list[dict]):
    def on_message(message, data):
        if message.get("type") == "error":
            print(f"[frida:error] {message.get('description')}", flush=True)
            return
        if message.get("type") != "send":
            return
        payload = message.get("payload") or {}
        kind = payload.get("type")
        if kind == "ready":
            print(f"[agent] hooked owl::ini_file::get at {payload.get('address')}", flush=True)
        elif kind == "log":
            print(f"[agent] {payload.get('message')}", flush=True)
        elif kind == "inject":
            print(f"[inject] {payload.get('key')} length={payload.get('length')}", flush=True)
        elif kind == "capture":
            key = payload.get("key")
            value = payload.get("value") or ""
            fp = key_fingerprint(value)
            print(f"[capture] {key} length={len(value)} sha256={fp}", flush=True)
            seen.append({"key": key, "value": value, "fingerprint": fp})
            if persist:
                # Keep one latest value per key name.
                store[:] = [x for x in store if x.get("key") != key]
                store.append({"key": key, "value": value, "sha256": fp,
                              "updated_at": int(time.time())})
                save_store(store)
                print(f"[store] saved {key} (fingerprint {fp})", flush=True)
    return on_message


def run(args) -> int:
    binary = app_binary(args.app)
    env = os.environ.copy()
    home = os.path.abspath(os.path.expanduser(args.home)) if args.home else None
    if home:
        os.makedirs(home, exist_ok=True)
        os.makedirs(os.path.join(home, "Documents"), exist_ok=True)
        os.makedirs(os.path.join(home, "Library", "Containers"), exist_ok=True)
        env["CFFIXED_USER_HOME"] = home
        env["HOME"] = home
    store = load_store()
    keys = [{"key": x["key"], "value": x["value"]} for x in store if x.get("value")]
    print(f"[store] {len(keys)} saved key(s) in {STORE_PATH}", flush=True)
    for x in store:
        print(f"[store] {x.get('key')} length={len(x.get('value', ''))} "
              f"sha256={x.get('sha256') or key_fingerprint(x.get('value', ''))}", flush=True)

    device = frida.get_local_device()
    print(f"[frida] spawning {binary}", flush=True)
    pid = device.spawn([binary], env=env, cwd=os.path.dirname(binary))
    session = device.attach(pid)
    script = session.create_script(open(AGENT_PATH, "r", encoding="utf-8").read())
    seen: list[dict] = []
    script.on("message", message_handler(args.persist, store, seen))
    script.load()
    if keys:
        script.post({"type": "set_keys", "keys": keys})
    device.resume(pid)
    print(f"[frida] resumed pid={pid}", flush=True)

    started = time.time()
    try:
        while True:
            if args.timeout and time.time() - started >= args.timeout:
                print("[frida] timeout reached; detaching", flush=True)
                break
            time.sleep(0.5)
    except KeyboardInterrupt:
        print("\n[frida] interrupted", flush=True)
    finally:
        try:
            session.detach()
        except Exception:
            pass
        # Do not kill WeChat: the user may want to inspect the login window.
    if not seen:
        print("[result] no auth key was observed. If this was a fresh clone, log in once "
              "and rerun; if this was a logged-in copy, wait until the login screen is "
              "initialized.", flush=True)
    else:
        print(f"[result] observed {len(seen)} auth key event(s)", flush=True)
    return 0


def clear() -> int:
    if os.path.exists(STORE_PATH):
        os.remove(STORE_PATH)
        print(f"[store] removed {STORE_PATH}")
    else:
        print("[store] nothing to clear")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Experimental WeChat 4.x login persistence")
    sub = ap.add_subparsers(dest="cmd", required=True)

    for name in ("run", "diagnose"):
        p = sub.add_parser(name)
        p.add_argument("--app", required=True, help="copy of WeChat.app")
        p.add_argument("--home", help="CFFIXED_USER_HOME for a clone")
        p.add_argument("--timeout", type=int, default=60, help="seconds to observe (0 = forever)")
        p.add_argument("--persist", action="store_true",
                       help="store captured keys (only for 'run'; diagnose never stores)")

    sub.add_parser("clear", help="remove saved login keys")

    args = ap.parse_args()
    if args.cmd == "clear":
        return clear()
    if args.cmd == "diagnose" and args.persist:
        print("diagnose never stores keys; use 'run --persist'", file=sys.stderr)
        return 2
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
