"""Version arithmetic for manual Sub-Store releases."""

from __future__ import annotations

import re


_VERSION_RE = re.compile(r"(?P<major>[0-9])\.(?P<minor>[0-9])\.(?P<patch>0|[1-9][0-9]?)\Z")
_TAG_RE = re.compile(r"v(?P<version>[0-9]+\.[0-9]+\.[0-9]+)\Z")


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
    if not (0 <= major <= 9 and 0 <= minor <= 9 and 0 <= patch <= 99):
        raise ValueError(f"Version values out of range: {parts!r}")
    return f"{major}.{minor}.{patch}"


def next_version(value: str) -> str | None:
    major, minor, patch = parse_version(value)
    if (major, minor, patch) == (9, 9, 99):
        return None
    if patch < 99:
        patch += 1
    else:
        patch = 0
        if minor < 9:
            minor += 1
        else:
            minor = 0
            major += 1
    return format_version((major, minor, patch))
