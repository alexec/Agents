#!/usr/bin/env python3
"""A change to what a caller sends makes a new capability number (#4095, docs/explanation/versions.md).

    wire-compat.py [<tag>]    compare Packages/Wire with <tag> (default: the last release tag)
    wire-compat.py --selftest

An older server refuses what it does not know. So each method in Packages/Wire/*.openrpc.json
whose params a caller may now send in a way that the release at <tag> refuses must have a new
x-capability:

- a property leaves `required` (a type's `required` list gets shorter), or a param stops being
  required;
- an enum in the params gets a new value;
- a new required property or param, or a property's or param's type changes.

What a server sends (results and notifications) keeps the rule that a new optional field or a
new enum value keeps the number. Run by `scripts/wire.sh compat`, and by CI's lint job when
Packages/Wire changes.
"""
import json
import subprocess
import sys

DOCUMENTS = ["Packages/Wire/daemon.openrpc.json", "Packages/Wire/control.openrpc.json"]
SCHEMA = "Packages/Wire/daemon.schema.json"
PREFIX = "daemon.schema.json#/definitions/"
LOCAL = "#/definitions/"


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def last_tag():
    """The last release tag: from history, or from origin in a shallow clone such as CI's."""
    described = git("describe", "--tags", "--abbrev=0", "--match", "v*")
    if described.returncode == 0:
        return described.stdout.strip()
    listed = git("ls-remote", "--tags", "--refs", "origin", "v*")
    tags = [line.split("refs/tags/", 1)[1] for line in listed.stdout.splitlines() if "refs/tags/" in line]
    releases = [t for t in tags if "-" not in t]
    if not releases:
        return None
    tag = max(releases, key=lambda t: [int(p) if p.isdigit() else 0 for p in t.lstrip("v").split(".")])
    git("fetch", "--quiet", "--depth=1", "origin", f"refs/tags/{tag}:refs/tags/{tag}")
    return tag


def read(revision, path):
    """A file at a revision, or in the working tree with no revision; None when it is missing."""
    if revision is None:
        try:
            with open(path) as f:
                return json.load(f)
        except FileNotFoundError:
            return None
    shown = git("show", f"{revision}:{path}")
    return json.loads(shown.stdout) if shown.returncode == 0 else None


class Side:
    """One revision of the wire: its methods by name, and its schema's definitions."""

    def __init__(self, documents, schema):
        self.methods = {}
        for document in documents:
            for m in (document or {}).get("methods", []):
                self.methods[m["name"]] = m
        self.definitions = (schema or {}).get("definitions", {})

    def resolve(self, schema):
        """The schema, and the name of the definition it refers to, if any."""
        ref = schema.get("$ref", "")
        for prefix in (PREFIX, LOCAL):
            if ref.startswith(prefix):
                name = ref[len(prefix):]
                return self.definitions.get(name, {}), name
        return schema, None


def kind(schema):
    """What a schema is, to tell when a type changes: its type, or its $ref."""
    if "$ref" in schema:
        return "$ref " + schema["$ref"].rsplit("/", 1)[-1]
    t = schema.get("type")
    return " or ".join(t) if isinstance(t, list) else t


def looser(old, new, where, before, after, seen):
    """What a caller may send under `new` that `old` refuses, as lines."""
    found = []
    if kind(old) != kind(new) and kind(old) is not None:
        return [f"{where} is {kind(new)}, was {kind(old)}"]
    old, name = before.resolve(old)
    new, _ = after.resolve(new)
    if name is not None:
        if name in seen:
            return []
        seen = seen | {name}
        where = name
    if kind(old) != kind(new) and "$ref" not in old and "$ref" not in new:
        return [f"{where} is {kind(new)}, was {kind(old)}"]
    if "enum" in old and "enum" in new:
        added = [v for v in new["enum"] if v not in old["enum"]]
        if added:
            found.append(f"{where} has new enum value{'s' if len(added) > 1 else ''} "
                         + ", ".join(json.dumps(v) for v in added))
    old_required, new_required = set(old.get("required", [])), set(new.get("required", []))
    for p in sorted(old_required - new_required):
        found.append(f"{where}.{p} left required")
    for p in sorted(new_required - old_required):
        found.append(f"{where}.{p} is a new required property")
    old_props, new_props = old.get("properties", {}), new.get("properties", {})
    for p in sorted(set(old_props) & set(new_props)):
        found += looser(old_props[p], new_props[p], f"{where}.{p}", before, after, seen)
    for key in ("items", "additionalProperties"):
        if isinstance(old.get(key), dict) and isinstance(new.get(key), dict):
            found += looser(old[key], new[key], f"{where}[]" if key == "items" else f"{where}{{}}",
                            before, after, seen)
    for key in ("oneOf", "anyOf", "allOf"):
        for i, (o, n) in enumerate(zip(old.get(key, []), new.get(key, []))):
            found += looser(o, n, f"{where}.{key}[{i}]", before, after, seen)
    return found


