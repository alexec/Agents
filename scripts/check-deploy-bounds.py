#!/usr/bin/env python3
"""What the deploy writes to the disk has a limit (#2290).

Docker's default log driver, json-file, keeps every line for ever, and each release pulls a
new image that stays when nothing removes it. This reads `deploy/compose*.yaml` and
`deploy/gcp/up.sh`, and fails on:

- a service with no `logging:` limit: its own `logging:`, or a merge (`<<: *name`) of a
  top-level block that has one. A service with no `image:` or `build:` overrides one in
  another file (compose.pebble.yaml over compose.public.yaml), and is that file's;
- a `logging:` block with no `max-size` (inline, or in the `&name` block it names);
- an `up.sh` that does not prune the images no container uses.

`--selftest` checks the check.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent

TOP = re.compile(r"^([\w.-]+):(?:\s*&([\w-]+))?\s*$")


def blocks(lines, start, indent):
    """The (name, body lines) of each key at `indent` spaces from `start` until the block ends."""
    out = []
    name, body = None, []
    for line in lines[start:]:
        if line.strip() == "" or line.lstrip().startswith("#"):
            if name:
                body.append(line)
            continue
        lead = len(line) - len(line.lstrip(" "))
        if lead < indent:
            break
        if lead == indent:
            if name:
                out.append((name, body))
            name, body = line.strip().split(":", 1)[0], [line]
        elif name:
            body.append(line)
    if name:
        out.append((name, body))
    return out


def problems(name, text):
    lines = text.splitlines()
    found = []
    limited = set()  # anchors whose block holds a limited logging
    anchor_text = {}
    for i, line in enumerate(lines):
        m = TOP.match(line)
        if m and m.group(2):
            body = [ln for _, b in blocks(lines, i + 1, 2) for ln in b]
            anchor_text[m.group(2)] = "\n".join(body)
            ref = re.search(r"logging:\s*\*([\w-]+)", anchor_text[m.group(2)])
            if "max-size" in anchor_text[m.group(2)] or (ref and ref.group(1) in limited):
                limited.add(m.group(2))
    try:
        start = next(i for i, ln in enumerate(lines) if ln.rstrip() == "services:")
    except StopIteration:
        return found
    for service, body in blocks(lines, start + 1, 2):
        text = "\n".join(body)
        m = re.search(r"^\s+logging:\s*(\*([\w-]+))?\s*$", text, re.M)
        if m:
            if m.group(2):
                if m.group(2) not in limited:
                    found.append(f"{name}: {service}'s logging *{m.group(2)} has no max-size")
            elif "max-size" not in text:
                found.append(f"{name}: {service}'s logging has no max-size")
            continue
        merges = re.findall(r"<<:\s*\*([\w-]+)", text)
        if any(a in limited for a in merges):
            continue
        if not merges and not re.search(r"^    (image|build):", text, re.M):
            continue  # an override of a service in another file, such as compose.pebble.yaml's
        found.append(f"{name}: {service} has no logging limit (#2290)")
    return found


def prune_problems(name, text):
    if not re.search(r"docker image prune -a", text):
        return [f"{name}: does not prune the images no container uses (#2290)"]
    return []


def selftest():
    good = """x-logging: &logging
  driver: local
  options:
    max-size: 10m

x-copy: &copy
  image: a
  logging: *logging

services:
  a:
    logging: *logging
    image: a
  b:
    <<: *copy
  c:
    image: c
    logging:
      driver: local
      options:
        max-size: 1m
volumes:
  data:
"""
    assert problems("good", good) == [], problems("good", good)
    bad = """services:
  override:
    environment:
      A: b
  a:
    image: a
  b:
    logging:
      driver: json-file
"""
    got = problems("bad", bad)
    assert got == ["bad: a has no logging limit (#2290)", "bad: b's logging has no max-size"], got
    unlimited = """x-logging: &logging
  driver: json-file

services:
  a:
    logging: *logging
"""
    assert problems("u", unlimited) == ["u: a's logging *logging has no max-size"]
    assert prune_problems("up", "vm_ssh 'sudo docker image prune -af'") == []
    assert prune_problems("up", "vm_ssh up -d") != []
    print("check-deploy-bounds: selftest ok")


def main():
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    found = []
    for path in sorted((root / "deploy").glob("compose*.yaml")):
        found += problems(str(path.relative_to(root)), path.read_text())
    up = root / "deploy/gcp/up.sh"
    found += prune_problems(str(up.relative_to(root)), up.read_text())
    for line in found:
        print(line, file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
