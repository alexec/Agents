#!/usr/bin/env python3
"""The capabilities a release adds, deprecates and removes (#1748, docs/explanation/versions.md).

    capability-changes.py <last tag> <sha>     Markdown for the notes' ## Capabilities, or nothing
    capability-changes.py --selftest

A capability is what x-capability on a method, or x-declared-capabilities, names in
Packages/Wire/*.openrpc.json; a deprecated one is listed in a document's
x-deprecated-capabilities. A document missing at a revision counts as naming none.
"""
import json
import subprocess
import sys

DOCUMENTS = ["Packages/Wire/daemon.openrpc.json", "Packages/Wire/control.openrpc.json"]


def named(document):
    """The capabilities one document names, and the ones it deprecates."""
    names = {m["x-capability"] for m in document.get("methods", []) if "x-capability" in m}
    names |= {d["name"] for d in document.get("x-declared-capabilities", [])}
    return names, set(document.get("x-deprecated-capabilities", []))


def at(revision):
    names, deprecated = set(), set()
    for path in DOCUMENTS:
        shown = subprocess.run(["git", "show", f"{revision}:{path}"], capture_output=True, text=True)
        if shown.returncode != 0:
            continue
        n, d = named(json.loads(shown.stdout))
        names |= n
        deprecated |= d
    return names, deprecated


def changes(before, after):
    (old, old_deprecated), (new, new_deprecated) = before, after
    if not old and new:
        # The first release with capabilities: every method has one now.
        return ("## Capabilities\n\n- Each part now says what it can do, and a client shows only what a host has. "
                "A host or an app from before this release works as before (#1748).")
    lines = []
    for title, which in (("Added", new - old), ("Deprecated", new_deprecated - old_deprecated), ("Removed", old - new)):
        if which:
            lines.append(f"- {title}: " + ", ".join(f"`{c}`" for c in sorted(which)) + ".")
    return "\n".join(["## Capabilities", "", *lines]) if lines else ""


def selftest():
    one = {"methods": [{"name": "a/x", "x-capability": "a/1"}, {"name": "f/x", "x-capability": "files/1"}]}
    two = {"methods": [{"name": "a/x", "x-capability": "a/1"}, {"name": "b/x", "x-capability": "chat.branch/1"},
                       {"name": "f/x", "x-capability": "files/1"}],
           "x-declared-capabilities": [{"name": "host.wire/1", "by": "host"}], "x-deprecated-capabilities": ["files/1"]}
    three = {"methods": [{"name": "a/x", "x-capability": "a/1"}]}
    assert changes(named(one), named(one)) == ""
    assert changes(named({}), named(one)).startswith("## Capabilities\n\n- Each part now says")
    assert changes(named(one), named(two)) == ("## Capabilities\n\n- Added: `chat.branch/1`, `host.wire/1`.\n"
                                               "- Deprecated: `files/1`."), changes(named(one), named(two))
    assert changes(named(two), named(three)) == ("## Capabilities\n\n- Removed: `chat.branch/1`, `files/1`, "
                                                 "`host.wire/1`."), changes(named(two), named(three))
    print("capability-changes selftest: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    elif len(sys.argv) == 3:
        out = changes(at(sys.argv[1]), at(sys.argv[2]))
        if out:
            print(out)
    else:
        sys.exit(__doc__)
