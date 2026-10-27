#!/usr/bin/env python3
"""
locate_revoke.py — read-only locator for WeChat 4.x anti-revoke patch points.

This does not modify anything. It parses the arm64 slice of
`WeChat.app/Contents/Resources/wechat.dylib` and looks for the build-invariant
geometry of `parseRevokeXML`:

    E + 0x270              == `cbz w0, SKIP`          (silent patch point)
    E + 0x270 + delta      == `str <Rt>, [x19, #newmsgid]`  (keeptip point)

Known generations (from fzlzjerry/wechat-antirecall and zengtianli/WeChatTweak,
both AGPL-3.0; see docs/FEASIBILITY.md for attribution):

    gen 4.1.13+     cbz 40100034  b 82000014  delta 0x7a0  str 60E600F9  field 0x1c8
    gen 4.1.12      cbz 40100034  b 82000014  delta 0x7a0  str 60CE00F9  field 0x198
    gen 4.1.10-11   cbz E00F0034  b 7F000014  delta 0x794  str 60B600F9  field 0x168

If none match, the build recompiled the function into a new generation and a
human must add a new geometry to the table (see docs/PATCH-270115.md).

Usage:
    python3 tools/locate_revoke.py
    python3 tools/locate_revoke.py --app /Applications/WeChat.app
    python3 tools/locate_revoke.py --dylib /path/wechat.dylib --json
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

FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFEBE
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
CPU_TYPE_ARM64 = 0x0100000C
OFF_CBZ = 0x270
STR_RT_MASK = 0xFFFFFFE0

SIGNATURES = [
    {
        "name": "4.1.13+ (269574+)",
        "cbz": "40100034",
        "branch": "82000014",
        "delta": 0x7A0,
        "str_x0": "60E600F9",
        "str_xzr": "7FE600F9",
        "field": 0x1C8,
    },
    {
        "name": "4.1.12 (269332-269341)",
        "cbz": "40100034",
        "branch": "82000014",
        "delta": 0x7A0,
        "str_x0": "60CE00F9",
        "str_xzr": "7FCE00F9",
        "field": 0x198,
    },
    {
        "name": "4.1.10-4.1.11 (<=269136)",
        "cbz": "E00F0034",
        "branch": "7F000014",
        "delta": 0x794,
        "str_x0": "60B600F9",
        "str_xzr": "7FB600F9",
        "field": 0x168,
    },
]


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
    with open(info, "rb") as f:
        plist = plistlib.load(f)
    return {
        "bundle_id": plist.get("CFBundleIdentifier"),
        "short_version": plist.get("CFBundleShortVersionString"),
        "build": plist.get("CFBundleVersion"),
        "wechat_version": plist.get("WeChatBundleVersion"),
        "channel": "appStore" if os.path.exists(os.path.join(app, "Contents", "_MASReceipt", "receipt")) else "direct",
    }


def arm64_slice(data: bytes) -> tuple[bytes, int]:
    """Return (arm64 slice bytes, slice file offset)."""
    if len(data) < 8:
        raise SystemExit("not a Mach-O file")
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        swapped = magic == FAT_CIGAM
        nfat = struct.unpack(">I", data[4:8])[0]
        if swapped:
            nfat = struct.unpack("<I", data[4:8])[0]
        for i in range(nfat):
            base = 8 + i * 20
            raw = data[base:base + 20]
            if len(raw) < 20:
                break
            if swapped:
                cputype, _sub, offset, size, _align = struct.unpack("<iIIII", raw)
            else:
                cputype, _sub, offset, size, _align = struct.unpack(">iIIII", raw)
            if (cputype & 0xFFFFFFFF) == CPU_TYPE_ARM64:
                return data[offset:offset + size], offset
        raise SystemExit("no arm64 slice in this binary")
    if struct.unpack("<I", data[:4])[0] != MH_MAGIC_64:
        raise SystemExit("not a 64-bit Mach-O")
    return data, 0


def parse_macho(sl: bytes) -> tuple[list[dict], list[dict]]:
    if len(sl) < 32:
        raise SystemExit("truncated Mach-O")
    magic, _cput, _cpus, _ft, ncmds, sizeofcmds, _fl, _rz = struct.unpack("<IiiIIIII", sl[:32])
    if magic != MH_MAGIC_64:
        raise SystemExit("arm64 slice is not a 64-bit Mach-O")
    segments: list[dict] = []
    sections: list[dict] = []
    p = 32
    for _ in range(ncmds):
        if p + 8 > len(sl):
            raise SystemExit("truncated load commands")
        cmd, cmdsize = struct.unpack("<II", sl[p:p + 8])
        if cmdsize < 8:
            raise SystemExit("invalid load command size")
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


def locate(sl: bytes, segments: list[dict], sections: list[dict]) -> dict:
    text = section(sections, "__text")
    tb = sl[text["fileoff"]:text["fileoff"] + text["size"]]
    text_va = text["vmaddr"]

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
            "no signature hit. This build likely recompiled parseRevokeXML into a new "
            "generation; add a new geometry to SIGNATURES in this file and to "
            "docs/PATCH-270115.md."
        )

    # Convert to VAs and de-duplicate (a hit can match multiple generations only
    # if their deltas coincide; in practice the table is disjoint).
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

    # Weak sanity check: the function entry should start with a stp/sub/pacibsp.
    entry_off = silent_off - OFF_CBZ
    entry_word = struct.unpack_from("<I", sl, entry_off)[0]
    prologue = (
        (entry_word & 0xFFC00000) in (0xA9800000, 0xA9000000)
        or (entry_word & 0xFF0003FF) == 0xD10003FF
        or entry_word == 0xD503237F
    )

    return {
        "generation": sig["name"],
        "entry_va": va - OFF_CBZ,
        "silent_va": va,
        "silent_fileoff_in_slice": silent_off,
        "silent_current": silent_bytes,
        "silent_pristine": sig["cbz"],
        "silent_patch": sig["branch"],
        "silent_state": "pristine" if silent_bytes == sig["cbz"] else "patched-silent",
        "keeptip_va": keeptip_va,
        "keeptip_fileoff_in_slice": keeptip_off,
        "keeptip_current": keeptip_bytes,
        "keeptip_pristine": sig["str_x0"],
        "keeptip_patch": sig["str_xzr"],
        "keeptip_state": "pristine" if keeptip_bytes == sig["str_x0"] else "patched-keeptip",
        "field": sig["field"],
        "delta": sig["delta"],
        "prologue_ok": prologue,
    }


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


def main() -> None:
    ap = argparse.ArgumentParser(description="Locate WeChat 4.x anti-revoke patch points (read-only)")
    ap.add_argument("-a", "--app", default="/Applications/WeChat.app", help="WeChat.app path")
    ap.add_argument("-d", "--dylib", help="wechat.dylib path (overrides --app inference)")
    ap.add_argument("--json", action="store_true", help="print machine-readable JSON")
    args = ap.parse_args()

    app = os.path.abspath(os.path.expanduser(args.app))
    dylib = args.dylib or os.path.join(app, "Contents", "Resources", "wechat.dylib")
    dylib = os.path.abspath(os.path.expanduser(dylib))
    if not os.path.exists(dylib):
        raise SystemExit(f"not found: {dylib}")

    with open(dylib, "rb") as f:
        data = f.read()
    sl, slice_off = arm64_slice(data)
    segments, sections = parse_macho(sl)
    info = read_app_info(app) if not args.dylib else {}
    result = locate(sl, segments, sections)
    result.update({
        "app": app if not args.dylib else None,
        "dylib": dylib,
        "arch": "arm64",
        "slice_offset": slice_off,
        "host_arch": platform.machine(),
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
    print(f"Host arch:     {platform.machine()}  (patch targets arm64)")
    print(f"Generation:    {result['generation']}  (newmsgid field [x19,#0x{result['field']:x}])")
    print(f"parseRevokeXML entry E: 0x{result['entry_va']:x}")
    print(f"silent  VA:    0x{result['silent_va']:x}  "
          f"{result['silent_current']} -> {result['silent_patch']}  [{result['silent_state']}]")
    print(f"keeptip VA:    0x{result['keeptip_va']:x}  "
          f"{result['keeptip_current']} -> {result['keeptip_patch']}  [{result['keeptip_state']}]")
    print(f"STP prologue:  {'ok' if result['prologue_ok'] else 'weak/absent (informational)'}")
    print()
    print("config.json target:")
    print(json.dumps({
        "version": info.get("build") or "REPLACE_WITH_BUILD",
        "targets": [
            {
                "identifier": "revoke",
                "binary": "Contents/Resources/wechat.dylib",
                "entries": [{
                    "arch": "arm64",
                    "addr": f"{result['silent_va']:x}",
                    "expected": result["silent_pristine"],
                    "asm": result["silent_patch"],
                }],
            },
            {
                "identifier": "revoke-keeptip",
                "binary": "Contents/Resources/wechat.dylib",
                "entries": [
                    {
                        "arch": "arm64",
                        "addr": f"{result['silent_va']:x}",
                        "expected": [result["silent_pristine"], result["silent_patch"]],
                        "asm": result["silent_pristine"],
                    },
                    {
                        "arch": "arm64",
                        "addr": f"{result['keeptip_va']:x}",
                        "expected": result["keeptip_pristine"],
                        "asm": result["keeptip_patch"],
                    },
                ],
            },
        ],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
