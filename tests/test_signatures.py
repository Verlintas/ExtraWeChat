#!/usr/bin/env python3
"""Self-consistency checks for the anti-revoke geometry table.

Run: python3 -m unittest discover -s tests -v
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import locate_revoke as L  # noqa: E402


class SignatureTests(unittest.TestCase):
    def test_branch_and_cbz_targets_match(self):
        for sig in L.SIGNATURES:
            cbz = L.word_from_hex(sig["cbz"])
            branch = L.word_from_hex(sig["branch"])
            # CBZ is at PC; both instructions are 4-byte aligned and branch to
            # the same target. imm19 (CBZ) / imm26 (B) are both PC-relative /4.
            self.assertEqual(
                (cbz >> 5) & 0x7FFFF,
                branch & 0x3FFFFFF,
                f"{sig['name']}: cbz/branch target mismatch",
            )

    def test_str_pair_only_differs_in_rt(self):
        mask = L.STR_RT_MASK
        for sig in L.SIGNATURES:
            x0 = L.word_from_hex(sig["str_x0"])
            xzr = L.word_from_hex(sig["str_xzr"])
            self.assertEqual(x0 & mask, xzr & mask, f"{sig['name']}: str opcode mismatch")
            self.assertEqual(x0 & 0x1F, 0, f"{sig['name']}: str_x0 Rt is not x0")
            self.assertEqual(xzr & 0x1F, 31, f"{sig['name']}: str_xzr Rt is not xzr")

    def test_geometry_is_aligned_and_in_range(self):
        for sig in L.SIGNATURES:
            self.assertEqual(L.OFF_CBZ % 4, 0)
            self.assertEqual(sig["delta"] % 4, 0, f"{sig['name']}: delta not aligned")
            self.assertGreater(sig["delta"], 0)
            self.assertEqual(sig["field"] % 8, 0, f"{sig['name']}: newmsgid field not 8-byte aligned")

    def test_generations_are_distinct(self):
        keys = {(s["cbz"], s["branch"], s["delta"], s["str_x0"]) for s in L.SIGNATURES}
        self.assertEqual(len(keys), len(L.SIGNATURES))


if __name__ == "__main__":
    unittest.main()
