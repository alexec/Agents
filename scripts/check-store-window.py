#!/usr/bin/env python3
"""The App Store window's sandbox gate (058, T044b).

Linking only AgentsKitCore stops a `Process` from compiling, but not a read of the disk
or Finder pointed at a path, and those fail quietly in the sandbox. This reads what the
AgentsStore target compiles (App/Sources and Shared/UI, less the files project.yml
excludes from it, less `#if !AGENTS_STORE` code) and fails on any line that reaches for
the disk, another process, or Finder on a path, unless the line says why it may with
`// store-ok: <reason>`.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent

def excluded():
    text = (root / "project.yml").read_text()
    block = text.split("  AgentsStore:", 1)[1].split("\n    dependencies:", 1)[0]
    first = block.split("      - path: App/Resources", 1)[0]
    return {"App/Sources/" + m.group(1).strip() for m in re.finditer(r"^\s+- (\S+\.swift)\s*$", first, re.M)}

PATTERNS = [
    (r"FileManager\.default\.(fileExists|contentsOfDirectory|createDirectory|removeItem|moveItem|copyItem|attributesOfItem|enumerator|homeDirectoryForCurrentUser)", "the disk"),
    (r"contentsOf(File)?:", "the disk"),
    (r"\.write\(to:", "the disk"),
    (r"NSWorkspace\.shared\.(activateFileViewerSelecting|open\(|icon\(forFile)", "Finder or an app on a path"),
    (r"\bdlsym\b|\bProcess\(\)|posix_spawn|\bFDTransport\b|connectUnixSocket", "another process"),
]

def compiled_lines(path):
    """The lines the store target compiles: a small #if reader for AGENTS_STORE only."""
    stack = []  # each: [this branch taken, any branch taken, known]
    for number, line in enumerate(path.read_text().splitlines(), 1):
        s = line.strip()
        if s.startswith("#if "):
            cond = s[4:].strip()
            known = cond in ("AGENTS_STORE", "!AGENTS_STORE")
            taken = (cond == "AGENTS_STORE") if known else True
            stack.append([taken, taken, known])
            continue
        if s.startswith("#elseif") and stack:
            top = stack[-1]
            if top[2]:
                top[0] = False
            continue
        if s == "#else" and stack:
            top = stack[-1]
            if top[2]:
                top[0] = not top[1]
                top[1] = True
            continue
        if s == "#endif" and stack:
            stack.pop()
            continue
        if all(frame[0] for frame in stack):
            yield number, line

def main():
    skip = excluded()
    problems = []
    for folder in ("App/Sources", "Shared/UI"):
        for path in sorted((root / folder).rglob("*.swift")):
            relative = str(path.relative_to(root))
            if relative in skip:
                continue
            for number, line in compiled_lines(path):
                code = line.split("//", 1)[0] if "store-ok:" not in line else ""
                for pattern, what in PATTERNS:
                    if re.search(pattern, code):
                        problems.append(f"{relative}:{number}: reaches {what}: {line.strip()}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} line(s) the sandbox would refuse. Send them to a host, fence them with "
              "#if !AGENTS_STORE, or say why with // store-ok: <reason>.", file=sys.stderr)
        return 1
    print("The App Store window reaches for no disk, process or Finder path it may not.")
    return 0

sys.exit(main())
