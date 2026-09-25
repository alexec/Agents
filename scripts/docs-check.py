#!/usr/bin/env python3
"""The docs site's own check (044), for what the generator's strict build does not catch.

    python3 scripts/docs-check.py [--root <repo>]

Every page names its Diataxis section and sits in that section's folder; every page is in
the nav and every nav entry exists; every picture exists, is used, is small and has alt
text; nothing private (paths, names, addresses, tokens) is on a page; explanations have no
steps and tutorials say where next. Links between pages are left to the strict build.

One line per problem, `path:line: message`, then a summary. Exit 0 clean, 1 with problems,
2 if it could not run. Standard library only, Python 3.9+.
"""

import argparse
import os
import re
import sys

SECTIONS = {
    "tutorial": "tutorials",
    "how-to": "how-to",
    "reference": "reference",
    "explanation": "explanation",
}
KINDS = set(SECTIONS) | {"index"}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"}
IMAGE_LIMIT = 400 * 1024

PRIVATE = [
    (re.compile(r"/Users/"), "a home-directory path (/Users/…)"),
    (re.compile(r"/private/"), "a /private/ path"),
    (re.compile(r"/tmp/run-"), "a scratch-root path (/tmp/run-…)"),
    (re.compile(r"alexcollins", re.I), "a real user name"),
    (re.compile(r"\bghp_[A-Za-z0-9]"), "a GitHub token"),
    (re.compile(r"\bgithub_pat_"), "a GitHub token"),
    (re.compile(r"\bsk-ant-"), "an Anthropic key"),
    (re.compile(r"\bxox[abp]-"), "a Slack token"),
]
IPV4 = re.compile(r"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])")
IPV4_ALLOWED = {"127.0.0.1", "0.0.0.0"}

FENCE = re.compile(r"^\s*(```|~~~)")
MD_IMAGE = re.compile(r"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HTML_IMAGE = re.compile(r"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"'][^>]*>", re.I)
HTML_ALT = re.compile(r"\balt=[\"']([^\"']*)[\"']", re.I)
ORDERED = re.compile(r"^\s{0,3}\d+[.)]\s")
WHERE_NEXT = re.compile(r"^##\s+Where next\s*$", re.I)


class Problems:
    def __init__(self, root):
        self.root = root
        self.lines = []

    def add(self, path, line, message):
        self.lines.append((os.path.relpath(path, self.root), line, message))

    def __len__(self):
        return len(self.lines)

    def report(self):
        for path, line, message in sorted(self.lines):
            print(f"{path}:{line}: {message}")


def read_config(root):
    """docs_dir and the nav's page paths from mkdocs.yml, without a YAML library.

    Only what this check needs: `docs_dir:` at the top level, and every `something.md`
    named under the top-level `nav:` key, with the line it is on.
    """
    path = os.path.join(root, "mkdocs.yml")
    if not os.path.isfile(path):
        raise SystemExit(f"docs-check: no mkdocs.yml in {root}")
    docs_dir = "docs"
    nav = []
    in_nav = False
    with open(path, encoding="utf-8") as f:
        for number, raw in enumerate(f, 1):
            line = raw.split(" #", 1)[0].rstrip()
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            top = not raw[0].isspace()
            if top:
                in_nav = line.startswith("nav:")
                m = re.match(r"docs_dir:\s*['\"]?([^'\"]+)['\"]?\s*$", line)
                if m:
                    docs_dir = m.group(1)
                continue
            if in_nav:
                for page in re.findall(r"([\w./-]+\.md)\b", line):
                    nav.append((page, number))
    return os.path.join(root, docs_dir), path, nav


def front_matter(lines):
    """The key: value pairs between leading --- lines, with the line each is on."""
    if not lines or lines[0].strip() != "---":
        return {}, 0
    values = {}
    for number, line in enumerate(lines[1:], 2):
        if line.strip() == "---":
            return values, number
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*?)\s*$", line)
        if m:
            values[m.group(1)] = (m.group(2).strip("'\""), number)
    return {}, 0


def body_lines(lines, start):
    """(line number, text, in_code) for every line after the front matter."""
    in_code = False
    for number, line in enumerate(lines[start:], start + 1):
        if FENCE.match(line):
            in_code = not in_code
            yield number, line, True
            continue
        yield number, line, in_code


def check_private(problems, path, number, text):
    for pattern, what in PRIVATE:
        if pattern.search(text):
            problems.add(path, number, f"private: {what}")
    for m in IPV4.finditer(text):
        if m.group(0) not in IPV4_ALLOWED and all(int(g) <= 255 for g in m.groups()):
            problems.add(path, number, f"private: an IP address ({m.group(0)})")


