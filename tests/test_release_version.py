import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from release import body_with_run_id, pending_candidates, prepare, publish, verify_files  # noqa: E402
from release_version import next_version, parse_tag, parse_version  # noqa: E402


class ReleaseVersionTests(unittest.TestCase):
    def test_patch_and_minor_rollover(self):
        self.assertEqual(next_version("0.0.0"), "0.0.1")
        self.assertEqual(next_version("0.0.98"), "0.0.99")
        self.assertEqual(next_version("0.0.99"), "0.1.0")
        self.assertEqual(next_version("0.9.99"), "1.0.0")
        self.assertEqual(next_version("9.9.98"), "9.9.99")

    def test_maximum_stops_without_wrapping(self):
        self.assertIsNone(next_version("9.9.99"))

    def test_version_ranges_and_canonical_patch(self):
        for version in ("0.0.0", "9.9.99", "2.3.4"):
            self.assertEqual(parse_version(version), tuple(map(int, version.split("."))))
        for version in ("10.0.0", "0.10.0", "0.0.100", "0.0.01", "00.0.1", "v0.0.1", "1.2"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                parse_version(version)

    def test_version_tags_are_strict(self):
        self.assertEqual(parse_tag("v0.0.99"), (0, 0, 99))
        self.assertIsNone(parse_tag("latest"))
        with self.assertRaises(ValueError):
            parse_tag("v0.0.100")

    def test_incomplete_release_and_orphan_tag_resume_before_increment(self):
        releases = [
            {"release": {"draft": False}, "tag": "v0.0.2", "version": "0.0.2", "parts": (0, 0, 2), "complete": True},
            {"release": {"draft": True}, "tag": "v0.0.3", "version": "0.0.3", "parts": (0, 0, 3), "complete": False},
            {"release": {"draft": False}, "tag": "v0.0.4", "version": "0.0.4", "parts": (0, 0, 4), "complete": False},
        ]
        candidates = pending_candidates(releases, {"v0.0.3", "v0.0.5", "v0.0.0"}, {"v0.0.2", "v0.0.3", "v0.0.4"})
        self.assertEqual([state["tag"] for state in candidates], ["v0.0.3", "v0.0.4", "v0.0.5"])

    def test_run_marker_is_preserved_and_deduplicated(self):
        body, ids = body_with_run_id("Notes\n\n<!-- sub-store-run-ids: 10,11 -->", "11")
        self.assertEqual(ids, ["10", "11"])
        self.assertEqual(body, "Notes\n\n<!-- sub-store-run-ids: 10,11 -->")
        body, ids = body_with_run_id(body, "12")
        self.assertEqual(ids, ["10", "11", "12"])

    def test_checksum_verifier_requires_matching_file_and_filename(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            package_name = "sub-store-0.0.1.run"
            package = b"package contents"
            (directory / package_name).write_bytes(package)
            digest = hashlib.sha256(package).hexdigest()
            checksum = directory / f"{package_name}.sha256"
            checksum.write_text(f"{digest}  {package_name}\n", encoding="ascii")
            self.assertEqual(verify_files(directory, "0.0.1"), digest)
            self.assertEqual(verify_files(directory, "0.0.1", expected_digest=digest), digest)
            self.assertIsNone(verify_files(directory, "0.0.1", expected_digest="0" * 64))
            checksum.write_text(f"{digest}  other.run\n", encoding="ascii")
            self.assertIsNone(verify_files(directory, "0.0.1"))

    def test_first_manual_release_allocates_baseline_successor(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "github-output"
            env = {
                "GH_TOKEN": "test-token",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_SHA": "source-sha",
                "GITHUB_RUN_ID": "100",
                "GITHUB_OUTPUT": str(output),
            }
            with patch.dict(os.environ, env), \
                 patch("release.list_api_pages", side_effect=[[], []]), \
                 patch("release.command") as command_mock, \
                 patch("release.release_commit", return_value="source-sha"):
                prepare()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(values["version"], "0.0.1")
            self.assertEqual(values["tag"], "v0.0.1")
            self.assertEqual(values["already_complete"], "false")
            create_args = command_mock.call_args.args[0]
            self.assertEqual(create_args[:4], ["gh", "release", "create", "v0.0.1"])
            self.assertIn("--draft", create_args)

    def test_next_manual_release_increments_after_last_complete_release(self):
        complete = {
            "tag_name": "v0.0.6",
            "draft": False,
            "body": "<!-- sub-store-run-ids: 90 -->",
            "assets": [],
        }
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "github-output"
            env = {
                "GH_TOKEN": "test-token",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_SHA": "new-source-sha",
                "GITHUB_RUN_ID": "101",
                "GITHUB_OUTPUT": str(output),
            }
            with patch.dict(os.environ, env), \
                 patch("release.list_api_pages", side_effect=[[complete], [{"name": "v0.0.6"}]]), \
                 patch("release.published_release_is_complete", return_value=True), \
                 patch("release.command") as command_mock, \
                 patch("release.release_commit", return_value="new-source-sha"):
                prepare()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(values["version"], "0.0.7")
            self.assertEqual(values["previous_tag"], "v0.0.6")
            create_args = command_mock.call_args.args[0]
            self.assertEqual(create_args[:4], ["gh", "release", "create", "v0.0.7"])

    def test_new_dispatch_resumes_draft_version_and_records_both_runs(self):
        draft = {
            "tag_name": "v0.0.7",
            "draft": True,
            "body": "<!-- sub-store-run-ids: 99 -->",
            "assets": [],
        }
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "github-output"
            env = {
                "GH_TOKEN": "test-token",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_SHA": "new-source-sha",
                "GITHUB_RUN_ID": "100",
                "GITHUB_OUTPUT": str(output),
            }
            with patch.dict(os.environ, env), \
                 patch("release.list_api_pages", side_effect=[[draft], [{"name": "v0.0.7"}]]), \
                 patch("release.command") as command_mock, \
                 patch("release.release_commit", return_value="new-source-sha"):
                prepare()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(values["version"], "0.0.7")
            self.assertEqual(values["run_ids"], "99,100")
            self.assertEqual(values["source_sha"], "new-source-sha")
            self.assertTrue(any(args[1:3] == ["api", "--method"] for (args,), _ in command_mock.call_args_list))

    def test_incomplete_published_release_is_demoted_and_resumed(self):
        incomplete = {
            "tag_name": "v0.0.8",
            "draft": False,
            "body": "Previous release notes",
            "assets": [{"name": "sub-store-0.0.8.run", "size": 10}],
        }
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "github-output"
            env = {
                "GH_TOKEN": "test-token",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_SHA": "new-source-sha",
                "GITHUB_RUN_ID": "101",
                "GITHUB_OUTPUT": str(output),
            }
            with patch.dict(os.environ, env), \
                 patch("release.list_api_pages", side_effect=[[incomplete], [{"name": "v0.0.8"}]]), \
                 patch("release.published_release_is_complete", return_value=False), \
                 patch("release.command") as command_mock, \
                 patch("release.release_commit", return_value="original-source-sha"):
                prepare()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(values["version"], "0.0.8")
            self.assertEqual(values["source_sha"], "original-source-sha")
            self.assertEqual(values["already_complete"], "false")
            edit_args = next(args for (args,), _ in command_mock.call_args_list if args[:3] == ["gh", "release", "edit"])
            self.assertIn("--draft", edit_args)

    def test_complete_release_from_same_run_is_not_overwritten_on_retry(self):
        release_data = {
            "tag_name": "v0.0.1",
            "draft": False,
            "body": "<!-- sub-store-run-ids: 100 -->",
            "assets": [],
        }
        with patch.dict(os.environ, {
            "GH_TOKEN": "test-token",
            "GITHUB_REPOSITORY": "owner/repo",
            "VERSION": "0.0.1",
            "TAG": "v0.0.1",
            "RUN_IDS": "100",
            "GITHUB_RUN_ID": "100",
        }), \
             patch("release.command", return_value=json.dumps(release_data)), \
             patch("release.published_release_is_complete", return_value=True), \
             patch("release.verify_files") as verify_mock:
            publish()
        verify_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
