#!/bin/sh
# Makes schema/daemon.schema.json from today's Swift: Packages/WebTypes already writes every
# DaemonAPI type the web reaches into Web/src/protocol/generated.ts, and ts-json-schema-generator
# turns that into JSON Schema (bootstrap/all.schema.json, 361 definitions). subset.js keeps
# what stages 1–2 use. Once the schema is the source, this step goes and gen.sh is all.
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/bootstrap" "$here/ts"
cp "$here/../../Web/src/protocol/generated.ts" "$here/bootstrap/generated.ts"
cp "$here/../../Web/src/protocol/generated.ts" "$here/ts/generated.ts"
docker run --rm -v "$here/bootstrap":/w -v "$HOME/Library/Caches/Agents-build/go-spike/npm":/root/.npm -w /w node:22-bookworm \
  npx -y ts-json-schema-generator@2 --path generated.ts --type "*" --expose export --no-type-check -o all.schema.json
cd "$here" && node subset.js
