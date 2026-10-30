#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""
locate_revoke.py — read-only locator for WeChat 4.x anti-revoke patch points.

Two-stage matching:

1. Exact build profile from `tools/revoke_profiles.json` (CFBundleVersion + arch).
   This is the fast, highest-confidence path and covers all builds collected in
   the compatibility table.
2. arm64 geometry scan of `parseRevokeXML` for builds that are not in the
   profile table. The function has a stable shape inside one "generation":

       E + 0x270             == `cbz w0, SKIP`          (silent point)
       E + 0x270 + delta     == `str <Rt>, [x19,#newmsgid]` (keeptip point)

All writes are still gated by the expected original bytes. If neither the
profile nor the geometry matches, the tool refuses to guess.

Supported architectures: arm64 and x86_64 (x86_64 uses exact build profiles
only; no x86_64 geometry scanner is implemented yet).

Usage:
    python3 tools/locate_revoke.py
    python3 tools/locate_revoke.py --app /Applications/WeChat.app
    python3 tools/locate_revoke.py --dylib /path/wechat.dylib --json
    python3 tools/locate_revoke.py --arch x86_64 --dylib ...
    python3 tools/locate_revoke.py --force-scan      # ignore build profiles
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import platform
import struct
import subprocess
import sys

BUNDLED_PROFILES_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "revoke_profiles.json"
)
LOCAL_PROFILES_PATH = os.path.expanduser(
    "~/Library/Application Support/ExtraWeChat/profiles/revoke_profiles.json"
)

FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFEBE
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM64 = 0x0100000C
STR_RT_MASK = 0xFFFFFFE0


