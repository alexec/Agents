#!/usr/bin/env python3
"""No colour is named outside a token file (#4609, epic #4600; specs/4600-design-system/spec.md).

The colours come from `design/tokens.json`, through the `tokens.css` files that
`scripts/design.sh gen` writes. This fails on a colour named anywhere else in the web page
(`Web/src`), www (`www`), the docs site's styles (`docs/stylesheets`), the forge pages
(`Go/internal/forgepages`), the small pages Agents serves (`Go/internal/paperpage`) and the
hosted sign-in pages (`deploy/site/www/oauth`):

- in CSS, SVG and HTML: a hex colour (`#abc`, `#aabbcc`, with or without alpha), `rgb(`,
  `rgba(`, `hsl(` or `hsla(`, outside a comment;
- in TS, JS and Go: a hex colour in a string (`"#fff"`, `fill="#fff"`), or one of those
  functions, outside a comment.

`design/colour-allowlist.txt` lists the few that stay, one per line: the path, the colour as
found (`#CFE3FF`, `rgb(`) or `*` for the whole file, and why. An entry that matches nothing
fails too, so the list only gets shorter. `ConsistencyTests` does the same for Swift.

`--selftest` checks the check.
"""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = "design/colour-allowlist.txt"
PLACES = [
    "Web/src",
    "www",
    "docs/stylesheets",
    "Go/internal/forgepages",
    "Go/internal/paperpage",
    "deploy/site/www/oauth",
]
# Written by scripts/design.sh gen from design/tokens.json; the wire's generated types name no colour.
GENERATED = ("tokens.css", "Web/src/protocol/generated.ts")
MARKUP = {"css", "svg", "html"}
CODE = {"ts", "tsx", "js", "mjs", "go"}

HEX = r"#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![0-9a-zA-Z_-])"
FUNCTION = r"\b(?:rgba?|hsla?)\("
IN_MARKUP = re.compile(f"{HEX}|{FUNCTION}")
# In code, a hex is a colour when it is a whole string ("#fff") or a CSS value (`color: #fff;`):
# "#4600 is open" is an issue.
IN_CODE = re.compile(rf"""(?:(?<=["'`])|(?<=: )){HEX}(?=["'`;])|{FUNCTION}""")


def blank(m):
    """The match as spaces, its newlines kept, so line numbers stay true."""
    return re.sub(r"[^\n]", " ", m.group(0))


def without_comments(ext, text):
    if ext in ("svg", "html"):
        text = re.sub(r"<!--.*?-->", blank, text, flags=re.S)
    if ext != "svg":
        text = re.sub(r"/\*.*?\*/", blank, text, flags=re.S)
    if ext in CODE:
        # A line comment, but not the // of a URL in a string.
        text = re.sub(r"(?<![:\"'])//[^\n]*", blank, text)
    return text


def found(path, text):
    """The (line, colour) of each colour named in a file at `path`."""
    ext = path.rsplit(".", 1)[-1]
    if ext not in MARKUP | CODE or path.endswith(GENERATED):
        return []
    pattern = IN_MARKUP if ext in MARKUP else IN_CODE
    out = []
    for i, line in enumerate(without_comments(ext, text).splitlines(), 1):
        for m in pattern.finditer(line):
            out.append((i, m.group(0)))
    return out


def parse_allowlist(text):
    """{(path, colour): reason}, and the problems with the list itself."""
    allowed, problems = {}, []
    for i, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("//"):
            continue
        parts = line.split(None, 2)
        if len(parts) < 3:
            problems.append(f"{ALLOWLIST}:{i}: wants a path, a colour and why")
            continue
        allowed[(parts[0], parts[1])] = parts[2]
    return allowed, problems


def problems(files, allowlist):
    """files: {path: text}. The findings as `path:line: …`, the allowlist's own last."""
    allowed, out = parse_allowlist(allowlist)
    used = set()
    for path in sorted(files):
        for line, colour in found(path, files[path]):
            for key in ((path, colour), (path, "*")):
                if key in allowed:
                    used.add(key)
                    break
            else:
                out.append(
                    f"{path}:{line}: {colour} names a colour: use a token from design/tokens.json "
                    f"(var(--…)), or add it to {ALLOWLIST} with why (#4609)"
                )
    for key in sorted(set(allowed) - used):
        out.append(f"{ALLOWLIST}:1: {key[0]} {key[1]} matches nothing: remove it")
    return out


def tracked():
    names = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", *PLACES],
        cwd=root, capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    files = {}
    for name in names:
        p = root / name
        if name and p.is_file() and name.rsplit(".", 1)[-1] in MARKUP | CODE:
            files[name] = p.read_text(errors="replace")
    return files


def selftest():
    css = "/* #4600: a ref, not a colour */\n.a { color: var(--paper-ink); }\n"
    assert problems({"Web/src/app.css": css}, "") == []
    bad = problems({"Web/src/app.css": css + ".b { color: #123456; }\n"}, "")
    assert len(bad) == 1 and bad[0].startswith("Web/src/app.css:3: #123456"), bad
    assert len(problems({"www/a.css": ".a { background: rgba(0 0 0 / 0.5); }"}, "")) == 1
    assert len(problems({"www/a.css": ".a { color: hsl(var(--hue) 55% 45%); }"}, "")) == 1
    assert problems({"Web/src/theme/tokens.css": ":root { --x: #fff; }"}, "") == []
    ts = '// #fff in a comment\nconst issue = "#4600 is a ref"; const url = "https://x//y";\n'
    assert problems({"Web/src/a.ts": ts}, "") == []
    assert len(problems({"Web/src/a.tsx": '<path fill="#0E1A3A" />'}, "")) == 1
    assert len(problems({"Web/src/a.ts": "ctx.fillStyle = '#abc';"}, "")) == 1
    assert len(problems({"Web/src/a.ts": "const css = `.a { color: #fff; }`;"}, "")) == 1
    assert len(problems({"Web/src/a.ts": "return `rgb(${r} ${g} ${b})`;"}, "")) == 1
    assert len(problems({"Go/internal/forgepages/a.go": 'const c = "#fff"'}, "")) == 1
    assert problems({"www/a.html": '<!-- #fff --><a href="#top">'}, "") == []
    allow = "// why each\nWeb/src/a.tsx #0E1A3A the Blob's own ink\nwww/icon.svg * a mark\n"
    files = {"Web/src/a.tsx": '<path fill="#0E1A3A" />', "www/icon.svg": '<svg fill="#fff"/>'}
    assert problems(files, allow) == [], problems(files, allow)
    stale = problems({"Web/src/a.tsx": ""}, "Web/src/a.tsx #0E1A3A gone")
    assert len(stale) == 1 and "matches nothing" in stale[0], stale
    assert len(problems({}, "Web/src/a.tsx #fff")) == 1  # no reason
    print("check-colour-tokens: selftest passed")


def main():
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    allow = root / ALLOWLIST
    out = problems(tracked(), allow.read_text() if allow.exists() else "")
    for line in out:
        print(line)
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
