#!/usr/bin/env python3
"""No accessibility label stacked on a selectable Text (#71, #222, #1724).

Under `.textSelection(.enabled)` a SwiftUI `Text` on the Mac is drawn by an AppKit text
view. A `.accessibilityLabel` on that Text, or on an element that `.combine`s it, makes
SwiftUI's node and the AppKit view ask each other for the label until the stack runs out:
the window dies (EXC_BAD_ACCESS) on the first accessibility query, from VoiceOver or a walk.
Give the row one element of its own instead: `.accessibilityElement(children: .ignore)`
before the label.

This reads App/Sources and Shared/UI. In a file that turns on text selection, it fails on
a `.accessibilityLabel` whose modifier chain starts at `Text(`, or holds
`.accessibilityElement(children: .combine)`, and has no `.accessibilityElement(children:
.ignore)`. A line that is safe for a reason this cannot see says so with
`// stacked-label: <why>` on the label's line.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent

LABEL = re.compile(r"^\s*\.accessibilityLabel\(")
IGNORE = re.compile(r"\.accessibilityElement\(children:\s*\.ignore\)")
COMBINE = re.compile(r"\.accessibilityElement\(children:\s*\.combine\)")
SELECTION = re.compile(r"\.textSelection\(\.enabled\)")


def chain(lines, at):
    """The label's modifier chain, from its head line down to the label: every line above
    it that starts with a `.` (or is a comment) belongs to it, and the first that does
    not is the head."""
    start = at
    while start > 0:
        above = lines[start - 1].strip()
        if above.startswith(".") or above.startswith("//") or not above:
            start -= 1
            continue
        start -= 1
        break
    return lines[start:at + 1]


def problems_in(text):
    lines = text.splitlines()
    if not any(SELECTION.search(line.split("//", 1)[0]) for line in lines):
        return []
    found = []
    for number, line in enumerate(lines):
        if not LABEL.search(line) or "stacked-label:" in line:
            continue
        links = [link.split("//", 1)[0] for link in chain(lines, number)]
        if any(IGNORE.search(link) for link in links):
            continue
        head = links[0].strip()
        if head.startswith("Text(") or any(COMBINE.search(link) for link in links):
            found.append(number + 1)
    return found


SELFTEST = [
    # A selectable Text with its own label: the #71 and #1724 crash.
    ("""VStack {
    Text("⋯")
        .padding(2)
        .accessibilityLabel("Lines not in the change")
}
.textSelection(.enabled)
""", [4]),
    # One element, children ignored: safe.
    ("""Text("⋯")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Lines not in the change")
    .textSelection(.enabled)
""", []),
    # Combined over selectable children, with a label on top.
    ("""HStack {
    Text(a)
    Text(b)
}
.accessibilityElement(children: .combine)
.accessibilityLabel("a b")
.textSelection(.enabled)
""", [6]),
    # No selection in the file: nothing to say.
    ("""Text("x")
    .accessibilityLabel("y")
""", []),
    # An image, a button: not a Text.
    ("""Image(systemName: "square")
    .accessibilityLabel("Not done")
Text("z").textSelection(.enabled)
""", []),
    # Said safe, with why.
    ("""Text("x")
    .accessibilityLabel("y") // stacked-label: never under textSelection
Text("z").textSelection(.enabled)
""", []),
]


def selftest():
    failed = 0
    for text, want in SELFTEST:
        got = problems_in(text)
        if got != want:
            failed += 1
            print(f"check-stacked-labels selftest: want {want}, got {got} for:\n{text}", file=sys.stderr)
    return 1 if failed else 0


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    problems = []
    for folder in ("App/Sources", "Shared/UI"):
        for path in sorted((root / folder).rglob("*.swift")):
            text = path.read_text()
            lines = text.splitlines()
            relative = str(path.relative_to(root))
            for number in problems_in(text):
                problems.append(f"{relative}:{number}: {lines[number - 1].strip()}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} accessibility label(s) on a selectable Text, or on an element that "
              "combines one: the window overflows its stack on the first accessibility query (#1724). "
              "Put .accessibilityElement(children: .ignore) before the label.", file=sys.stderr)
        return 1
    print("No accessibility label is stacked on a selectable Text.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
