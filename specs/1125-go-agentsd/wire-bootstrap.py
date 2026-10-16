#!/usr/bin/env python3
"""How Packages/Wire was made from today's Swift, once (#1135). Kept as the record; it is not
run again, because Packages/Wire is now the source and the Swift is checked against it.

It ran in a scratch folder (here) holding:
  old.generated.ts     Web/src/protocol/generated.ts as Packages/WebTypes last made it
  int/all.schema.json  `ts-json-schema-generator@2 --type "*" --expose export --no-type-check
                       --unstable` over the generated.ts a scratch copy of Packages/WebTypes
                       wrote with Swift's Int family as a `WireInt` brand, so that the schema
                       says `integer` where Swift has Int and `number` where it has Double
and AgentsKitCore's source, for WebSignatures' notification kinds. The scratch folder sat two
levels under the repository (build/wire/), which is what `root` below assumes.

It wrote Packages/Wire/daemon.schema.json, daemon.openrpc.json and control.openrpc.json.
"""
import json, os, re, sys

root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
here = os.path.dirname(os.path.abspath(__file__))
src = json.load(open(os.path.join(here, "int", "all.schema.json")))
defs = src["definitions"]
ts = open(os.path.join(here, "old.generated.ts")).read()  # generated.ts as WebTypes made it
core = os.path.join(root, "Packages/AgentsKit/Sources/AgentsKitCore")

methods = defs.pop("Methods")
notifications = defs.pop("Notifications")
defs.pop("WireInt")


def fix(v):
    """WireInt is integer; every other $ref names a definition in daemon.schema.json."""
    if isinstance(v, dict):
        if v.get("$ref") == "#/definitions/WireInt":
            out = {k: fix(x) for k, x in v.items() if k != "$ref"}
            out["type"] = "integer"
            return out
        return {k: fix(x) for k, x in v.items()}
    if isinstance(v, list):
        return [fix(x) for x in v]
    return v


defs = fix(defs)
methods = fix(methods)
notifications = fix(notifications)

# The five meaning-types (#1134): written by hand in each language, named here.
meaning = {
    "UUID": {"format": "uuid", "pattern": "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
             "x-swift-type": "UUID", "x-go-type": "UUID"},
    "WireDate": {"x-swift-type": "Date", "x-go-type": "Date"},
    "Base64": {"contentEncoding": "base64", "x-swift-type": "Data", "x-go-type": "Data"},
    "URLString": {"format": "uri", "x-swift-type": "URL", "x-go-type": "URL"},
    "JSONValue": {"x-swift-type": "JSONValue", "x-go-type": "JSONValue"},
}
ts_brand = lambda base, name: f'{base} & {{ readonly __brand: "{name}" }}'
meaning["UUID"]["x-ts-type"] = ts_brand("string", "UUID")
meaning["WireDate"]["x-ts-type"] = ts_brand("number", "WireDate")
meaning["Base64"]["x-ts-type"] = ts_brand("string", "Base64")
meaning["URLString"]["x-ts-type"] = ts_brand("string", "URLString")
meaning["JSONValue"]["x-ts-type"] = "null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue }"
for name, extra in meaning.items():
    defs[name].update(extra)

# A Swift enum of one case: ts-json-schema-generator unwrapped it.
defs["AgentPurpose"] = {"anyOf": [defs["AgentPurpose"]]}

# The other brands generated.ts had, kept for the web page; plain strings to Go.
for m in re.finditer(r'^export type (\w+) = (string & \{ readonly __brand: "\w+" \});$', ts, re.M):
    if m.group(1) not in meaning:
        defs[m.group(1)]["x-ts-type"] = m.group(2)
defs["ProjectSummary"]["properties"]["counts"]["x-ts-type"] = "Partial<Record<AgentGroup, number>>"

# The forgiving decoders, kept hand-written in Swift, said in the schema.
defs["AgentState"]["x-fallback"] = "stopped"
defs["AgentState"]["description"] = ("A state this build does not know reads as `stopped` (Agent's init(from:)), "
                                     "with endedReason `unrecognised`.")
defs["EndedReason"]["x-fallback"] = "unrecognised"
defs["EndedReason"]["description"] = "A reason this build does not know reads as `unrecognised`."
defs["TranscriptEntryKind"]["x-fallback"] = "keep"
defs["TranscriptEntryKind"]["description"] = ("One key, the kind's name, holding its fields. A kind this build does "
                                              "not know is kept whole and written back as it was read "
                                              "(TranscriptEntry+Coding.swift).")

