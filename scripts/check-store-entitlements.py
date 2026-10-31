#!/usr/bin/env python3
"""App/Agents-Store.entitlements holds only T044's list (#2498).

The list is scripts/check-store-archive.sh's `expected=( … )`, which the release checks the
archive against; this checks the source file against it, so a pull request fails on a new
entitlement before a release's archive does.
"""
import plistlib
import re
import sys

script = open("scripts/check-store-archive.sh").read()
expected = set(re.search(r"^expected=\(\n(.*?)\n\)", script, re.S | re.M).group(1).split())
path = sys.argv[1] if len(sys.argv) > 1 else "App/Agents-Store.entitlements"
with open(path, "rb") as f:
    bad = sorted(set(plistlib.load(f)) - expected)
for key in bad:
    print(f"BAD entitlement {key} in {path} (not in T044's list in scripts/check-store-archive.sh)")
if not bad:
    print(f"{path} holds only T044's entitlements.")
sys.exit(1 if bad else 0)
