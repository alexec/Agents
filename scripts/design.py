#!/usr/bin/env python3
"""The design system's CSS token files, written from design/tokens.json (#4602).

    python3 scripts/design.py gen        write every output below
    python3 scripts/design.py check      write nothing; fail when an output is not what
                                         design/tokens.json makes
    python3 scripts/design.py --selftest

Each output is the same tokens as CSS custom properties, with the dark values where its
surface looks for them:

    Web/src/theme/tokens.css        the web page; paper.css imports it
    www/tokens.css                  agentloops.dev
    docs/stylesheets/tokens.css     the docs site (Material's slate scheme is the dark)
    Go/internal/forgepages/tokens.css   the forge connector pages, as light-dark() pairs

Our own code rather than Style Dictionary: every output needs a format of its own (the
web page's must stay byte-equal to what paper.css held, the docs' dark follows Material's
scheme attribute), so a library would only read the JSON, and it would bring a Node
package tree into a text check that runs in CI's lint.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design" / "tokens.json"
DARK = "dev.agentloops.dark"
ALPHA = "dev.agentloops.alpha"
HEADER = "/* Made by scripts/design.sh gen from design/tokens.json (#4602). Do not edit: change the\n   JSON and run gen again. */\n"


def tokens(tree, path=()):
    """Every token in the tree, in its order, as (path, token, $type)."""
    found = []
    kind = tree.get("$type")
    for key, value in tree.items():
        if key.startswith("$") or not isinstance(value, dict):
            continue
        if "$value" in value:
            found.append((path + (key,), value, value.get("$type", kind)))
        else:
            for sub_path, token, sub_kind in tokens(value, path + (key,)):
                found.append((sub_path, token, sub_kind or value.get("$type") or kind))
    return found


def name(path):
    """A token's custom property: colours are --paper-*, but for the accent, the tints and
    the labels, which keep the names the web page has always used."""
    head, rest = path[0], path[1:]
    if head == "color":
        if rest[0] in ("tint", "label"):
            return "--" + "-".join(rest)
        if rest == ("accent",):
            return "--accent"
        return "--paper-" + "-".join(rest)
    return "--" + "-".join(path)


def colour(hex_value, alpha=None):
    if alpha is None:
        return hex_value
    r, g, b = (int(hex_value[i:i + 2], 16) for i in (1, 3, 5))
    return f"rgb({r} {g} {b} / {round(alpha * 100)}%)"


def css(token, kind, dark=False):
    """The token's value as CSS, or None when it has no dark value of its own."""
    value = token["$value"]
    extensions = token.get("$extensions", {})
    if kind == "color":
        if dark:
            if DARK not in extensions:
                return None
            value = extensions[DARK]
        return colour(value, extensions.get(ALPHA))
    if dark:
        return None
    if kind == "fontFamily":
        return ", ".join(f'"{f}"' if " " in f else f for f in value)
    if isinstance(value, dict):
        number = value["value"]
        return f"{number:g}{value['unit']}"
    return str(value)


def comment(token, indent):
    text = token.get("$description")
    return f"{indent}/* {text} */\n" if text else ""


# What each output holds: the groups, and how the dark is written.
OUTPUTS = {
    # Byte-equal to the :root blocks paper.css held before #4602 once esbuild minifies it, so
    # the web page does not change: its groups, and the two lines it always had.
    "Web/src/theme/tokens.css": {"groups": ("color", "radius", "font"), "dark": "media", "web": True},
    "www/tokens.css": {"groups": ("color", "radius", "font", "type"), "dark": "media"},
    "docs/stylesheets/tokens.css": {"groups": ("color", "radius", "font", "type"), "dark": "material"},
    "Go/internal/forgepages/tokens.css": {"groups": ("color", "radius", "font", "type"), "dark": "light-dark"},
}


def render(source, spec):
    chosen = [t for t in tokens(source) if t[0][0] in spec["groups"]]
    out = [HEADER, "\n"]
    light_selector = ':root, [data-md-color-scheme="default"]' if spec["dark"] == "material" else ":root"
    out.append(light_selector + " {\n  color-scheme: light dark;\n")
    for path, token, kind in chosen:
        value = css(token, kind)
        if spec["dark"] == "light-dark":
            dark = css(token, kind, dark=True)
            if dark is not None:
                value = f"light-dark({value}, {dark})"
        out.append(comment(token, "  "))
        out.append(f"  {name(path)}: {value};\n")
        if spec.get("web") and name(path) == "--accent":
            out.append("  accent-color: var(--accent);\n")
    out.append("}\n")
    darks = [(path, css(token, kind, dark=True)) for path, token, kind in chosen]
    darks = [(path, value) for path, value in darks if value is not None]
    if spec["dark"] == "media":
        out.append("\n@media (prefers-color-scheme: dark) {\n  :root {\n")
        out += [f"    {name(path)}: {value};\n" for path, value in darks]
        out.append("  }\n}\n")
    elif spec["dark"] == "material":
        out.append('\n[data-md-color-scheme="slate"] {\n')
        out += [f"  {name(path)}: {value};\n" for path, value in darks]
        out.append("}\n")
    return "".join(out)


def outputs():
    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    return {path: render(source, spec) for path, spec in OUTPUTS.items()}


def selftest():
    source = {
        "color": {"$type": "color",
                  "ground": {"$value": "#ffffff", "$extensions": {DARK: "#000000"}},
                  "shadow": {"$value": "#20242a", "$extensions": {DARK: "#000000", ALPHA: 0.1}},
                  "tint": {"failure": {"$value": "#b4232b", "$extensions": {DARK: "#f08086"}}}},
        "radius": {"$type": "dimension", "card": {"$value": {"value": 10, "unit": "px"}}},
        "font": {"$type": "fontFamily", "mono": {"$value": ["ui-monospace", "SF Mono"]}},
    }
    web = render(source, OUTPUTS["Web/src/theme/tokens.css"])
    for want in ("--paper-ground: #ffffff;", "--paper-shadow: rgb(32 36 42 / 10%);",
                 "--tint-failure: #f08086;", "--radius-card: 10px;", '--font-mono: ui-monospace, "SF Mono";',
                 "@media (prefers-color-scheme: dark)"):
        assert want in web, (want, web)
    assert "--radius-card" not in web.split("@media")[1], web
    pairs = render(source, OUTPUTS["Go/internal/forgepages/tokens.css"])
    assert "--paper-ground: light-dark(#ffffff, #000000);" in pairs, pairs
    assert "@media" not in pairs, pairs
    docs = render(source, OUTPUTS["docs/stylesheets/tokens.css"])
    assert '[data-md-color-scheme="slate"] {\n  --paper-ground: #000000;' in docs, docs
    print("design.py: selftest passed")


def main(argv):
    command = argv[1] if len(argv) > 1 else ""
    if command == "--selftest":
        selftest()
        return 0
    if command not in ("gen", "check"):
        print("usage: scripts/design.sh gen | check", file=sys.stderr)
        return 2
    stale = []
    for path, text in outputs().items():
        target = ROOT / path
        current = target.read_text(encoding="utf-8") if target.exists() else None
        if current == text:
            continue
        if command == "gen":
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
            print(f"design.sh: wrote {path}")
        else:
            stale.append(path)
    if stale:
        for path in stale:
            print(f"design.sh: {path} is not what design/tokens.json makes; run scripts/design.sh gen "
                  "and commit it", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
