#!/bin/sh
# Stage 3's checks: Go and Swift types round-trip today's Swift encoder's output, the Go
# host's own records fit the schema, and today's TypeScript types fit the schema's.
# The Swift check builds AgentsKitCore: hold the "build" lease while it runs.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
./go.sh test ./internal/wire/ ./internal/daemon/ -run 'TestSwiftFixturesRoundTrip|TestHostRecordsFitTheSchema' -v | grep -E "found|kinds|ok|FAIL"
docker run --rm -v "$here/schema/ts":/w -v "$HOME/Library/Caches/Agents-build/go-spike/npm":/root/.npm -w /w node:22-bookworm \
  npx -y -p typescript@5 tsc --noEmit --strict --target es2022 --moduleResolution bundler --module esnext check.ts && echo "tsc: today's types fit the schema's"
(cd schema/swift-check && ../../../scripts/build-cache.sh swift test 2>&1 | grep -E "found|skipped|passed|failed|error:")
