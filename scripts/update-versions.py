#!/usr/bin/env python3
"""Regenerate this registry's ``versions/`` database from ``ports/``.

This is a standalone re-implementation of ``vcpkg x-add-version --all``: it
records, for every port, the git tree object of its directory together with the
version declared in its ``vcpkg.json``. vcpkg resolves a package from a git
registry by looking the version up in ``versions/<prefix>/<port>.json`` and
extracting the recorded ``git-tree`` -- so a stale versions database means
vcpkg either cannot find the port at all or silently builds an older copy of
it.

We implement it here rather than shelling out to vcpkg so that the database can
be regenerated (and checked in CI) without a vcpkg checkout. The tree hash is
computed exactly the way vcpkg computes it -- ``git add`` into a throwaway
index, then ``git write-tree`` -- which means it also covers a port whose
changes are still uncommitted.

Usage::

    scripts/update-versions.py            # rewrite versions/
    scripts/update-versions.py --check    # fail if versions/ is out of date
    scripts/update-versions.py --overwrite-version   # re-point an existing entry

Refusing to re-point an existing ``version``/``port-version`` pair at a new
tree is deliberate: a published version has to keep resolving to the same
sources. Bump ``port-version`` in the port's ``vcpkg.json`` instead (see
``scripts/update-dune-ports.bash``, which does that automatically when a DUNE
pin moves).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REGISTRY_ROOT = Path(__file__).resolve().parent.parent
PORTS_DIR = REGISTRY_ROOT / "ports"
VERSIONS_DIR = REGISTRY_ROOT / "versions"

# The keys vcpkg accepts as a port's version, in the order it looks for them.
# Exactly one may be present, and the versions database has to echo back the
# same key.
VERSION_KEYS = ("version", "version-semver", "version-date", "version-string")


def git(*args: str, env: dict[str, str] | None = None) -> str:
    """Run git in the registry root and return its stripped stdout."""
    full_env = {**os.environ, **(env or {})}
    result = subprocess.run(
        ["git", "-c", "core.autocrlf=false", "-C", str(REGISTRY_ROOT), *args],
        check=True,
        capture_output=True,
        text=True,
        env=full_env,
    )
    return result.stdout.strip()


def git_tree_of(port: str) -> str:
    """Return the git tree object hash of ``ports/<port>``.

    Mirrors vcpkg's own ``x-add-version``: stage the directory into a scratch
    index so that the hash reflects the working tree, not the last commit.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        env = {"GIT_INDEX_FILE": str(Path(tmpdir) / "index")}
        git("read-tree", "--empty", env=env)
        git("add", "--all", "--", f"ports/{port}", env=env)
        root_tree = git("write-tree", env=env)
        return git("rev-parse", f"{root_tree}:ports/{port}", env=env)


def read_port_manifest(port: str) -> tuple[str, str, int]:
    """Return ``(version_key, version, port_version)`` for a port."""
    manifest_path = PORTS_DIR / port / "vcpkg.json"
    manifest = json.loads(manifest_path.read_text())

    if manifest.get("name") != port:
        raise SystemExit(
            f"{manifest_path}: declares name '{manifest.get('name')}' but lives in ports/{port}"
        )

    present = [key for key in VERSION_KEYS if key in manifest]
    if len(present) != 1:
        raise SystemExit(
            f"{manifest_path}: expected exactly one of {', '.join(VERSION_KEYS)}, found {present or 'none'}"
        )

    return present[0], manifest[present[0]], manifest.get("port-version", 0)


def versions_file(port: str) -> Path:
    return VERSIONS_DIR / f"{port[0]}-" / f"{port}.json"


def dump_json(payload: object) -> str:
    """Serialize ``payload`` the way vcpkg writes its own JSON."""
    return json.dumps(payload, indent=2) + "\n"


def build_version_entry(port: str) -> tuple[dict[str, object], str, int]:
    version_key, version, port_version = read_port_manifest(port)
    entry: dict[str, object] = {
        "git-tree": git_tree_of(port),
        version_key: version,
        "port-version": port_version,
    }
    return entry, version, port_version


def merge_versions(port: str, entry: dict[str, object], overwrite: bool) -> str:
    """Return the new contents of ``versions/<prefix>/<port>.json``."""
    path = versions_file(port)
    existing: list[dict[str, object]] = []
    if path.exists():
        existing = json.loads(path.read_text()).get("versions", [])

    version_key = next(key for key in VERSION_KEYS if key in entry)
    port_version = entry["port-version"]

    def same_version(other: dict[str, object]) -> bool:
        return (
            other.get(version_key) == entry[version_key]
            and other.get("port-version", 0) == port_version
        )

    match = next((other for other in existing if same_version(other)), None)
    if match is None:
        # vcpkg reads the list newest-first, so a new version goes on top.
        versions = [entry, *existing]
    elif match["git-tree"] == entry["git-tree"]:
        versions = existing
    elif overwrite:
        versions = [entry if same_version(other) else other for other in existing]
    else:
        raise SystemExit(
            f"{port}: version {entry[version_key]}#{port_version} is already published with a"
            f" different git-tree ({match['git-tree']} != {entry['git-tree']}).\n"
            f"Bump 'port-version' in ports/{port}/vcpkg.json, or pass --overwrite-version if the"
            " published entry was never consumed."
        )

    return dump_json({"versions": versions})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="do not write anything; exit non-zero if versions/ is out of date",
    )
    parser.add_argument(
        "--overwrite-version",
        action="store_true",
        help="allow re-pointing an already published version at a new git-tree",
    )
    args = parser.parse_args()

    ports = sorted(path.name for path in PORTS_DIR.iterdir() if (path / "vcpkg.json").is_file())
    if not ports:
        raise SystemExit(f"no ports found under {PORTS_DIR}")

    wanted: dict[Path, str] = {}
    baseline: dict[str, dict[str, object]] = {}

    for port in ports:
        entry, version, port_version = build_version_entry(port)
        wanted[versions_file(port)] = merge_versions(port, entry, args.overwrite_version)
        baseline[port] = {"baseline": version, "port-version": port_version}

    wanted[VERSIONS_DIR / "baseline.json"] = dump_json({"default": baseline})

    # Any versions file we did not just regenerate belongs to a port that no
    # longer exists; the baseline would then reference a missing port.
    stale = [
        path
        for path in VERSIONS_DIR.rglob("*.json")
        if path not in wanted and path.name != "baseline.json"
    ]

    outdated = [
        path
        for path, content in wanted.items()
        if not path.exists() or path.read_text() != content
    ]

    if args.check:
        for path in outdated:
            print(f"out of date: {path.relative_to(REGISTRY_ROOT)}", file=sys.stderr)
        for path in stale:
            print(f"stale (no such port): {path.relative_to(REGISTRY_ROOT)}", file=sys.stderr)
        if outdated or stale:
            print("\nRun scripts/update-versions.py and commit the result.", file=sys.stderr)
            return 1
        print(f"versions database is up to date ({len(ports)} ports)")
        return 0

    for path in stale:
        path.unlink()
        print(f"removed {path.relative_to(REGISTRY_ROOT)}")
    for path, content in wanted.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    print(f"wrote versions database for {len(ports)} ports ({len(outdated)} changed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