def check_page(problems, docs, path, used_images):
    relative = os.path.relpath(path, docs).replace(os.sep, "/")
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()

    meta, end = front_matter(lines)
    kind = meta.get("diataxis", (None, 1))
    if kind[0] is None:
        problems.add(path, 1, "section-missing: no `diataxis:` in the front matter")
    elif kind[0] not in KINDS:
        problems.add(path, kind[1], f"section-unknown: `diataxis: {kind[0]}` is not one of "
                     + ", ".join(sorted(KINDS)))
    elif kind[0] == "index":
        parts = relative.split("/")
        allowed = relative == "index.md" or (
            len(parts) == 2 and parts[1] == "index.md" and parts[0] in SECTIONS.values())
        if not allowed:
            problems.add(path, kind[1], "section-folder: `index` is only for docs/index.md "
                         "and each section's index.md")
    else:
        folder = SECTIONS[kind[0]]
        if not relative.startswith(folder + "/"):
            problems.add(path, kind[1], f"section-folder: a {kind[0]} page belongs in "
                         f"docs/{folder}/")

    has_where_next = False
    for number, text, in_code in body_lines(lines, end):
        check_private(problems, path, number, text)
        if in_code:
            continue
        if kind[0] == "explanation" and ORDERED.match(text):
            problems.add(path, number, "shape-steps: explanation pages have no numbered steps")
        if WHERE_NEXT.match(text):
            has_where_next = True
        for alt, target in MD_IMAGE.findall(text):
            check_image(problems, path, number, target, alt, used_images)
        for tag in HTML_IMAGE.finditer(text):
            alt = HTML_ALT.search(tag.group(0))
            check_image(problems, path, number, tag.group(1), alt.group(1) if alt else "",
                        used_images)

    if kind[0] == "tutorial" and not has_where_next:
        problems.add(path, max(len(lines), 1), "shape-where-next: a tutorial ends with "
                     "`## Where next`")


def check_image(problems, page, number, target, alt, used_images):
    if re.match(r"^[a-z]+:", target) or target.startswith("#"):
        return
    target = target.split("#", 1)[0].split("?", 1)[0]
    image = os.path.normpath(os.path.join(os.path.dirname(page), target))
    if not alt.strip():
        problems.add(page, number, f"image-alt: {target} has no alt text")
    if not os.path.isfile(image):
        problems.add(page, number, f"image-missing: {target}: no such file")
        return
    used_images.add(image)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--root", default=os.path.join(os.path.dirname(__file__), ".."),
                        help="the repository (default: this script's)")
    args = parser.parse_args()
    root = os.path.abspath(args.root)

    try:
        docs, config, nav = read_config(root)
    except SystemExit as e:
        print(e, file=sys.stderr)
        return 2
    if not os.path.isdir(docs):
        print(f"docs-check: no docs folder at {docs}", file=sys.stderr)
        return 2

    problems = Problems(root)
    pages, images = [], []
    for directory, subdirectories, files in os.walk(docs):
        subdirectories.sort()
        for name in sorted(files):
            path = os.path.join(directory, name)
            if name.endswith(".md"):
                pages.append(path)
            elif os.path.basename(directory) == "images" and \
                    os.path.splitext(name)[1].lower() in IMAGE_SUFFIXES:
                images.append(path)

    seen = {}
    for page, number in nav:
        target = os.path.normpath(os.path.join(docs, page))
        if not os.path.isfile(target):
            problems.add(config, number, f"nav-dead: {page}: no such page")
        elif target in seen:
            problems.add(config, number, f"nav-twice: {page} is already in the nav "
                         f"(line {seen[target]})")
        else:
            seen[target] = number
    for page in pages:
        if page not in seen:
            problems.add(page, 1, "nav-missing: not in the nav of mkdocs.yml")

    used_images = set()
    for page in pages:
        check_page(problems, docs, page, used_images)

    for image in images:
        if image not in used_images:
            problems.add(image, 1, "image-unused: no page uses this picture")
        size = os.path.getsize(image)
        if size > IMAGE_LIMIT:
            problems.add(image, 1, f"image-large: {size // 1024} KB, over "
                         f"{IMAGE_LIMIT // 1024} KB")

    problems.report()
    if problems:
        print(f"docs-check: {len(problems)} problems in {len(pages)} pages")
        return 1
    print(f"docs-check: ok ({len(pages)} pages, {len(images)} pictures)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
