#!/usr/bin/env python3
"""Repair the per-run paths in a restored SwiftPM cache, and drop it when it cannot be."""

from __future__ import annotations

import os
import re
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path


BUILD = Path(sys.argv[1])
DATABASE = BUILD / "out/Intermediates.noindex/XCBuildData/build.db"
OLD_ROOT = re.compile(
    rb"/(?:private/)?var/run/com\.apple\.security\.cryptexd/mnt/"
    rb"com\.apple\.MobileAsset\.MetalToolchain-[^/]+(?=/Metal\.xctoolchain)"
)
XCODE_APP = re.compile(rb"/Applications/(Xcode[^/]*)\.app")
MACOSX_SDK = re.compile(rb"/SDKs/(MacOSX[^/]*)\.sdk")
SOURCE_EPOCH = 946684800  # 2000-01-01 UTC; exact-content cache key guards freshness.


def current_metal_root() -> bytes:
    metal = Path(subprocess.check_output(["xcrun", "--find", "metal"], text=True).strip()).resolve()
    return str(metal.parents[3]).encode()


def current_xcode_app() -> set[bytes]:
    return {path.name.removesuffix(".app").encode() for path in Path("/Applications").glob("Xcode*.app")}


def current_macosx_sdk() -> set[bytes]:
    sdk = Path(subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
    return {path.name.removesuffix(".sdk").encode() for path in sdk.parents[0].glob("MacOSX*.sdk")}


def normalize_source_timestamps(package: Path) -> None:
    paths = [package / "Package.swift", package / "Package.resolved"]
    for name in ("Sources", "Tests", "Plugins"):
        paths.extend((package / name).rglob("*"))
    for path in paths:
        if path.is_file():
            try:
                os.utime(path, (SOURCE_EPOCH, SOURCE_EPOCH))
            except OSError:
                pass


def drop_cached_outputs(reason: str) -> None:
    print(f"{reason}; dropping cached AgentsKit build outputs")
    shutil.rmtree(BUILD / "out", ignore_errors=True)


def main() -> None:
    if not DATABASE.is_file():
        return

    current = current_metal_root()
    # Rule keys are recorded as bytes and are not all valid UTF-8, so the column is read
    # as bytes throughout rather than decoded and re-encoded around each pattern.
    with sqlite3.connect(DATABASE) as connection:
        connection.text_factory = bytes

        # A graph written by a different Xcode or SDK is not repairable. Its tasks
        # record the SDK they compiled against, and the objects it produced carry
        # autolink entries holding the absolute framework paths inside that SDK, so a
        # restored graph from an older image links against frameworks that are no
        # longer there. The cache key carries the toolchain too; this is the check for
        # when a key was matched anyway.
        #
        # A graph names several SDKs of one install — MacOSX27.0, and the versionless
        # MacOSX beside it — so the test is not that the names match one current
        # directory but that every name is still installed on this runner.
        toolchain = {
            "Xcode": (
                {match.group(1) for (key,) in connection.execute(
                    "SELECT key FROM key_names WHERE key LIKE '%/Applications/Xcode%'"
                ) for match in XCODE_APP.finditer(key)},
                current_xcode_app(),
            ),
            "macOS SDK": (
                {match.group(1) for (key,) in connection.execute(
                    "SELECT key FROM key_names WHERE key LIKE '%/SDKs/MacOSX%'"
                ) for match in MACOSX_SDK.finditer(key)},
                current_macosx_sdk(),
            ),
        }
        for name, (found, installed) in toolchain.items():
            if found and not found <= installed:
                missing = b", ".join(sorted(found - installed))
                drop_cached_outputs(f"Restored graph names a {name} this runner does not have ({missing.decode()})")
                return

        # Most rule keys are binary and are not valid UTF-8; restrict the query before
        # Python asks sqlite to match against the column.
        keys = connection.execute(
            "SELECT id, key FROM key_names WHERE key LIKE '%MobileAsset.MetalToolchain-%'"
        ).fetchall()
        roots = {match.group(0) for _, key in keys if (match := OLD_ROOT.search(key)) is not None}

        if not roots:
            return

        # The suffix after the component version is generated for each runner. The
        # component version itself must match before reusing any compiled products.
        versions = {Path(root.decode()).name.rsplit(".", 1)[0] for root in roots}
        current_version = Path(current.decode()).name.rsplit(".", 1)[0]
        same_layout = all(len(root) == len(current) for root in roots)
        if versions != {current_version} or not same_layout:
            drop_cached_outputs("Metal toolchain changed")
            return

        for key_id, key in keys:
            rewritten = key
            for root in roots:
                rewritten = rewritten.replace(root, current)
            if rewritten != key:
                connection.execute("UPDATE key_names SET key = ? WHERE id = ?", (rewritten, key_id))

    replacements = {root: current for root in roots if root != current}
    paths = list((BUILD / "out/Intermediates.noindex/XCBuildData").rglob("*"))
    paths.append(BUILD / "manifest.pif")
    for path in paths:
        if not path.is_file() or path == DATABASE:
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        rewritten = data
        for old, new in replacements.items():
            rewritten = rewritten.replace(old, new)
        if rewritten != data:
            path.write_bytes(rewritten)
    normalize_source_timestamps(BUILD.parent)
    print("Prepared the restored AgentsKit build graph for this runner")


if __name__ == "__main__":
    main()
