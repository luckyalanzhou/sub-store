"""Version arithmetic for manual Sub-Store releases."""

from __future__ import annotations

import re


_VERSION_RE = re.compile(
    r"(?P<major>0|[1-9][0-9]*)\.(?P<minor>0|[1-9][0-9]*)\.(?P<patch>0|[1-9][0-9]*)\Z"
)
_TAG_RE = re.compile(r"v(?P<version>[0-9]+\.[0-9]+\.[0-9]+)\Z")
_BUMP_TYPES = {"patch", "minor", "major"}


def parse_version(value: str) -> tuple[int, int, int]:
    match = _VERSION_RE.fullmatch(value)
    if not match:
        raise ValueError(f"Invalid release version: {value!r}")
    return tuple(int(match.group(name)) for name in ("major", "minor", "patch"))


def parse_tag(tag: str) -> tuple[int, int, int] | None:
    match = _TAG_RE.fullmatch(tag)
    if not match:
        if re.match(r"^v[0-9]", tag):
            raise ValueError(f"Invalid version tag: {tag!r}")
        return None
    return parse_version(match.group("version"))


def format_version(parts: tuple[int, int, int]) -> str:
    major, minor, patch = parts
    if min(parts) < 0:
        raise ValueError(f"Version values must be non-negative: {parts!r}")
    return f"{major}.{minor}.{patch}"


def next_version(value: str, bump_type: str = "patch") -> str:
    major, minor, patch = parse_version(value)
    if bump_type not in _BUMP_TYPES:
        raise ValueError(f"Invalid bump type: {bump_type!r}; choose patch, minor, or major")
    if bump_type == "patch":
        patch += 1
    elif bump_type == "minor":
        minor += 1
        patch = 0
    else:
        major += 1
        minor = 0
        patch = 0
    return format_version((major, minor, patch))
