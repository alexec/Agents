#!/usr/bin/env python3
"""Every window preference goes through `WindowDefaults` (#1029).

Every copy of the Mac window shares one bundle id, so one defaults domain: a key written
to `UserDefaults.standard` by a scratch copy (run-app, a branch build) lands in the
person's own window. This reads App/Sources and Shared/UI and fails on an `@AppStorage`
without `store: WindowDefaults.store`, and on `UserDefaults.standard` or `= .standard`,
outside `WindowDefaults.swift` itself.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent

PATTERNS = [
    (re.compile(r"@AppStorage\((?![^)]*store:\s*WindowDefaults\.store)"), "an @AppStorage without store: WindowDefaults.store"),
    (re.compile(r"UserDefaults\.standard|UserDefaults\s*=\s*\.standard"), "the shared defaults domain"),
]


def main():
    problems = []
    for folder in ("App/Sources", "Shared/UI"):
        for path in sorted((root / folder).rglob("*.swift")):
            if path.name == "WindowDefaults.swift":
                continue
            relative = str(path.relative_to(root))
            for number, line in enumerate(path.read_text().splitlines(), 1):
                code = line.split("//", 1)[0]
                for pattern, what in PATTERNS:
                    if pattern.search(code):
                        problems.append(f"{relative}:{number}: {what}: {line.strip()}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} line(s) would write the person's window's defaults from a scratch copy. "
              "Use WindowDefaults.store.", file=sys.stderr)
        return 1
    print("Every window preference goes through WindowDefaults.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
