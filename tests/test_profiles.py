#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""Validate the per-build anti-revoke profile table.

Run: python3 -m unittest discover -s tests -v
"""

import json
import os
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..")
PROFILES = os.path.join(ROOT, "tools", "revoke_profiles.json")


class ProfileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(PROFILES, "r", encoding="utf-8") as f:
            cls.doc = json.load(f)

    def test_build_table_is_not_empty(self):
        builds = self.doc.get("builds", {})
        self.assertGreaterEqual(len(builds), 40)
        self.assertIn("270115", builds)

    def test_arm64_entries_are_consistent(self):
        for build, arches in self.doc["builds"].items():
            self.assertIn("arm64", arches, build)
            for variant in ("silent", "keeptip"):
                for entry in arches["arm64"].get(variant, []):
                    self.assertRegex(entry["addr"], r"^[0-9a-f]+$", build)
                    self.assertRegex(entry["asm"], r"^[0-9A-F]+$", build)
                    self.assertEqual(len(entry["asm"]) % 2, 0, build)
                    self.assertTrue(entry["expected"], build)
                    for expected in entry["expected"]:
                        self.assertRegex(expected, r"^[0-9A-F]+$", build)
                        self.assertEqual(len(expected) % 2, 0, build)
                        self.assertEqual(len(expected), len(entry["asm"]),
                                         f"{build}: expected/patch length mismatch")

    def test_270115_known_points(self):
        arm = self.doc["builds"]["270115"]["arm64"]
        self.assertEqual(arm["silent"][0]["addr"], "4bbb1dc")
        self.assertEqual(arm["silent"][0]["expected"], ["40100034"])
        self.assertEqual(arm["silent"][0]["asm"], "82000014")
        self.assertEqual(arm["keeptip"][0]["addr"], "4bbb1dc")
        self.assertEqual(arm["keeptip"][1]["addr"], "4bbb97c")
        self.assertEqual(arm["keeptip"][1]["asm"], "7FE600F9")

    def test_269602_special_profile(self):
        arm = self.doc["builds"]["269602"]["arm64"]
        self.assertEqual(arm["silent"][0]["expected"], ["F44FBEA9FD7B01A9"])
        self.assertEqual(arm["silent"][0]["asm"], "00008052C0035FD6")
        self.assertGreaterEqual(len(arm["keeptip"]), 3)

    def test_268880_only_silent(self):
        arm = self.doc["builds"]["268880"]["arm64"]
        self.assertTrue(arm["silent"])
        self.assertFalse(arm.get("keeptip"))

    def test_every_profile_has_a_variant(self):
        for build, arches in self.doc["builds"].items():
            for arch, profile in arches.items():
                self.assertIn(arch, ("arm64", "x86_64"), build)
                self.assertTrue(profile.get("silent") or profile.get("keeptip"),
                                f"{build}/{arch} has no entries")

    def test_entries_do_not_overlap_within_variant(self):
        for build, arches in self.doc["builds"].items():
            for arch, profile in arches.items():
                for variant in ("silent", "keeptip"):
                    ranges = []
                    for entry in profile.get(variant, []):
                        start = int(entry["addr"], 16)
                        size = len(entry["asm"]) // 2
                        ranges.append((start, start + size))
                    ranges.sort()
                    for (a_start, a_end), (b_start, _b_end) in zip(ranges, ranges[1:]):
                        self.assertLessEqual(a_end, b_start,
                                             f"{build}/{arch}/{variant}: overlapping entries")


if __name__ == "__main__":
    unittest.main()
