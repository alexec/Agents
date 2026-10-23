#!/usr/bin/env python3
"""Format jscpd's JSON report for lint output or the first baseline report."""

import argparse
import json
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
MODEL_FILES = {"AppModel.swift", "RemoteModel.swift", "AgentsModel.swift"}


def relative_name(file):
    path = Path(file["name"])
    if str(path).startswith("/src/"):
        return str(path).removeprefix("/src/")
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def location(file):
    return f"{relative_name(file)}:{file['startLoc']['line']}"


def is_model_pair(duplicate):
    names = {
        Path(relative_name(duplicate[key])).name
        for key in ("firstFile", "secondFile")
    }
    return bool(names & MODEL_FILES)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    duplicates = report["duplicates"]
    stats = report["statistics"]["total"]

    if not args.baseline:
        for duplicate in duplicates:
            first = duplicate["firstFile"]
            second = duplicate["secondFile"]
            lines = duplicate["lines"]
            print(f"{location(first)}: clone with {location(second)} ({lines} lines)")
            print(f"{location(second)}: clone with {location(first)} ({lines} lines)")
        return

    by_pair = defaultdict(list)
    for duplicate in duplicates:
        pair = tuple(sorted((relative_name(duplicate["firstFile"]), relative_name(duplicate["secondFile"]))))
        by_pair[pair].append(duplicate)

    output = [
        "# jscpd baseline report (2026-10-23)",
        "",
        "jscpd 5.4.2 scans Swift, Go and TypeScript with a minimum of 10 lines and 70 tokens.",
        "This report is informational. The linter does not fail CI for clones.",
        "",
        "## Summary",
        "",
        f"- Clones: {stats['clones']}",
        f"- Duplicated lines across both copies: {stats['duplicatedLines']}",
        f"- Files scanned: {stats['sources']}",
        "",
        "| Language | Clones | Duplicated lines | Files |",
        "|---|---:|---:|---:|",
    ]
    for language, values in sorted(report["statistics"]["formats"].items()):
        output.append(
            f"| {language} | {values['clones']} | {values['duplicatedLines']} | {values['sources']} |"
        )

    output.extend(["", "## AppModel, RemoteModel and AgentsModel pairs", ""])
    model_pairs = [(pair, clones) for pair, clones in by_pair.items() if any(Path(name).name in MODEL_FILES for name in pair)]
    if model_pairs:
        output.extend(["| Files | Clones | Duplicated lines |", "|---|---:|---:|"])
        for pair, clones in sorted(model_pairs):
            duplicated_lines = sum(clone["lines"] * 2 for clone in clones)
            output.append(f"| `{pair[0]}` ↔ `{pair[1]}` | {len(clones)} | {duplicated_lines} |")
        if not any("AgentsModel.swift" in pair for pair, _ in model_pairs):
            output.append("")
            output.append("No clone was found in AgentsModel.swift.")
    else:
        output.append("No clones involve AppModel.swift, RemoteModel.swift or AgentsModel.swift.")

    output.extend(["", "## Clones by pair of files", "", "| Files | Clones | Duplicated lines |", "|---|---:|---:|"])
    for pair, clones in sorted(by_pair.items(), key=lambda item: (-len(item[1]), item[0])):
        duplicated_lines = sum(clone["lines"] * 2 for clone in clones)
        output.append(f"| `{pair[0]}` ↔ `{pair[1]}` | {len(clones)} | {duplicated_lines} |")

    output.extend(["", "## Ten largest clones", "", "| Files and lines | Lines per copy | Lines across both copies |", "|---|---:|---:|"])
    for clone in sorted(duplicates, key=lambda item: (-item["lines"], location(item["firstFile"]), location(item["secondFile"])))[:10]:
        first, second = clone["firstFile"], clone["secondFile"]
        output.append(
            f"| `{location(first)}` ↔ `{location(second)}` | {clone['lines']} | {clone['lines'] * 2} |"
        )

    output.extend(["", "## Notes", "", "- `Packages/CodeText/Grammars`, `.specify`, `Web/dist`, `.build`, generated Go files, Go tests and `generated.ts` are excluded.", "- A clone can be correct for platform-specific clients. Review each pair before changing it.", ""])
    print("\n".join(output))


if __name__ == "__main__":
    main()
