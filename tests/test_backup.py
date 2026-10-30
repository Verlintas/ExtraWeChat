#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Verlintas
# SPDX-License-Identifier: AGPL-3.0-only
"""Backup/restore tests using a tiny fake .app bundle (no codesign)."""

import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = os.path.join(os.path.dirname(__file__), "..")
sys.path.insert(0, os.path.join(ROOT, "tools"))
import backup_copy as B  # noqa: E402


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.app = self.base / "Test.app"
        self.root = self.base / "backups"
        (self.app / "Contents" / "Resources").mkdir(parents=True)
        (self.app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "test.extrawechat",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "123",
        }))
        (self.app / "Contents" / "Resources" / "data.txt").write_text("hello")

    def tearDown(self):
        self.tmp.cleanup()

    def test_create_list_restore_delete(self):
        created = B.create(str(self.app), str(self.root), "first")
        self.assertEqual(created["build"], "123")
        self.assertTrue(os.path.isdir(created["app"]))

        items = B.list_backups(str(self.root))
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["name"], "first")

        (self.app / "Contents" / "Resources" / "data.txt").write_text("changed")
        B.restore(str(self.app), str(self.root), None, True, skip_verify=True)
        self.assertEqual(
            (self.app / "Contents" / "Resources" / "data.txt").read_text(),
            "hello",
        )

        B.delete(str(self.root), "first")
        self.assertEqual(B.list_backups(str(self.root)), [])

    def test_safe_name_rejects_traversal(self):
        created = B.create(str(self.app), str(self.root), "../../evil")
        self.assertIn(created["name"], {"evil", "backup"})
        self.assertTrue(created["path"].startswith(str(self.root)))


if __name__ == "__main__":
    unittest.main()
