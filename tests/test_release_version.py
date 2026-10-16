import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from release import (  # noqa: E402
    ReleaseError,
    body_with_run_id,
    get_release_by_tag,
    pending_candidates,
    prepare,
    publish,
    resumable_candidates,
    verify_files,
)
from release_version import next_version, parse_tag, parse_version  # noqa: E402


class ReleaseVersionTests(unittest.TestCase):
    def test_release_lookup_finds_draft_by_tag_from_release_list(self):
        draft = {"tag_name": "v0.0.1", "draft": True, "target_commitish": "source-sha"}
        with patch("release.list_api_pages", return_value=[{"tag_name": "v0.0.2"}, draft]) as list_mock:
            self.assertEqual(get_release_by_tag("owner/repo", "v0.0.1"), draft)
        list_mock.assert_called_once_with("repos/owner/repo/releases?per_page=100")

    def test_patch_minor_and_major_bumps(self):
        self.assertEqual(next_version("0.0.0"), "0.0.1")
        self.assertEqual(next_version("1.9.99", "patch"), "1.9.100")
        self.assertEqual(next_version("1.4.12", "minor"), "1.5.0")
        self.assertEqual(next_version("1.4.12", "major"), "2.0.0")

    def test_invalid_bump_type_is_rejected(self):
        with self.assertRaises(ValueError):
            next_version("1.4.12", "release")

    def test_unbounded_numeric_components_and_canonical_format(self):
        for version in ("0.0.0", "999.1000.10000", "2.3.4"):
            self.assertEqual(parse_version(version), tuple(map(int, version.split("."))))
        for version in ("0.0.01", "00.0.1", "1.00.1", "1.2", "v1.2.3", "-1.0.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                parse_version(version)

    def test_version_tags_are_strict(self):
        self.assertEqual(parse_tag("v1.9.100"), (1, 9, 100))
        self.assertEqual(parse_tag("v999.1000.10000"), (999, 1000, 10000))
        self.assertIsNone(parse_tag("latest"))
        for tag in ("v01.0.0", "v1.00.0", "v1.0.01"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                parse_tag(tag)

    def test_pending_versions_sort_by_numeric_components(self):
        tags = {"v1.10.0", "v1.9.100", "v1.9.99"}
        candidates = pending_candidates([], tags, set())
        self.assertEqual([candidate["tag"] for candidate in candidates], [
            "v1.9.99", "v1.9.100", "v1.10.0",
        ])

    def test_incomplete_release_and_orphan_tag_resume_before_increment(self):
        releases = [
            {"release": {"draft": False}, "tag": "v0.0.2", "version": "0.0.2", "parts": (0, 0, 2), "complete": True},
            {"release": {"draft": True}, "tag": "v0.0.3", "version": "0.0.3", "parts": (0, 0, 3), "complete": False},
            {"release": {"draft": False}, "tag": "v0.0.4", "version": "0.0.4", "parts": (0, 0, 4), "complete": False},
        ]
        candidates = pending_candidates(releases, {"v0.0.3", "v0.0.5", "v0.0.0"}, {"v0.0.2", "v0.0.3", "v0.0.4"})
        self.assertEqual([state["tag"] for state in candidates], ["v0.0.3", "v0.0.4", "v0.0.5"])

    def test_only_unfinished_versions_after_latest_complete_are_resumable(self):
        candidates = [
            {"tag": "v0.0.9", "parts": (0, 0, 9)},
            {"tag": "v0.0.22", "parts": (0, 0, 22)},
        ]
        self.assertEqual(
            [candidate["tag"] for candidate in resumable_candidates(candidates, (0, 0, 21))],
            ["v0.0.22"],
        )

    def test_prepare_rejects_multiple_newer_unfinished_versions(self):
        drafts = [
            {"tag_name": "v0.0.3", "draft": True, "body": "", "assets": []},
            {"tag_name": "v0.0.4", "draft": True, "body": "", "assets": []},
        ]
        with tempfile.TemporaryDirectory() as temp:
            env = {
                "GH_TOKEN": "test-token",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_SHA": "source-sha",
                "GITHUB_RUN_ID": "100",
                "GITHUB_OUTPUT": str(Path(temp) / "github-output"),
                "BUMP_TYPE": "patch",
            }
            with patch.dict(os.environ, env), \
                 patch("release.list_api_pages", side_effect=[drafts, []]), \
                 self.assertRaisesRegex(ReleaseError, "Multiple unfinished releases"):
                prepare()

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
                "BUMP_TYPE": "patch",
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
            "tag_name": "v1.4.12",
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
                "BUMP_TYPE": "minor",
            }
            with patch.dict(os.environ, env), \
                 patch("release.list_api_pages", side_effect=[[complete], [{"name": "v1.4.12"}]]), \
                 patch("release.published_release_is_complete", return_value=True), \
                 patch("release.command") as command_mock, \
                 patch("release.release_commit", return_value="new-source-sha"):
                prepare()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(values["version"], "1.5.0")
            self.assertEqual(values["previous_tag"], "v1.4.12")
            create_args = command_mock.call_args.args[0]
            self.assertEqual(create_args[:4], ["gh", "release", "create", "v1.5.0"])

    def test_new_dispatch_resumes_draft_version_and_records_both_runs(self):
        draft = {
            "tag_name": "v0.0.7",
            "draft": True,
            "target_commitish": "original-source-sha",
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
                "BUMP_TYPE": "major",
            }
            with patch.dict(os.environ, env), \
                 patch("release.list_api_pages", side_effect=[[draft], []]), \
                 patch("release.command") as command_mock, \
                 patch("release.release_commit") as release_commit_mock:
                prepare()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(values["version"], "0.0.7")
            self.assertEqual(values["run_ids"], "99,100")
            self.assertEqual(values["source_sha"], "new-source-sha")
            edit_args = next(args for (args,), _ in command_mock.call_args_list if args[:3] == ["gh", "release", "edit"])
            self.assertIn("--target", edit_args)
            self.assertFalse(any(args[1:3] == ["api", "--method"] for (args,), _ in command_mock.call_args_list))
            release_commit_mock.assert_not_called()

    def test_retry_of_draft_without_tag_uses_saved_target_commit(self):
        draft = {
            "tag_name": "v0.0.1",
            "draft": True,
            "target_commitish": "original-source-sha",
            "body": "<!-- sub-store-run-ids: 100 -->",
            "assets": [],
        }
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "github-output"
            env = {
                "GH_TOKEN": "test-token",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_SHA": "later-source-sha",
                "GITHUB_RUN_ID": "100",
                "GITHUB_OUTPUT": str(output),
                "BUMP_TYPE": "patch",
            }
            with patch.dict(os.environ, env), \
                 patch("release.list_api_pages", side_effect=[[draft], []]), \
                 patch("release.command"), \
                 patch("release.release_commit") as release_commit_mock:
                prepare()
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
            self.assertEqual(values["version"], "0.0.1")
            self.assertEqual(values["source_sha"], "original-source-sha")
            release_commit_mock.assert_not_called()

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
                "BUMP_TYPE": "major",
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
             patch("release.list_api_pages", return_value=[release_data]), \
             patch("release.published_release_is_complete", return_value=True), \
             patch("release.verify_files") as verify_mock, \
             patch("release.Path.read_text", side_effect=FileNotFoundError("dist/release-notes.md")) as read_notes_mock:
            publish()
        verify_mock.assert_not_called()
        read_notes_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
