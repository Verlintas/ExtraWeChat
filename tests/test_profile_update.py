#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""Validate the profile updater and its published SHA file."""

import hashlib
import json
import os
import sys
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import profile_update as U  # noqa: E402

PROFILES = os.path.join(ROOT, "tools", "revoke_profiles.json")
SHA_FILE = PROFILES + ".sha256"


class ProfileUpdateTests(unittest.TestCase):
    def test_doc_is_valid(self):
        doc = json.load(open(PROFILES, "r", encoding="utf-8"))
        builds, generations = U.validate_doc(doc)
        self.assertGreaterEqual(builds, 40)
        self.assertGreaterEqual(generations, 3)

    def test_published_sha_matches(self):
        raw = open(PROFILES, "rb").read()
        expected = open(SHA_FILE, "r", encoding="utf-8").read().split()[0]
        self.assertEqual(hashlib.sha256(raw).hexdigest(), expected)

    def test_check_from_file_is_up_to_date(self):
        result = U.check(from_file=PROFILES)
        self.assertEqual(result["status"], "up-to-date")
        self.assertEqual(result["remote_builds"], result["local_builds"])

    def test_invalid_doc_is_rejected(self):
        with self.assertRaises(ValueError):
            U.validate_doc({"builds": {}, "generations": []})


if __name__ == "__main__":
    unittest.main()
