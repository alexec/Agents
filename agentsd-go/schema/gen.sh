#!/bin/sh
# Generates the wire types from schema/daemon.schema.json (schema-first, stage 3):
#   Go         internal/wire/types_gen.go      (atombender/go-jsonschema)
#   Swift      schema/swift-check/Sources/WireTypes/Wire.swift   (quicktype)
#   TypeScript schema/ts/wire.ts               (quicktype)
# Re-making the schema itself from today's Swift (through generated.ts) is
# schema/bootstrap.sh; once the schema is the source, that step goes.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
./go.sh run github.com/atombender/go-jsonschema@v0.24.1 -p wire --capitalization ID --capitalization URL \
  --only-models -o internal/wire/types_gen.go schema/daemon.schema.json 2>/dev/null
# A case with no values ({"timedOut":{}}) is an empty object: go-jsonschema types it as a
# map, and omitempty drops an empty map. A pointer keeps "present and empty".
python3 - <<'PY'
import re
p = "internal/wire/types_gen.go"
s = open(p).read()
maps = set(re.findall(r"^type (\w+) map\[string\]interface\{\}$", s, re.M))
def fix(m):
    name, typ, tag = m.group(1), m.group(2), m.group(3)
    return f"\t{name} *{typ} {tag}" if typ in maps and "omitempty" in tag else m.group(0)
s = re.sub(r"^\t(\w+) (\w+) (`json:\"[^`]*`)$", fix, s, flags=re.M)
open(p, "w").write(s)
PY
mkdir -p schema/ts schema/swift-check/Sources/WireTypes
# quicktype overflows its stack on the recursive JSONValue: it reads a copy where it is "any".
node -e 'const s=require("./schema/daemon.schema.json"); s.definitions.JSONValue={}; require("fs").writeFileSync("schema/.quicktype.schema.json", JSON.stringify(s))' 
docker run --rm -v "$here/schema":/w -v "$HOME/Library/Caches/Agents-build/go-spike/npm":/root/.npm -w /w node:22-bookworm sh -c '
  npx -y quicktype@23 --src-lang schema --lang typescript --just-types --prefer-unions --acronym-style original -o ts/wire.ts .quicktype.schema.json &&
  npx -y quicktype@23 --src-lang schema --lang swift --acronym-style original --struct-or-class struct --type-prefix W \
     --access-level public -o swift-check/Sources/WireTypes/Wire.swift .quicktype.schema.json' 2>&1 | grep -v "npm notice" || true
wc -l internal/wire/types_gen.go schema/ts/wire.ts schema/swift-check/Sources/WireTypes/Wire.swift