defs["WorkflowSummary"]["properties"]["isEnabled"]["default"] = True
defs["WorkflowSummary"]["x-fallback"] = "defaults"
defs["WorkflowSummary"]["description"] = ("Read forgivingly (Workflow.swift's init(from:)): a field that is missing "
                                          "or does not read takes its default (`isEnabled` true; false, 0, [] or "
                                          "absent for the rest).")

schema = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "$id": "https://agents.alexecollins.com/schema/daemon.schema.json",
    "title": "The wire between the clients, the hosts (agentsd) and the control plane",
    "description": ("The source of every type on the wire (#1135). Go (Go/wire) and TypeScript "
                    "(Web/src/protocol/generated.ts) are made from it by scripts/wire.sh gen; Swift's "
                    "Model types are written by hand and checked against it (WireSchemaTests)."),
    "definitions": {k: defs[k] for k in sorted(defs)},
}

# Failure codes and where each method goes, from generated.ts.
failures = re.search(r"export const Failure = \{(.*?)\} as const;", ts, re.S).group(1)
failures = [(m.group(1), int(m.group(2))) for m in re.finditer(r"(\w+): (-?\d+),", failures)]
targets = dict(re.findall(r'^  "([^"]+)": "(host|control)",$',
                          re.search(r"export const MethodTarget = \{(.*?)\} as const;", ts, re.S).group(1), re.M))

# Notification kinds, from WebSignatures' rows and DaemonAPI.Notification's names.
names = {}
for dirpath, _, files in os.walk(core):
    for f in files:
        if f.endswith(".swift"):
            text = open(os.path.join(dirpath, f)).read()
            for m in re.finditer(r'static let (\w+)\s*=\s*"([^"]+)"', text):
                names.setdefault(m.group(1), set()).add(m.group(2))
web = open(os.path.join(core, "Daemon/DaemonAPI+Web.swift")).read()
web = re.sub(r"\s+", " ", web)
note_kind = {}
for m in re.finditer(r"Row\(Notification\.(\w+), params: [^)]*?kind: \.(\w+)\)", web):
    candidates = [n for n in names.get(m.group(1), ()) if n in notifications["properties"]]
    assert len(candidates) == 1, (m.group(1), candidates)
    note_kind[candidates[0]] = m.group(2)
assert set(note_kind) == set(notifications["properties"]), set(notifications["properties"]) ^ set(note_kind)


def ref(v):
    """A schema in the OpenRPC document: its $refs point into daemon.schema.json."""
    if isinstance(v, dict):
        return {k: (x.replace("#/definitions/", "daemon.schema.json#/definitions/") if k == "$ref" else ref(x))
                for k, x in v.items()}
    if isinstance(v, list):
        return [ref(x) for x in v]
    return v


def document(target, title, description):
    out = []
    for name, sig in methods["properties"].items():
        if targets[name] != target:
            continue
        out.append({
            "name": name,
            "tags": [{"name": "web"}],
            "paramStructure": "by-name",
            "params": [{"name": "params", "required": True, "schema": ref(sig["properties"]["params"])}],
            "result": {"name": "result", "schema": ref(sig["properties"]["result"])},
        })
    for name, params in notifications["properties"].items():
        if note_kind[name] != ("hostNotification" if target == "host" else "controlNotification"):
            continue
        out.append({
            "name": name,
            "tags": [{"name": "web"}],
            "x-notification": True,
            "paramStructure": "by-name",
            "params": [{"name": "params", "required": True, "schema": ref(params)}],
        })
    doc = {
        "openrpc": "1.3.2",
        "info": {"title": title, "version": "0", "description": description},
        "methods": sorted(out, key=lambda m: (m.get("x-notification", False), m["name"])),
    }
    if target == "host":
        doc["components"] = {"errors": {n: {"code": c, "message": n} for n, c in sorted(failures)}}
    return doc


common = (" Every method's params are its one `params` value, sent as JSON-RPC's whole params (an object, "
          "or for a few a bare value), as DaemonAPI sends them. A method with `x-notification` has no "
          "result: the server sends it. The `web` tag marks what the web page calls and hears "
          "(DaemonAPI.WebSignatures); a method a Go step ports joins with its types, schema first.")
out = os.path.join(root, "Packages/Wire")
os.makedirs(out, exist_ok=True)
for name, value in [
    ("daemon.schema.json", schema),
    ("daemon.openrpc.json", document("host", "agentsd", "The methods a host (agentsd) answers, sent to it with `h`." + common)),
    ("control.openrpc.json", document("control", "agents-control",
                                      "The methods the control plane answers itself, with no `h`." + common)),
]:
    with open(os.path.join(out, name), "w") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
        f.write("\n")
print(len(schema["definitions"]), "definitions;", len(methods["properties"]), "methods;",
      len(notifications["properties"]), "notifications;", len(failures), "failures")
