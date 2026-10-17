#!/usr/bin/env python3
"""Find tests that index or force-unwrap after a check that does not stop them (#94).

  scripts/check-test-indexing.py [--selftest] [FILE ...]

`#expect` records a failure and carries on, and so does `eventually`, which gives up
quietly. A test that then reads `xs[1]`, `xs.first!` or `x!` traps when the check has
failed, and a trap ends the whole `swift test` run, not just the one test: every test
after it goes unrun and unreported. `try #require(...)` stops the test instead.

With no files it scans the tests of AgentsKit, ControlPlane and CodeText. Within each
function, once an `#expect` or `eventually` has been seen, it flags:

  - a subscript by an integer literal, `xs[1]`, `a.b[0][2]`;
  - `.first!` and `.last!`;
  - a force unwrap, `x!`, `f()!`, of something an earlier `#expect` or `eventually`
    named, as in `#expect(x != nil)` then `x!`.

A subscript or unwrap is allowed when an earlier `#require`, `guard` or `if` in the same
function names what is indexed or unwrapped, as in `try #require(xs.count == 2)` then
`xs[1]`. A line that is safe for a reason this cannot see says so with `// index-ok:`
and the reason; on the line that declares a value, `let all = try await copies(2)  //
index-ok: one per copy or it throws`, it covers that value for the rest of the function.
It exits 1 and lists each site if it finds any.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = ["AgentsKit", "ControlPlane", "CodeText"]

ARMS = re.compile(r"#expect\b|\beventually\w*\s*[({]")
GUARDS = re.compile(r"#require\b|^\s*guard\b|^\s*(\}\s*else\s+)?if\b")
FUNC = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|static|override|mutating|nonisolated)\s+)*func\s")
# The thing being subscripted: a dotted chain, maybe ending in a call or another subscript.
RECEIVER = r"([A-Za-z_][\w.]*(?:\(\))?(?:\[[^\]]*\])*)"
LITERAL_INDEX = re.compile(r"\[(\d+)\]")
FIRST_LAST = re.compile(RECEIVER + r"\.(?:first|last)!")
UNWRAP = re.compile(r"([A-Za-z_][\w.]*(?:\([^()]*\))?(?:\[[^\]]*\])*)!(?!=)")
NOT_UNWRAP = {"try", "as"}


def code_of(line):
    """The line without string literals or a trailing comment."""
    out, i, in_string = [], 0, False
    while i < len(line):
        c = line[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
                out.append('"')
        elif c == '"':
            in_string = True
            out.append('"')
        elif line.startswith("//", i):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def base_name(receiver):
    """`a.b[0]` -> `a.b`, `f()` -> `f`: what a guard has to mention."""
    return re.sub(r"(\(\)|\[[^\]]*\])+$", "", receiver)


def mentioned(name, lines):
    return any(re.search(r"(?<![\w.])" + re.escape(name) + r"(?!\w)", line) for line in lines)


def sites(text):
    found = []
    armed = False
    guarded = []  # code of each guarding line so far in this function
    checked = []  # code of each #expect or eventually line so far
    depth = None  # indentation of the function being read; one nested in it carries on
    for number, raw in enumerate(text.splitlines(), 1):
        indent = len(raw) - len(raw.lstrip())
        if FUNC.match(raw) and (depth is None or indent <= depth):
            armed, guarded, checked, depth = False, [], [], indent
        elif depth is not None and raw.strip() == "}" and indent <= depth:
            armed, guarded, checked, depth = False, [], [], None  # the function ended
        code = code_of(raw)
        if "index-ok:" in raw:
            guarded.extend((n, n) for n in re.findall(r"\b(?:let|var)\s+(\w+)", code))
        elif armed:
            for kind, match in risky(code):
                name = base_name(match)
                if kind == "unwrap" and not mentioned(name, checked):
                    continue
                if not mentioned(name, [raw_g if "[" in name else bare for raw_g, bare in guarded]):
                    found.append((number, kind, raw.strip()))
                    break
        if GUARDS.search(code):
            # Less what it indexes, for a plain name: `guard case .a = xs[0]` does not
            # guard `xs`, though `#require(xs[0].ys.count > 1)` guards `xs[0].ys`.
            guarded.append((code, without_subscripts(code)))
        if ARMS.search(code):
            armed = True
            checked.append(code)
    return found


def receiver_before(code, end):
    """The expression a subscript at `end` applies to: `hunks[0].lines` in
    `hunks[0].lines[2]`, walking back over names, dots, calls and subscripts."""
    i, depth = end, 0
    while i > 0:
        c = code[i - 1]
        if c in ")]":
            depth += 1
        elif c in "([":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and not (c.isalnum() or c in "_."):
            break
        i -= 1
    return code[i:end].lstrip(".")


def without_subscripts(code):
    for m in reversed(list(LITERAL_INDEX.finditer(code))):
        start = m.start() - len(receiver_before(code, m.start()))
        code = code[:start] + code[m.end():]
    return code


def risky(code):
    for m in LITERAL_INDEX.finditer(code):
        receiver = receiver_before(code, m.start())
        if receiver[:1].isalpha() or receiver[:1] == "_":  # not an array literal, `[1, 2][0]`
            yield "index", receiver
    for m in FIRST_LAST.finditer(code):
        yield "first/last!", m.group(1)
    for m in UNWRAP.finditer(code):
        receiver = m.group(1)
        if receiver in NOT_UNWRAP or receiver.endswith((".first", ".last")):
            continue
        if re.match(r"[A-Z]\w*\(", receiver):  # URL(string: "…")!: made from a literal, not checked
            continue
        yield "unwrap", receiver


def files():
    for package in PACKAGES:
        yield from sorted((ROOT / "Packages" / package / "Tests").rglob("*.swift"))


SELFTEST = [
    ("#expect(xs.count == 2)\n#expect(xs[1] == 3)", 1),
    ("#expect(xs.count == 2)\nlet a = xs.first!", 1),
    ("#expect(x != nil)\n#expect(x!.name == \"a\")", 1),
    ("await eventually { xs.count == 1 }\nlet y = xs[0]", 1),
    ("let y = xs[0]\n#expect(y == 1)", 0),
    ("#expect(a == 1)\nlet xs = try #require(ys)\n#expect(ys[0] == 1)", 0),
    ("try #require(xs.count == 2)\n#expect(xs[0] == 1)\n#expect(xs[1] == 2)", 0),
    ("#expect(a == 1)\nguard xs.count > 1 else { return }\n#expect(xs[1] == 2)", 0),
    ("#expect(a != b)\n#expect(\"x[0]!\" == s)", 0),
    ("#expect(a == 1)\nlet b = try! f()\nlet c = d as! E", 0),
    ("#expect(a == 1)\nlet u = URL(string: \"https://a\")!", 0),
    ("#expect(next != nil)\n#expect(next! > now)", 1),
    ("#expect(a == 1)\nlet b = xs[0] // index-ok: a literal of three", 0),
    ("let all = f(2) // index-ok: two\n#expect(a == 1)\n#expect(all[1] == b)", 0),
    ("#expect(a == 1)\ntry #require(hs.count == 1)\n#expect(hs[0].ls[2] == x)", 1),
    ("#expect(a == 1)\ntry #require(hs.count == 1)\ntry #require(hs[0].ls.count > 2)\n#expect(hs[0].ls[2] == x)", 0),
    ("#expect(a == 1)\nlet b = [1, 2][0]", 0),
    ("    #expect(a == 1)\n    func helper() {}\n    #expect(xs[0] == b)", 1),
    ("}\n    @Test func two() {\n    let xs = try #require(ys)\n    #expect(a == 1)\n    }\n    @Test func three() {\n    #expect(a == 1)\n    #expect(xs[0] == b)", 1),
    ("#expect(a == 1)\nguard case .a = xs[0],\ncase .b = xs[1] else { return }", 2),
    ("#expect(a == 1)\nguard xs.count == 2,\ncase .a = xs[0] else { return }", 0),
    ("#expect(a == 1)\n}\n@Test func next() {\nlet b = xs[0]", 0),
]


def selftest():
    failed = 0
    for source, want in SELFTEST:
        got = len(sites("func t() {\n" + source + "\n}"))
        if got != want:
            failed += 1
            print(f"selftest: wanted {want}, found {got} in:\n{source}\n")
    print("selftest: ok" if not failed else f"selftest: {failed} failed")
    return 1 if failed else 0


def main(args):
    if args[:1] == ["--selftest"]:
        return selftest()
    paths = [Path(a) for a in args] or list(files())
    total = 0
    for path in paths:
        for number, kind, line in sites(path.read_text()):
            total += 1
            shown = path.relative_to(ROOT) if path.is_absolute() and ROOT in path.parents else path
            print(f"{shown}:{number}: {kind} after a check that does not stop the test: {line}")
    if total:
        print(f"\n{total} site(s). Use `try #require(...)` or guard before indexing (#94); "
              "a line safe for another reason says why with `// index-ok:`.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
