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


class NativePackageReleaseTests(unittest.TestCase):
    def write_asset(self, directory: Path, name: str, content: bytes) -> None:
        (directory / name).write_bytes(content)
        digest = hashlib.sha256(content).hexdigest()
        (directory / f"{name}.sha256").write_text(f"{digest}  {name}\n", encoding="ascii")

    def test_legacy_release_only_requires_run_installer(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.write_asset(directory, "sub-store-0.0.1.run", b"run package")
            self.assertTrue(release.verify_release_files(directory, "0.0.1", include_native=False))

    def test_native_release_requires_both_package_formats_and_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.write_asset(directory, "sub-store-0.0.1.run", b"run package")
            ipk, apk = release.native_package_names("0.0.1")
            self.write_asset(directory, ipk, b"ipk package")
            self.write_asset(directory, apk, b"apk package")
            self.assertTrue(release.verify_release_files(directory, "0.0.1", include_native=True))

            (directory / f"{apk}.sha256").unlink()
            self.assertFalse(release.verify_release_files(directory, "0.0.1", include_native=True))

    def test_native_marker_keeps_old_releases_compatible(self) -> None:
        self.assertFalse(release.release_includes_native_packages({"body": "old release"}))
        self.assertTrue(release.release_includes_native_packages({"body": release.NATIVE_PACKAGE_MARKER}))


if __name__ == "__main__":
    unittest.main()