def params_looser(old_method, new_method, before, after):
    old_params = {p["name"]: p for p in old_method.get("params", [])}
    new_params = {p["name"]: p for p in new_method.get("params", [])}
    found = []
    for name, p in old_params.items():
        if p.get("required") and not new_params.get(name, {}).get("required"):
            found.append(f"param {name} left required" if name in new_params else f"param {name} is gone")
    for name, p in new_params.items():
        if name not in old_params:
            if p.get("required"):
                found.append(f"param {name} is new and required")
            continue
        found += looser(old_params[name].get("schema", {}), p.get("schema", {}), f"param {name}",
                        before, after, frozenset())
    return found


def raise_number(capability):
    name, _, number = capability.rpartition("/")
    return f"{name}/{int(number) + 1}" if number.isdigit() else capability


def compare(before, after):
    """Each method whose params got looser with the same x-capability, as lines to print."""
    problems = []
    for name, new in sorted(after.methods.items()):
        old = before.methods.get(name)
        if old is None or new.get("x-notification") or old.get("x-capability") != new.get("x-capability"):
            continue
        for change in params_looser(old, new, before, after):
            c = new.get("x-capability", "?")
            problems.append(f"{name}: {change}; raise {c} to {raise_number(c)}")
    return problems


def side(revision):
    return Side([read(revision, d) for d in DOCUMENTS], read(revision, SCHEMA))


def selftest():
    def doc(capability, ref="ProviderCreate", notification=False):
        m = {"name": "providers/create", "x-capability": capability,
             "params": [{"name": "params", "required": True, "schema": {"$ref": PREFIX + ref}}]}
        if notification:
            m["x-notification"] = True
        return [{"methods": [m]}]

    def schema(**create):
        base = {"type": "object", "required": ["id", "name"],
                "properties": {"id": {"type": "string"}, "name": {"type": "string"},
                               "kind": {"type": "string", "enum": ["a", "b"]},
                               "tags": {"type": "array", "items": {"$ref": "#/definitions/Tag"}}}}
        base.update(create)
        return {"definitions": {"ProviderCreate": base,
                                "Tag": {"type": "object", "required": ["k"], "properties": {"k": {"type": "string"}}}}}

    old = Side(doc("providers/1"), schema())
    assert compare(old, Side(doc("providers/1"), schema())) == []
    # A property leaves required with the same number: refused, and says what to raise.
    loose = schema(required=["id"])
    assert compare(old, Side(doc("providers/1"), loose)) == [
        "providers/create: ProviderCreate.name left required; raise providers/1 to providers/2"], \
        compare(old, Side(doc("providers/1"), loose))
    # The same change with a new number passes.
    assert compare(old, Side(doc("providers/2"), loose)) == []
    # A new enum value in the params.
    wider = schema()
    wider["definitions"]["ProviderCreate"]["properties"]["kind"]["enum"] = ["a", "b", "c"]
    assert compare(old, Side(doc("providers/1"), wider)) == [
        'providers/create: ProviderCreate.kind has new enum value "c"; raise providers/1 to providers/2']
    # A new required property, and a type change, deep in a $ref.
    stricter = schema(required=["id", "name", "kind"])
    stricter["definitions"]["Tag"]["properties"]["k"] = {"type": "integer"}
    assert compare(old, Side(doc("providers/1"), stricter)) == [
        "providers/create: ProviderCreate.kind is a new required property; raise providers/1 to providers/2",
        "providers/create: Tag.k is integer, was string; raise providers/1 to providers/2"], \
        compare(old, Side(doc("providers/1"), stricter))
    # A new optional property keeps the number, and so does a notification (what a server sends).
    more = schema()
    more["definitions"]["ProviderCreate"]["properties"]["extra"] = {"type": "string"}
    assert compare(old, Side(doc("providers/1"), more)) == []
    assert compare(Side(doc("providers/1", notification=True), schema()),
                   Side(doc("providers/1", notification=True), loose)) == []
    # A method that is new, or a document missing at the tag, has nothing to compare.
    assert compare(Side([None], None), Side(doc("providers/1"), loose)) == []
    assert raise_number("org-routes/2") == "org-routes/3"
    print("wire-compat: selftest ok")


def main(argv):
    if argv[1:] == ["--selftest"]:
        selftest()
        return 0
    tag = argv[1] if len(argv) > 1 else last_tag()
    if tag is None:
        print("wire-compat: no release tag to compare with", file=sys.stderr)
        return 0
    if git("rev-parse", "--verify", "--quiet", f"{tag}^{{commit}}").returncode != 0:
        print(f"wire-compat: {tag} is not here", file=sys.stderr)
        return 1
    problems = compare(side(tag), side(None))
    for p in problems:
        print(f"wire-compat: {p}", file=sys.stderr)
    if problems:
        print(f"wire-compat: what a caller sends changed since {tag} with the same capability number. "
              "An older server refuses it, and the caller cannot know. Raise the number "
              "(docs/explanation/versions.md, \"Changing a capability\").", file=sys.stderr)
        return 1
    print(f"wire-compat: what a caller sends is as {tag} reads it, or has a new number")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
