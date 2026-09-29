#!/usr/bin/env python3
"""Repair only the per-run MetalToolchain mount path in a restored SwiftPM cache."""

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
SOURCE_EPOCH = 946684800  # 2000-01-01 UTC; exact-content cache key guards freshness.


def current_metal_root() -> str:
    metal = Path(subprocess.check_output(["xcrun", "--find", "metal"], text=True).strip()).resolve()
    return str(metal.parents[3])


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


def main() -> None:
    if not DATABASE.is_file():
        return

    current = current_metal_root()
    with sqlite3.connect(DATABASE) as connection:
        # Most rule keys are binary and are not valid UTF-8; restrict the query before
        # Python asks sqlite to decode the TEXT column.
        keys = connection.execute(
            "SELECT id, key FROM key_names WHERE key LIKE '%MobileAsset.MetalToolchain-%'"
        ).fetchall()
        roots = {
            match.group(0).decode()
            for _, key in keys
            if (match := OLD_ROOT.search(key.encode())) is not None
        }

        if not roots:
            return

        # The suffix after the component version is generated for each runner. The
        # component version itself must match before reusing any compiled products.
        versions = {Path(root).name.rsplit(".", 1)[0] for root in roots}
        current_version = Path(current).name.rsplit(".", 1)[0]
        same_layout = all(len(root) == len(current) for root in roots)
        if versions != {current_version} or not same_layout:
            print("Metal toolchain changed; dropping cached AgentsKit build outputs")
            shutil.rmtree(BUILD / "out", ignore_errors=True)
            return

        for key_id, key in keys:
            rewritten = key
            for root in roots:
                rewritten = rewritten.replace(root, current)
            if rewritten != key:
                connection.execute("UPDATE key_names SET key = ? WHERE id = ?", (rewritten, key_id))

    replacements = {root.encode(): current.encode() for root in roots if root != current}
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
