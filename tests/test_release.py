#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import release


class RunReleaseTests(unittest.TestCase):
    def write_asset(self, directory: Path, name: str, content: bytes) -> None:
        (directory / name).write_bytes(content)
        digest = hashlib.sha256(content).hexdigest()
        (directory / f"{name}.sha256").write_text(f"{digest}  {name}\n", encoding="ascii")

    def test_release_contains_only_run_installer_and_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.write_asset(directory, "sub-store-0.0.1.run", b"run package")
            self.assertEqual(
                release.release_asset_names("0.0.1"),
                ("sub-store-0.0.1.run", "sub-store-0.0.1.run.sha256"),
            )
            self.assertTrue(release.verify_release_files(directory, "0.0.1"))

    def test_release_requires_valid_run_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.write_asset(directory, "sub-store-0.0.1.run", b"run package")
            (directory / "sub-store-0.0.1.run.sha256").write_text("invalid\n", encoding="ascii")
            self.assertFalse(release.verify_release_files(directory, "0.0.1"))


if __name__ == "__main__":
    unittest.main()
