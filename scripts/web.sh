#!/bin/sh
# The web remote (071): its generated types, its build, and the checks CI runs.
#
#   scripts/web.sh types   regenerate Web/src/protocol/generated.ts from AgentsKitCore's source
#   scripts/web.sh build   install the pinned packages and build Web/dist (needs Node)
#   scripts/web.sh dist    what Agents Host's build runs first: build Web/dist when a source is
#                          newer than it; with no Node (or another version), leave an empty one
#                          and warn, so the app still builds and its web remote stays off
#   scripts/web.sh test    the web app's tests (needs Node)
#   scripts/web.sh check   everything CI checks: types fresh, and, when Node is here, a build,
#                          Web/dist matching its manifest, tsc, lint, licences and tests
#
# generated.ts is checked in: a change to a protocol type regenerates and commits it. Web/dist
# is not (#473): it is ignored, built here, and a pull request never carries it.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

# An Xcode script phase has a bare PATH: look where Node is usually installed as well.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

have_node() {
	command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1
}

need_node() {
	have_node || { echo "web.sh: $1 needs Node $(cat Web/.node-version) and npm" >&2; exit 1; }
}

# The pinned Node, not just any: build.mjs refuses another, as its bytes would differ.
have_pinned_node() {
	have_node && [ "$(node --version)" = "v$(cat Web/.node-version)" ]
}

# Web/dist is older than one of the inputs build.mjs hashes, or was never built.
dist_stale() {
	[ -f Web/dist/MANIFEST ] || return 0
	[ -n "$(find Web/src Web/assets Web/index.html Web/sandbox.html Web/build.mjs Web/tsconfig.json \
		Web/package.json Web/package-lock.json Web/.node-version -newer Web/dist/MANIFEST 2>/dev/null | head -1)" ]
}

build() {
	cd "$root/Web"
	npm ci --ignore-scripts --no-audit --no-fund
	npm run build
	cd "$root"
}

case "${1:-}" in
types)
	exec swift run --package-path Packages/WebTypes agents-webtypes --root "$root"
	;;
build)
	need_node build
	build
	;;
dist)
	if ! dist_stale; then
		exit 0
	elif have_pinned_node; then
		build
	else
		# "warning:" is how an Xcode script phase shows one in the build log.
		echo "warning: web.sh: no Node $(cat Web/.node-version) here, so Agents Host is built without its web remote; install it and build again to serve the web page"
		mkdir -p Web/dist
	fi
	;;
test)
	need_node test
	cd Web
	[ -d node_modules ] || npm ci --ignore-scripts --no-audit --no-fund
	exec npm test
	;;
check)
	scripts/build-cache.sh swift run --package-path Packages/WebTypes agents-webtypes --root "$root" --check
	if have_node; then
		build
		scripts/build-cache.sh swift test --package-path Packages/AgentsKit --filter 'WebDistManifestTests|ControlAgreementVectorTests'
		cd Web
		npm run check
		npm test
	else
		scripts/build-cache.sh swift test --package-path Packages/AgentsKit --filter 'ControlAgreementVectorTests'
		echo "web.sh: no Node here; checked the types only (CI's web job builds and tests with Node)" >&2
	fi
	;;
*)
	echo "usage: scripts/web.sh types | build | dist | test | check" >&2
	exit 2
	;;
esac
