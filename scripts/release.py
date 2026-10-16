#!/usr/bin/env python3
"""Allocate, resume, verify, and publish Sub-Store GitHub Releases."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from release_version import format_version, next_version, parse_tag, parse_version


RUN_MARKER_RE = re.compile(r"<!-- sub-store-run-ids: ([0-9,]+) -->")


class ReleaseError(RuntimeError):
    pass


def command(args: list[str], *, capture: bool = True) -> str:
    try:
        result = subprocess.run(
            args,
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except FileNotFoundError as error:
        raise ReleaseError(f"Required command is unavailable: {args[0]}") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise ReleaseError(f"Command failed ({error.returncode}): {' '.join(args)}\n{detail}") from error
    return result.stdout.strip() if capture else ""


def require_environment(*names: str) -> dict[str, str]:
    missing = [name for name in names if not os.environ.get(name)]
    if missing:
        raise ReleaseError(f"Missing required environment variables: {', '.join(missing)}")
    return {name: os.environ[name] for name in names}


def list_api_pages(path: str) -> list[dict[str, Any]]:
    output = command(["gh", "api", "--paginate", path, "--jq", ".[] | @json"])
    return [json.loads(line) for line in output.splitlines() if line.strip()]


def get_release_by_tag(repo: str, tag: str) -> dict[str, Any]:
    releases = list_api_pages(f"repos/{repo}/releases?per_page=100")
    for release in releases:
        if release.get("tag_name") == tag:
            return release
    raise ReleaseError(f"Release {tag} was not found")


def release_ids(body: str) -> list[str]:
    match = RUN_MARKER_RE.search(body or "")
    if not match:
        return []
    return list(dict.fromkeys(match.group(1).split(",")))


def body_with_run_id(body: str, run_id: str) -> tuple[str, list[str]]:
    ids = release_ids(body)
    if run_id not in ids:
        ids.append(run_id)
    clean_body = RUN_MARKER_RE.sub("", body or "").rstrip()
    marker = f"<!-- sub-store-run-ids: {','.join(ids)} -->"
    return (f"{clean_body}\n\n{marker}" if clean_body else marker), ids


def asset_map(release: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {asset["name"]: asset for asset in release.get("assets", [])}


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_files(directory: Path, version: str, expected_digest: str | None = None) -> str | None:
    package_name = f"sub-store-{version}.run"
    checksum_name = f"{package_name}.sha256"
    package_path = directory / package_name
    checksum_path = directory / checksum_name
    if not package_path.is_file() or not checksum_path.is_file():
        return None
    try:
        checksum_line = checksum_path.read_text(encoding="ascii").strip()
    except UnicodeDecodeError:
        return None
    match = re.fullmatch(r"([0-9a-f]{64})[ \t]+\*?" + re.escape(package_name), checksum_line)
    if not match:
        return None
    digest = file_digest(package_path)
    if digest != match.group(1) or (expected_digest is not None and digest != expected_digest):
        return None
    return digest


def release_asset_names(version: str) -> tuple[str, ...]:
    run_name = f"sub-store-{version}.run"
    return run_name, f"{run_name}.sha256"


def verify_release_files(
    directory: Path,
    version: str,
    *,
    expected_digests: dict[str, str] | None = None,
) -> bool:
    run_name = f"sub-store-{version}.run"
    expected_digests = expected_digests or {}
    return verify_files(directory, version, expected_digest=expected_digests.get(run_name)) is not None


def published_release_is_complete(repo: str, release: dict[str, Any], version: str) -> bool:
    names = release_asset_names(version)
    assets = asset_map(release)
    if any(name not in assets or int(assets[name].get("size", 0)) <= 0 for name in names):
        return False

    with tempfile.TemporaryDirectory(prefix="sub-store-release-check-") as temp:
        args = [
            "gh", "release", "download", release["tag_name"],
            "--repo", repo,
        ]
        for name in names:
            args.extend(("--pattern", name))
        args.extend(("--dir", temp))
        command(args)
        return verify_release_files(Path(temp), version)


def matching_version(value: str) -> tuple[int, int, int] | None:
    if not value.startswith("v") or len(value) < 2 or not value[1].isdigit():
        return None
    return parse_tag(value)


def pending_candidates(
    states: list[dict[str, Any]], tag_names: set[str], release_tags: set[str]
) -> list[dict[str, Any]]:
    candidates = {
        state["tag"]: state
        for state in states
        if state["release"].get("draft", False) or not state["complete"]
    }
    for tag in tag_names:
        parts = matching_version(tag)
        if parts is None or tag in release_tags or parts == (0, 0, 0):
            continue
        candidates[tag] = {
            "release": None,
            "tag": tag,
            "version": format_version(parts),
            "parts": parts,
            "complete": False,
        }
    return sorted(candidates.values(), key=lambda state: state["parts"])


def resumable_candidates(
    candidates: list[dict[str, Any]], latest_complete: tuple[int, int, int]
) -> list[dict[str, Any]]:
    return [candidate for candidate in candidates if candidate["parts"] > latest_complete]


def release_commit(repo: str, tag: str) -> str:
    return command(["gh", "api", f"repos/{repo}/commits/{tag}", "--jq", ".sha"])


def set_output(values: dict[str, str]) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        raise ReleaseError("GITHUB_OUTPUT is not set")
    with open(path, "a", encoding="utf-8") as output:
        for name, value in values.items():
            if "\n" in value or "\r" in value:
                raise ReleaseError(f"Output {name} contains a newline")
            output.write(f"{name}={value}\n")


def write_note(body: str) -> str:
    fd, path = tempfile.mkstemp(prefix="sub-store-release-note-", text=True)
    with os.fdopen(fd, "w", encoding="utf-8") as note:
        note.write(body + "\n")
    return path


def update_draft(
    repo: str,
    tag: str,
    version: str,
    body: str,
    target_sha: str | None = None,
    tag_exists: bool = True,
) -> None:
    if target_sha and tag_exists:
        command([
            "gh", "api", "--method", "PATCH", f"repos/{repo}/git/refs/tags/{tag}",
            "-F", f"sha={target_sha}",
            "-F", "force=true",
        ])
    note_path = write_note(body)
    try:
        args = [
            "gh", "release", "edit", tag,
            "--repo", repo,
            "--draft",
            "--title", f"sub-store v{version}",
            "--notes-file", note_path,
        ]
        if target_sha:
            args.extend(["--target", target_sha])
        command(args)
    finally:
        Path(note_path).unlink(missing_ok=True)


def create_draft(repo: str, tag: str, version: str, source_sha: str, body: str, verify_tag: bool) -> None:
    note_path = write_note(body)
    try:
        args = [
            "gh", "release", "create", tag,
            "--repo", repo,
            "--draft",
            "--target", source_sha,
            "--title", f"sub-store v{version}",
            "--notes-file", note_path,
        ]
        if verify_tag:
            args.append("--verify-tag")
        command(args)
    finally:
        Path(note_path).unlink(missing_ok=True)


def prepare() -> None:
    env = require_environment(
        "GH_TOKEN", "GITHUB_REPOSITORY", "GITHUB_REF", "GITHUB_SHA", "GITHUB_RUN_ID", "BUMP_TYPE"
    )
    if env["GITHUB_REF"] != "refs/heads/main":
        raise ReleaseError("正式发布只能从 main 分支手动启动")
    if env["BUMP_TYPE"] not in {"patch", "minor", "major"}:
        raise ReleaseError("版本升级类型只能是 patch、minor 或 major")

    repo = env["GITHUB_REPOSITORY"]
    run_id = env["GITHUB_RUN_ID"]
    releases = list_api_pages(f"repos/{repo}/releases?per_page=100")
    tag_items = list_api_pages(f"repos/{repo}/tags?per_page=100")
    tag_names = {item["name"] for item in tag_items}

    states: list[dict[str, Any]] = []
    release_tags: set[str] = set()
    for release in releases:
        tag = str(release.get("tag_name", ""))
        version_parts = matching_version(tag)
        if version_parts is None:
            continue
        if version_parts == (0, 0, 0):
            raise ReleaseError("v0.0.0 is the starting baseline, not a formal release version")
        version = format_version(version_parts)
        complete = False
        if not release.get("draft", False):
            complete = published_release_is_complete(repo, release, version)
        state = {"release": release, "tag": tag, "version": version, "parts": version_parts, "complete": complete}
        states.append(state)
        release_tags.add(tag)

    # Rerunning all jobs after publication is an idempotent success, not a new release.
    same_run = [state for state in states if run_id in release_ids(state["release"].get("body", ""))]
    if len(same_run) > 1:
        raise ReleaseError(f"Workflow run {run_id} is recorded on more than one release")
    if same_run and same_run[0]["complete"]:
        state = same_run[0]
        set_output({
            "version": state["version"],
            "tag": state["tag"],
            "source_sha": release_commit(repo, state["tag"]),
            "previous_tag": "",
            "run_ids": ",".join(release_ids(state["release"].get("body", ""))),
            "already_complete": "true",
        })
        print(f"v{state['version']} is already complete for workflow run {run_id}; skipping release.")
        return

    candidates = pending_candidates(states, tag_names, release_tags)
    complete_states = [state for state in states if state["complete"]]
    latest = max((state["parts"] for state in complete_states), default=(0, 0, 0))
    resumable = resumable_candidates(candidates, latest)
    if same_run:
        selected = same_run[0]
        selected_tag = selected["tag"]
    elif len(resumable) == 1:
        selected = resumable[0]
        selected_tag = selected["tag"]
    elif len(resumable) > 1:
        tags = ", ".join(candidate["tag"] for candidate in resumable)
        raise ReleaseError(f"Multiple unfinished releases require manual cleanup: {tags}")
    else:
        current = format_version(latest)
        version = next_version(current, env["BUMP_TYPE"])
        selected_tag = f"v{version}"
        selected = {
            "release": None,
            "tag": selected_tag,
            "version": version,
            "parts": parse_tag(selected_tag),
            "complete": False,
        }

    version = selected["version"]
    if selected["release"] is None and selected_tag not in tag_names:
        source_sha = env["GITHUB_SHA"]
    elif selected["release"] and selected["release"].get("draft", False):
        prior_ids = release_ids(selected["release"].get("body", ""))
        if run_id not in prior_ids:
            # A fresh manual run may include fixes committed after the draft was allocated.
            source_sha = env["GITHUB_SHA"]
        elif selected_tag not in tag_names:
            # GitHub drafts do not necessarily create their tag until publication.
            source_sha = str(selected["release"].get("target_commitish", ""))
            if not source_sha:
                raise ReleaseError(f"Draft release {selected_tag} has no saved target commit")
        else:
            source_sha = release_commit(repo, selected_tag)
    else:
        if selected_tag not in tag_names:
            raise ReleaseError(f"Release {selected_tag} has no Git tag or resumable draft target")
        source_sha = release_commit(repo, selected_tag)

    complete_before = [state for state in states if state["complete"] and state["parts"] < selected["parts"]]
    previous_tag = max(complete_before, key=lambda state: state["parts"])["tag"] if complete_before else ""
    prior_ids = release_ids(selected["release"].get("body", "") if selected["release"] else "")
    body, all_ids = body_with_run_id("Release is being prepared by GitHub Actions.", run_id) if not prior_ids else body_with_run_id(
        selected["release"].get("body", ""), run_id
    )

    if selected["release"] is None:
        create_draft(repo, selected_tag, version, source_sha, body, verify_tag=selected_tag in tag_names)
    else:
        target_sha = source_sha if selected["release"].get("draft", False) and run_id not in prior_ids else None
        update_draft(
            repo,
            selected_tag,
            version,
            body,
            target_sha=target_sha,
            tag_exists=selected_tag in tag_names,
        )

    # Existing tags are authoritative; drafts without tags retain their saved target SHA.
    if selected_tag in tag_names:
        source_sha = release_commit(repo, selected_tag)
    set_output({
        "version": version,
        "tag": selected_tag,
        "source_sha": source_sha,
        "previous_tag": previous_tag,
        "run_ids": ",".join(all_ids),
        "already_complete": "false",
    })
    print(f"Allocated or resumed sub-store v{version} from {source_sha}.")


def publish() -> None:
    env = require_environment("GH_TOKEN", "GITHUB_REPOSITORY", "VERSION", "TAG", "RUN_IDS", "GITHUB_RUN_ID")
    repo = env["GITHUB_REPOSITORY"]
    version = env["VERSION"]
    expected_tag = f"v{version}"
    if env["TAG"] != expected_tag:
        raise ReleaseError(f"Release tag mismatch: expected {expected_tag}, got {env['TAG']}")
    parse_version(version)

    existing = get_release_by_tag(repo, env["TAG"])
    if not existing.get("draft", False):
        if published_release_is_complete(repo, existing, version):
            if env["GITHUB_RUN_ID"] in release_ids(existing.get("body", "")):
                print(f"sub-store v{version} is already complete for workflow run {env['GITHUB_RUN_ID']}.")
                return
            raise ReleaseError(f"Refusing to overwrite complete release {env['TAG']}")

    notes = Path("dist/release-notes.md").read_text(encoding="utf-8")
    names = release_asset_names(version)
    package_paths = [Path("dist") / name for name in names if not name.endswith(".sha256")]
    package_asset_names = [name for name in names if not name.endswith(".sha256")]

    digest = verify_files(Path("dist"), version)
    if digest is None or not verify_release_files(Path("dist"), version):
        raise ReleaseError("A local installation package or its SHA-256 checksum is missing or invalid")
    expected_digests = {
        name: file_digest(Path("dist") / name)
        for name in names
        if not name.endswith(".sha256")
    }
    if f"<!-- sub-store-run-ids: {env['RUN_IDS']} -->" not in notes:
        raise ReleaseError("Release notes are missing this run's recovery marker")
    if not existing.get("draft", False):
        # Repair an incomplete published release under the same version, keeping it hidden until verified.
        command([
            "gh", "release", "edit", env["TAG"],
            "--repo", repo,
            "--draft",
            "--title", f"sub-store v{version}",
            "--notes-file", "dist/release-notes.md",
        ])

    command([
        "gh", "release", "upload", env["TAG"],
        "--repo", repo,
        "--clobber",
        *[str(path) for path in package_paths],
        *[str(Path("dist") / f"{name}.sha256") for name in package_asset_names],
    ])
    command([
        "gh", "release", "edit", env["TAG"],
        "--repo", repo,
        "--draft",
        "--title", f"sub-store v{version}",
        "--notes-file", "dist/release-notes.md",
    ])

    release = get_release_by_tag(repo, env["TAG"])
    if not release.get("draft", False):
        raise ReleaseError("Release left draft state before asset verification")
    assets = asset_map(release)
    for name in names:
        if name not in assets or int(assets[name].get("size", 0)) <= 0:
            raise ReleaseError(f"Release asset is missing or empty: {name}")

    with tempfile.TemporaryDirectory(prefix="sub-store-release-verify-") as temp:
        args = [
            "gh", "release", "download", env["TAG"],
            "--repo", repo,
        ]
        for name in names:
            args.extend(("--pattern", name))
        args.extend(("--dir", temp))
        command(args)
        if not verify_release_files(
            Path(temp), version, expected_digests=expected_digests
        ):
            raise ReleaseError("Uploaded installation packages failed remote SHA-256 verification")
        remote_digest = verify_files(Path(temp), version, expected_digest=digest)
        if remote_digest is None:
            raise ReleaseError("Uploaded installer failed remote SHA-256 verification")

    command(["gh", "release", "edit", env["TAG"], "--repo", repo, "--draft=false"])
    final_release = get_release_by_tag(repo, env["TAG"])
    if final_release.get("draft", True) or not final_release.get("published_at"):
        raise ReleaseError("Release assets verified, but GitHub did not confirm publication")
    final_assets = asset_map(final_release)
    if any(name not in final_assets or int(final_assets[name].get("size", 0)) <= 0 for name in names):
        raise ReleaseError("Published release is missing an installation package or checksum asset")
    print(f"Published sub-store v{version}; SHA-256 {digest} verified.")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"prepare", "publish"}:
        print(f"Usage: {sys.argv[0]} prepare|publish", file=sys.stderr)
        return 2
    try:
        prepare() if sys.argv[1] == "prepare" else publish()
    except (ReleaseError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
