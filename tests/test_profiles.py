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


if __name__ == "__main__":
    unittest.main()
