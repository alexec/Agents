#!/usr/bin/env python3
"""Make two shared docs pages from per-entry files, so two PRs edit different files (#5386).

  scripts/docs-parts.py gen        write the pages from docs-parts/
  scripts/docs-parts.py check      fail when a page is not what gen makes (lint runs this)
  scripts/docs-parts.py split      one-time: cut the pages into docs-parts/ (refuses to overwrite)
  scripts/docs-parts.py --selftest

A page is the files under docs-parts/<name>/, read in path order and joined. A `.part` file is
prose, verbatim (a section's heading, text and a table's header lines). A `.row` file is one
table row. Rows and parts sit in numbered files (`NNN-slug`), in a folder for each `##`
section, so a new integration or screen row is a new file and an edit to one is a one-file edit.
Never edit a page by hand: edit its parts and run `gen`. A conflict in a page is settled by
running `gen`.
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "docs-parts")
PAGES = {
    "integrations": "docs/reference/integrations.md",
    "parity": "specs/071-web-remote/walks/parity.md",
}
SEP = re.compile(r"^\|[\s:|-]+\|\s*$")


def render(name, src=SRC):
    out = []
    base = os.path.join(src, name)
    for dirpath, dirs, files in os.walk(base):
        dirs.sort()
        for f in sorted(files):
            with open(os.path.join(dirpath, f), encoding="utf-8") as fh:
                text = fh.read()
            if f.endswith(".row"):
                text = text.rstrip("\n") + "\n"
            elif not f.endswith(".part"):
                raise SystemExit(f"{dirpath}/{f}: only .part and .row files")
            out.append(text)
    return "".join(out)


def slug(text, words=6):
    s = re.sub(r"[^a-z0-9]+", "-", re.sub(r"[`*#]", "", text.lower())).strip("-")
    return "-".join(s.split("-")[:words]) or "x"


def chunks(lines):
    """Yield ("part", [lines]) and ("row", line), tables' data rows apart from the rest."""
    part, i = [], 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("|") and not SEP.match(line) and i + 1 < len(lines) and SEP.match(lines[i + 1]):
            part += [line, lines[i + 1]]
            i += 2
            while i < len(lines) and lines[i].startswith("|"):
                yield ("part", part)
                part = []
                yield ("row", lines[i])
                i += 1
            continue
        part.append(line)
        i += 1
    if part:
        yield ("part", part)


def split(name, dest=SRC):
    page = os.path.join(ROOT, PAGES[name])
    with open(page, encoding="utf-8") as f:
        lines = f.read().splitlines(keepends=True)
    # Sections: a new folder at each "## " heading outside a code fence.
    sections, cur, fence = [("intro", [])], None, False
    for line in lines:
        if line.startswith("```"):
            fence = not fence
        if line.startswith("## ") and not fence:
            sections.append((slug(line), []))
        sections[-1][1].append(line)
    base = os.path.join(dest, name)
    for n, (title, body) in enumerate(sections):
        d = os.path.join(base, f"{n * 10:03d}-{title}")
        os.makedirs(d)
        k = 0
        for kind, item in chunks(body):
            k += 10
            if kind == "part":
                with open(os.path.join(d, f"{k:04d}-text.part"), "w", encoding="utf-8") as f:
                    f.writelines(item)
            else:
                first = item.split("|")[1] if "|" in item[1:] else item
                with open(os.path.join(d, f"{k:04d}-{slug(first)}.row"), "w", encoding="utf-8") as f:
                    f.write(item)


def gen(check=False):
    bad = 0
    for name, path in PAGES.items():
        want = render(name)
        full = os.path.join(ROOT, path)
        have = open(full, encoding="utf-8").read() if os.path.exists(full) else None
        if have == want:
            continue
        if check:
            print(f"{path} is not what scripts/docs-parts.py makes from docs-parts/{name}/: "
                  f"edit the parts and run scripts/docs-parts.py gen", file=sys.stderr)
            bad = 1
        else:
            with open(full, "w", encoding="utf-8") as f:
                f.write(want)
            print(f"wrote {path}")
    return bad


def selftest():
    import tempfile
    text = "# T\n\n## A\n\nx\n\n| H | I |\n|---|---|\n| a | b |\n| c | d |\n\n## B\n\n```\n## no\n```\n"
    lines = text.splitlines(keepends=True)
    got = [(k, i) for k, i in chunks(lines)]
    assert [k for k, _ in got].count("row") == 2, got
    with tempfile.TemporaryDirectory() as tmp:
        global ROOT
        old, ROOT = ROOT, tmp
        PAGES["selftest"] = "p.md"
        try:
            open(os.path.join(tmp, "p.md"), "w").write(text)
            split("selftest", os.path.join(tmp, "parts"))
            assert render("selftest", os.path.join(tmp, "parts")) == text
        finally:
            ROOT = old
            del PAGES["selftest"]
    print("docs-parts selftest ok")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "--selftest":
        selftest()
    elif cmd == "gen":
        gen()
    elif cmd == "check":
        sys.exit(gen(check=True))
    elif cmd == "split":
        for name in PAGES:
            split(name)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
