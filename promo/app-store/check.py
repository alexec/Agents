#!/usr/bin/env python3
"""Checks listing.md against App Store Connect's limits (#1912).

    python3 promo/app-store/check.py

Each field is the ```text block under its heading. Keywords count in bytes, the rest in
characters. It also checks each screenshot's size against its folder.
"""
import re
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIMITS = {"Name": 30, "Subtitle": 30, "Promotional text": 170, "Keywords": 100, "Description": 4000}
SIZES = {"mac": {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)},
         "iphone": {(1320, 2868), (1290, 2796)},
         "ipad": {(2064, 2752), (2048, 2732)}}


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])


def main():
    text = (HERE / "listing.md").read_text()
    failed = False
    for field, limit in LIMITS.items():
        found = re.search(rf"^## {re.escape(field)} \(\d+\)\n\n```text\n(.*?)\n```", text, re.S | re.M)
        if not found:
            print(f"{field}: missing")
            failed = True
            continue
        value = found.group(1)
        size = len(value.encode()) if field == "Keywords" else len(value)
        if field == "Keywords" and (", " in value or len(set(value.split(","))) != len(value.split(","))):
            print("Keywords: no spaces after commas and no word twice")
            failed = True
        print(f"{field}: {size} of {limit}")
        failed |= size > limit
        if "—" in value:
            print(f"{field}: has an em dash")
            failed = True
    for folder, sizes in SIZES.items():
        for png in sorted((HERE / "screenshots" / folder).glob("*.png")):
            if png_size(png) not in sizes:
                print(f"{png.relative_to(HERE)}: {png_size(png)} is not an App Store size")
                failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
