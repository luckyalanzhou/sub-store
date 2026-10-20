#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def run_publish_with_remote_checksum(
        self, remote_checksum_valid: bool, upload_succeeds: bool = True
    ) -> tuple[list[list[str]], int]:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original_cwd = Path.cwd()
            os.chdir(root)
            try:
                dist = root / "dist"
                dist.mkdir()
                package_name = "sub-store-0.0.1.run"
                package_content = b"run package"
                self.write_asset(dist, package_name, package_content)
                (dist / "release-notes.md").write_text(
                    "Release notes\n\n<!-- sub-store-run-ids: 42 -->\n", encoding="utf-8"
                )

                draft = {"tag_name": "v0.0.1", "draft": True, "assets": []}
                uploaded_draft = {
                    "tag_name": "v0.0.1",
                    "draft": True,
                    "assets": [
                        {"name": name, "size": 1}
                        for name in release.release_asset_names("0.0.1")
                    ],
                }
                published = {
                    "tag_name": "v0.0.1",
                    "draft": False,
                    "published_at": "2026-10-20T00:00:00Z",
                    "assets": [
                        {"name": name, "size": 1}
                        for name in release.release_asset_names("0.0.1")
                    ],
                }
                commands: list[list[str]] = []

                def command(args: list[str]) -> str:
                    commands.append(args)
                    if args[:3] == ["gh", "release", "upload"] and not upload_succeeds:
                        raise release.ReleaseError("simulated asset upload failure")
                    if args[:3] == ["gh", "release", "download"]:
                        download_dir = Path(args[args.index("--dir") + 1])
                        self.write_asset(download_dir, package_name, package_content)
                        if not remote_checksum_valid:
                            checksum_path = download_dir / f"{package_name}.sha256"
                            checksum_path.write_text(
                                f"{'0' * 64}  {package_name}\n", encoding="ascii"
                            )
                    return ""

                env = {
                    "GH_TOKEN": "test-token",
                    "GITHUB_REPOSITORY": "owner/repo",
                    "VERSION": "0.0.1",
                    "TAG": "v0.0.1",
                    "RUN_IDS": "42",
                    "GITHUB_RUN_ID": "42",
                }
                with patch.dict(os.environ, env), \
                     patch("release.get_release_by_tag", side_effect=[draft, uploaded_draft, published]) as get_release, \
                     patch("release.command", side_effect=command):
                    if not upload_succeeds:
                        with self.assertRaisesRegex(release.ReleaseError, "simulated asset upload failure"):
                            release.publish()
                    elif remote_checksum_valid:
                        release.publish()
                    else:
                        with self.assertRaisesRegex(
                            release.ReleaseError, "failed remote SHA-256 verification"
                        ):
                            release.publish()
                return commands, get_release.call_count
            finally:
                os.chdir(original_cwd)

    def test_release_is_published_only_after_remote_checksum_verification(self) -> None:
        commands, release_reads = self.run_publish_with_remote_checksum(remote_checksum_valid=True)
        upload_index = next(
            index for index, args in enumerate(commands)
            if args[:3] == ["gh", "release", "upload"]
        )
        download_index = next(
            index for index, args in enumerate(commands)
            if args[:3] == ["gh", "release", "download"]
        )
        publish_index = next(
            index for index, args in enumerate(commands)
            if args[:3] == ["gh", "release", "edit"] and "--draft=false" in args
        )
        self.assertLess(upload_index, download_index)
        self.assertLess(download_index, publish_index)
        self.assertEqual(release_reads, 3)

    def test_invalid_remote_checksum_keeps_release_unpublished(self) -> None:
        commands, release_reads = self.run_publish_with_remote_checksum(remote_checksum_valid=False)
        self.assertTrue(any(args[:3] == ["gh", "release", "download"] for args in commands))
        self.assertFalse(
            any(
                args[:3] == ["gh", "release", "edit"] and "--draft=false" in args
                for args in commands
            )
        )
        self.assertEqual(release_reads, 2)

    def test_failed_asset_upload_keeps_release_unpublished(self) -> None:
        commands, release_reads = self.run_publish_with_remote_checksum(
            remote_checksum_valid=True, upload_succeeds=False
        )
        self.assertTrue(any(args[:3] == ["gh", "release", "upload"] for args in commands))
        self.assertFalse(
            any(
                args[:3] == ["gh", "release", "edit"] and "--draft=false" in args
                for args in commands
            )
        )
        self.assertEqual(release_reads, 1)


if __name__ == "__main__":
    unittest.main()
