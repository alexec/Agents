#!/usr/bin/env python3
"""The App Store window's sandbox gate (058, T044b).

Linking only AgentsKitCore stops a `Process` from compiling, but not a read of the disk
or Finder pointed at a path, and those fail quietly in the sandbox. This reads what the
AgentsStore target compiles (App/Sources and Shared/UI) and fails on any line that
reaches for the disk, another process, or Finder on a path, unless the line says why it
may with `// store-ok: <reason>`.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent

PATTERNS = [
    (r"FileManager\.default\.(fileExists|contentsOfDirectory|createDirectory|removeItem|moveItem|copyItem|attributesOfItem|enumerator|homeDirectoryForCurrentUser)", "the disk"),
    (r"contentsOf(File)?:", "the disk"),
    (r"\.write\(to:", "the disk"),
    (r"NSWorkspace\.shared\.(activateFileViewerSelecting|open\(|icon\(forFile)", "Finder or an app on a path"),
    (r"\bdlsym\b|\bProcess\(\)|posix_spawn|\bFDTransport\b|connectUnixSocket", "another process"),
]

def main():
    problems = []
    for folder in ("App/Sources", "Shared/UI"):
        for path in sorted((root / folder).rglob("*.swift")):
            relative = str(path.relative_to(root))
            for number, line in enumerate(path.read_text().splitlines(), 1):
                code = line.split("//", 1)[0] if "store-ok:" not in line else ""
                for pattern, what in PATTERNS:
                    if re.search(pattern, code):
                        problems.append(f"{relative}:{number}: reaches {what}: {line.strip()}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} line(s) the sandbox would refuse. Send them to a host, "
              "or say why with // store-ok: <reason>.", file=sys.stderr)
        return 1
    print("The App Store window reaches for no disk, process or Finder path it may not.")
    return 0

sys.exit(main())