def _read_profile(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if not isinstance(doc.get("builds"), dict) or not doc["builds"]:
        raise ValueError("missing builds table")
    return doc


def _load_profiles() -> tuple[dict, str, str]:
    override = os.environ.get("EXTRAWECHAT_PROFILES")
    if override:
        try:
            return _read_profile(override), override, "override"
        except Exception as error:
            raise SystemExit(f"invalid profile override {override}: {error}")

    local = None
    bundled = None
    try:
        local = _read_profile(LOCAL_PROFILES_PATH)
    except Exception:
        pass
    try:
        bundled = _read_profile(BUNDLED_PROFILES_PATH)
    except Exception as error:
        if local is None:
            raise SystemExit(
                "missing or invalid signature/profile table: "
                f"{BUNDLED_PROFILES_PATH}: {error}"
            )

    # Avoid a stale local override hiding newer bundled profiles. Equal build
    # counts still prefer local, so address corrections can be delivered.
    if local is not None:
        if bundled is None or len(local["builds"]) >= len(bundled["builds"]):
            return local, LOCAL_PROFILES_PATH, "local"
    return bundled, BUNDLED_PROFILES_PATH, "bundled"


PROFILES, PROFILES_PATH, PROFILES_SOURCE = _load_profiles()
OFF_CBZ = int(PROFILES.get("off_cbz", "0x270"), 16)

SIGNATURES: list[dict] = []
for _gen in PROFILES.get("generations", []):
    _sig = dict(_gen)
    _sig["branch"] = _sig["b"]
    _sig["delta"] = int(_sig["delta"], 16)
    _sig["field"] = int(_sig["field"], 16)
    SIGNATURES.append(_sig)


def word_from_hex(hex_be: str) -> int:
    """Config hex is written in file order (big-endian spelling). Return the
    little-endian instruction word used by the CPU."""
    return struct.unpack("<I", bytes.fromhex(hex_be))[0]


def hex_from_word(word: int) -> str:
    return struct.pack("<I", word).hex().upper()


def read_app_info(app: str) -> dict:
    info = os.path.join(app, "Contents", "Info.plist")
    if not os.path.exists(info):
        return {}
    try:
        with open(info, "rb") as f:
            plist = plistlib.load(f)
    except Exception:
        return {}
    return {
        "bundle_id": plist.get("CFBundleIdentifier"),
        "short_version": plist.get("CFBundleShortVersionString"),
        "build": plist.get("CFBundleVersion"),
        "wechat_version": plist.get("WeChatBundleVersion"),
        "channel": "appStore" if os.path.exists(os.path.join(app, "Contents", "_MASReceipt", "receipt")) else "direct",
    }


def _cpu_name(cputype: int) -> str | None:
    if cputype == CPU_TYPE_ARM64:
        return "arm64"
    if cputype == CPU_TYPE_X86_64:
        return "x86_64"
    return None


def macho_slice(data: bytes, arch: str = "auto") -> tuple[bytes, int, str]:
    """Return (slice bytes, slice file offset, arch name)."""
    if len(data) < 8:
        raise SystemExit("not a Mach-O file")

    if data[:4] == b"\xca\xfe\xba\xbe":
        endian = ">"
    elif data[:4] == b"\xbe\xba\xfe\xca":
        endian = "<"
    else:
        endian = None

    if endian:
        nfat = struct.unpack(endian + "I", data[4:8])[0]
        if nfat == 0 or nfat > 64:
            raise SystemExit(f"invalid fat header: {nfat} architectures")
        wanted = arch
        if wanted == "auto":
            wanted = "arm64" if platform.machine() == "arm64" else "x86_64"
        for i in range(nfat):
            base = 8 + i * 20
            raw = data[base:base + 20]
            if len(raw) < 20:
                raise SystemExit("truncated fat_arch table")
            cputype, _sub, offset, size, _align = struct.unpack(endian + "iIIII", raw)
            name = _cpu_name(cputype & 0xFFFFFFFF)
            if name == wanted:
                end = offset + size
                if size == 0 or end > len(data):
                    raise SystemExit(f"invalid {wanted} slice bounds")
                return data[offset:end], offset, name
        raise SystemExit(
            f"no {wanted} slice in this binary (available: "
            + ", ".join(
                filter(None, [
                    _cpu_name(struct.unpack(endian + "i", data[8 + i * 20:12 + i * 20])[0] & 0xFFFFFFFF)
                    for i in range(nfat)
                ])
            )
            + ")"
        )

    if struct.unpack("<I", data[:4])[0] != MH_MAGIC_64:
        raise SystemExit("not a 64-bit Mach-O")
    cputype = struct.unpack("<i", data[4:8])[0] & 0xFFFFFFFF
    name = _cpu_name(cputype)
    if name is None:
        raise SystemExit(f"unsupported CPU type 0x{cputype:x}")
    wanted = arch
    if wanted == "auto":
        wanted = "arm64" if platform.machine() == "arm64" else "x86_64"
    if name != wanted:
        raise SystemExit(f"thin binary is {name}, not {wanted}")
    return data, 0, name


def arm64_slice(data: bytes) -> tuple[bytes, int]:
    """Backward-compatible wrapper."""
    sl, off, _ = macho_slice(data, "arm64")
    return sl, off


def parse_macho(sl: bytes) -> tuple[list[dict], list[dict]]:
    if len(sl) < 32:
        raise SystemExit("truncated Mach-O")
    magic, _cput, _cpus, _ft, ncmds, sizeofcmds, _fl, _rz = struct.unpack("<IiiIIIII", sl[:32])
    if magic != MH_MAGIC_64:
        raise SystemExit("slice is not a 64-bit Mach-O")
    segments: list[dict] = []
    sections: list[dict] = []
    p = 32
    for _ in range(ncmds):
        if p + 8 > len(sl):
            raise SystemExit("truncated load commands")
        cmd, cmdsize = struct.unpack("<II", sl[p:p + 8])
        if cmdsize < 8 or cmdsize % 8 or p + cmdsize > len(sl):
            raise SystemExit("invalid load command size")
        if cmdsize > 0x40000000:
            raise SystemExit("load command too large")
        if cmd == LC_SEGMENT_64:
            segname = sl[p + 8:p + 24].rstrip(b"\0").decode(errors="replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", sl[p + 24:p + 56])
            nsects = struct.unpack("<I", sl[p + 64:p + 68])[0] if cmdsize >= 72 else 0
            segments.append({
                "name": segname,
                "vmaddr": vmaddr,
                "vmsize": vmsize,
                "fileoff": fileoff,
                "filesize": filesize,
            })
            for j in range(nsects):
                q = p + 72 + 80 * j
                if q + 80 > len(sl):
                    break
                sectname = sl[q:q + 16].rstrip(b"\0").decode(errors="replace")
                s_vmaddr, s_size = struct.unpack("<QQ", sl[q + 32:q + 48])
                s_fileoff = struct.unpack("<I", sl[q + 48:q + 52])[0]
                sections.append({
                    "segname": segname,
                    "name": sectname,
                    "vmaddr": s_vmaddr,
                    "size": s_size,
                    "fileoff": s_fileoff,
                })
        p += cmdsize
    if p > 32 + sizeofcmds:
        raise SystemExit("load commands exceed sizeofcmds")
    return segments, sections


def section(sections: list[dict], name: str) -> dict:
    for s in sections:
        if s["name"] == name:
            return s
    raise SystemExit(f"missing __TEXT,__{name}")


def off_to_va(segments: list[dict], off: int) -> int | None:
    for seg in segments:
        if seg["fileoff"] <= off < seg["fileoff"] + seg["filesize"]:
            return seg["vmaddr"] + (off - seg["fileoff"])
    return None


def va_to_off(segments: list[dict], va: int) -> int | None:
    for seg in segments:
        if seg["vmaddr"] <= va < seg["vmaddr"] + seg["filesize"]:
            return seg["fileoff"] + (va - seg["vmaddr"])
    return None


def bytes_at(sl: bytes, segments: list[dict], va: int, length: int) -> bytes | None:
    off = va_to_off(segments, va)
    if off is None or off + length > len(sl):
        return None
    return sl[off:off + length]


def _expected_list(entry: dict) -> list[str]:
    value = entry.get("expected", [])
    if isinstance(value, str):
        return [value.upper()]
    return [x.upper() for x in value]


def _entries_from_profile(profile: dict) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for variant in ("silent", "keeptip"):
        entries = []
        for raw in profile.get(variant, []):
            expected = _expected_list(raw)
            patch = raw["asm"].upper()
            addr = raw.get("addr", "")
            if not expected or not patch:
                raise SystemExit(f"empty expected/asm in {variant} profile entry: {raw}")
            try:
                int(addr, 16)
            except ValueError:
                raise SystemExit(f"invalid address in {variant} profile entry: {raw}")
            if any(len(x) % 2 for x in expected) or len(patch) % 2:
                raise SystemExit(f"odd-length hex in {variant} profile entry: {raw}")
            entries.append({
                "va": int(raw["addr"], 16),
                "expected": expected,
                "patch": patch,
            })
        out[variant] = entries
    return out


def _profile_result(sl: bytes, segments: list[dict], build: str, arch: str,
                    profile: dict) -> dict | None:
    entries = _entries_from_profile(profile)
    if not entries["silent"] and not entries["keeptip"]:
        return None

    # Every entry must be either pristine, one of the accepted bytes, or the
    # final patch. If any entry is unknown, this profile is for a different
    # binary/build and must not be used.
    seen_unknown = []
    for variant in ("silent", "keeptip"):
        for entry in entries[variant]:
            patch = bytes.fromhex(entry["patch"])
            current = bytes_at(sl, segments, entry["va"], len(patch))
            if current is None:
                seen_unknown.append((variant, entry["va"], "not file-backed"))
                continue
            accepted = [bytes.fromhex(x) for x in entry["expected"]]
            if current not in accepted and current != patch:
                seen_unknown.append((variant, entry["va"], current.hex().upper()))
    if seen_unknown:
        return None

    def current_state(variant: str, index: int, patched_name: str) -> tuple[str, bytes | None, dict | None]:
        variant_entries = entries[variant]
        if not variant_entries:
            return "unsupported", None, None
        entry = variant_entries[index]
        patch = bytes.fromhex(entry["patch"])
        current = bytes_at(sl, segments, entry["va"], len(patch))
        if current == patch:
            return patched_name, current, entry
        return "pristine", current, entry

    silent_state, silent_current, silent_entry = current_state("silent", 0, "patched-silent")
    keeptip_state, keeptip_current, keeptip_entry = current_state("keeptip", -1, "patched-keeptip")
    silent_va = entries["silent"][0]["va"] if entries["silent"] else entries["keeptip"][0]["va"]
    keeptip_va = entries["keeptip"][-1]["va"] if entries["keeptip"] else silent_va

    def legacy(entry: dict | None) -> tuple[str, str, str]:
        if entry is None:
            return "—", "—", "—"
        return entry["expected"][0], entry["patch"], entry["patch"]

    silent_pristine, silent_patch, _ = legacy(silent_entry)
    keeptip_pristine, keeptip_patch, _ = legacy(keeptip_entry)

    return {
        "generation": profile.get("generation", "build profile"),
        "match": "profile",
        "build": build,
        "arch": arch,
        "entry_va": silent_va - OFF_CBZ,
        "silent_va": silent_va,
        "silent_current": silent_current.hex().upper() if silent_current else "—",
        "silent_pristine": silent_pristine,
        "silent_patch": silent_patch,
        "silent_state": silent_state,
        "keeptip_va": keeptip_va,
        "keeptip_current": keeptip_current.hex().upper() if keeptip_current else "—",
        "keeptip_pristine": keeptip_pristine,
        "keeptip_patch": keeptip_patch,
        "keeptip_state": keeptip_state,
        "field": None,
        "delta": None,
        "prologue_ok": None,
        "entries": entries,
    }


def _signature_result(sl: bytes, segments: list[dict], sections: list[dict]) -> dict:
    text = section(sections, "__text")
    tb = sl[text["fileoff"]:text["fileoff"] + text["size"]]

    anchors: dict[int, list[dict]] = {}
    for sig in SIGNATURES:
        sig = dict(sig)
        sig["cbz_word"] = word_from_hex(sig["cbz"])
        sig["branch_word"] = word_from_hex(sig["branch"])
        sig["str_masked"] = word_from_hex(sig["str_x0"]) & STR_RT_MASK
        anchors.setdefault(sig["cbz_word"], []).append(sig)
        anchors.setdefault(sig["branch_word"], []).append(sig)

    hits: list[tuple[int, dict]] = []
    for i in range(0, len(tb) - 3, 4):
        word = struct.unpack_from("<I", tb, i)[0]
        candidates = anchors.get(word)
        if not candidates:
            continue
        for sig in candidates:
            j = i + sig["delta"]
            if j + 4 > len(tb):
                continue
            str_word = struct.unpack_from("<I", tb, j)[0]
            if (str_word & STR_RT_MASK) == sig["str_masked"]:
                hits.append((i, sig))

    if not hits:
        raise SystemExit(
            "no exact profile and no arm64 geometry hit. This build likely "
            "recompiled parseRevokeXML into a new generation; add a profile "
            "to tools/revoke_profiles.json or add a new generation signature."
        )

    vas: list[tuple[int, int, dict]] = []
    for i, sig in hits:
        va = off_to_va(segments, text["fileoff"] + i)
        if va is not None:
            vas.append((va, i, sig))
    if len(vas) != 1:
        pretty = ", ".join(f"0x{va:x}({sig['name']})" for va, _i, sig in vas)
        raise SystemExit(f"signature matched {len(vas)} sites ({pretty}); refusing to guess")

    va, _i, sig = vas[0]
    keeptip_va = va + sig["delta"]
    silent_off = va_to_off(segments, va)
    keeptip_off = va_to_off(segments, keeptip_va)
    if silent_off is None or keeptip_off is None:
        raise SystemExit("located VA is not file-backed")
    silent_bytes = sl[silent_off:silent_off + 4].hex().upper()
    keeptip_bytes = sl[keeptip_off:keeptip_off + 4].hex().upper()
    if silent_bytes not in (sig["cbz"], sig["branch"]):
        raise SystemExit(f"unexpected silent bytes {silent_bytes}")
    if keeptip_bytes not in (sig["str_x0"], sig["str_xzr"]):
        raise SystemExit(f"unexpected keeptip bytes {keeptip_bytes}")

    entry_off = silent_off - OFF_CBZ
    entry_word = struct.unpack_from("<I", sl, entry_off)[0]
    prologue = (
        (entry_word & 0xFFC00000) in (0xA9800000, 0xA9000000)
        or (entry_word & 0xFF0003FF) == 0xD10003FF
        or entry_word == 0xD503237F
    )

    entries = {
        "silent": [{
            "va": va,
            "expected": [sig["cbz"], sig["branch"]],
            "patch": sig["branch"],
        }],
        "keeptip": [
            {
                "va": va,
                "expected": [sig["cbz"], sig["branch"]],
                "patch": sig["cbz"],
            },
            {
                "va": keeptip_va,
                "expected": [sig["str_x0"], sig["str_xzr"]],
                "patch": sig["str_xzr"],
            },
        ],
    }

    return {
        "generation": sig["name"],
        "match": "signature",
        "build": None,
        "arch": "arm64",
        "entry_va": va - OFF_CBZ,
        "silent_va": va,
        "silent_current": silent_bytes,
        "silent_pristine": sig["cbz"],
        "silent_patch": sig["branch"],
        "silent_state": "patched-silent" if silent_bytes == sig["branch"] else "pristine",
        "keeptip_va": keeptip_va,
        "keeptip_current": keeptip_bytes,
        "keeptip_pristine": sig["str_x0"],
        "keeptip_patch": sig["str_xzr"],
        "keeptip_state": "patched-keeptip" if keeptip_bytes == sig["str_xzr"] else "pristine",
        "field": sig["field"],
        "delta": sig["delta"],
        "prologue_ok": prologue,
        "entries": entries,
    }


def locate_with_profile(sl: bytes, segments: list[dict], sections: list[dict],
                        build: str | None, arch: str,
                        use_profile: bool = True,
                        use_signature: bool = True) -> dict:
    profile_note = ""
    if use_profile and build:
        arch_profile = PROFILES.get("builds", {}).get(str(build), {}).get(arch)
        if arch_profile:
            result = _profile_result(sl, segments, str(build), arch, arch_profile)
            if result is not None:
                return result
            profile_note = (
                f"build {build}/{arch} has a profile, but the bytes do not match; "
            )

    if arch == "arm64" and use_signature:
        result = _signature_result(sl, segments, sections)
        result["build"] = build
        if profile_note:
            result["profile_note"] = profile_note.strip()
        return result

    raise SystemExit(
        profile_note
        + f"no match for build {build or 'unknown'} on {arch}. "
        "x86_64 requires an exact build profile; arm64 can fall back to the "
        "geometry scanner. Add the build to tools/revoke_profiles.json."
    )


def codesign_flags(app: str) -> str:
    r = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=2", app],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        return "unsigned-or-unreadable"
    flags = []
    for line in r.stderr.splitlines():
        if line.startswith("flags="):
            flags.append(line)
        if line.startswith("Authority="):
            flags.append(line)
    return "; ".join(flags[:3])


def target_entries(result: dict, variant: str) -> list[dict]:
    entries = result.get("entries", {}).get(variant, [])
    out = []
    for entry in entries:
        expected = entry["expected"]
        out.append({
            "arch": result["arch"],
            "addr": f"{entry['va']:x}",
            "expected": expected[0] if len(expected) == 1 else expected,
            "asm": entry["patch"],
        })
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Locate WeChat 4.x anti-revoke patch points (read-only)")
    ap.add_argument("-a", "--app", default="/Applications/WeChat.app", help="WeChat.app path")
    ap.add_argument("-d", "--dylib", help="wechat.dylib path (overrides --app inference)")
    ap.add_argument("--build", help="CFBundleVersion override (useful with --dylib)")
    ap.add_argument("--arch", choices=["auto", "arm64", "x86_64"], default="auto")
    ap.add_argument("--force-scan", action="store_true",
                    help="ignore exact build profiles and use the arm64 geometry scanner")
    ap.add_argument("--json", action="store_true", help="print machine-readable JSON")
    args = ap.parse_args()

    app = os.path.abspath(os.path.expanduser(args.app))
    dylib = args.dylib or os.path.join(app, "Contents", "Resources", "wechat.dylib")
    dylib = os.path.abspath(os.path.expanduser(dylib))
    if not os.path.exists(dylib):
        raise SystemExit(f"not found: {dylib}")

    info = read_app_info(app) if not args.dylib else {}
    build = args.build or info.get("build")

    with open(dylib, "rb") as f:
        data = f.read()
    sl, slice_off, arch = macho_slice(data, args.arch)
    segments, sections = parse_macho(sl)
    result = locate_with_profile(
        sl, segments, sections, build, arch,
        use_profile=not args.force_scan,
        use_signature=True,
    )
    result.update({
        "app": app if not args.dylib else None,
        "dylib": dylib,
        "arch": arch,
        "slice_offset": slice_off,
        "host_arch": platform.machine(),
        "build": build,
        "profiles_path": PROFILES_PATH,
        "profiles_source": PROFILES_SOURCE,
        "codesign": codesign_flags(app) if not args.dylib else None,
        **info,
    })

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    print("===== WeChat anti-revoke locator =====")
    if info:
        print(f"WeChat:        {info.get('short_version')} (build {info.get('build')}), "
              f"{info.get('channel')}, {info.get('bundle_id')}")
        print(f"Full version:  {info.get('wechat_version')}")
    print(f"Dylib:         {dylib}")
    print(f"Host arch:     {platform.machine()}")
    print(f"Target arch:   {arch}")
    print(f"Match:         {result['match']}  ({result['generation']})")
    print(f"Build:         {build or 'unknown'}")
    print(f"parseRevokeXML entry E: 0x{result['entry_va']:x}")
    if result.get("field"):
        print(f"newmsgid field: [x19,#0x{result['field']:x}]")
    print(f"silent  VA:    0x{result['silent_va']:x}  "
          f"{result['silent_current']} -> {result['silent_patch']}  [{result['silent_state']}]")
    print(f"keeptip VA:    0x{result['keeptip_va']:x}  "
          f"{result['keeptip_current']} -> {result['keeptip_patch']}  [{result['keeptip_state']}]")
    print(f"STP prologue:  {'ok' if result['prologue_ok'] else 'n/a'}")
    print()
    print("config.json targets:")
    targets = []
    silent = target_entries(result, "silent")
    keeptip = target_entries(result, "keeptip")
    if silent:
        targets.append({
            "identifier": "revoke",
            "binary": "Contents/Resources/wechat.dylib",
            "entries": silent,
        })
    if keeptip:
        targets.append({
            "identifier": "revoke-keeptip",
            "binary": "Contents/Resources/wechat.dylib",
            "entries": keeptip,
        })
    print(json.dumps({
        "version": build or "REPLACE_WITH_BUILD",
        "targets": targets,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
