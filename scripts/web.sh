#!/bin/sh
# The web remote (071): its generated types, its build, and the checks CI runs.
#
#   scripts/web.sh types   regenerate Web/src/protocol/generated.ts: scripts/wire.sh gen (#1135)
#   scripts/web.sh build   install the pinned packages and build Web/dist (needs Node; with nvm
#                          and another Node, nvm installs the pinned one: #4987)
#   scripts/web.sh dist    what Agents Host's build runs first: build Web/dist when a source is
#                          newer than it; with no Node (or another version), leave an empty one
#                          and warn, so the app still builds and its web remote stays off
#   scripts/web.sh test    the web app's tests (needs Node)
#   scripts/web.sh check   everything CI checks: types fresh (scripts/wire.sh check), and, when
#                          Node is here, a build,
#                          Web/dist matching its manifest, tsc, lint, licences and tests
#
# generated.ts is checked in, made from Packages/Wire: a change to a protocol type changes the
# schema there, regenerates and commits it. Web/dist
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

# A host with nvm and another Node (a codespace's image has Node 24; #4987): put the pinned
# Node first on PATH. With "install", nvm downloads it when it is missing; without, only a
# Node that nvm already has is used, so an Xcode build phase never downloads. nvm is a bash
# function that does not run under `set -u`, so it runs in a bash of its own.
use_nvm_node() {
	have_pinned_node && return 0
	nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
	[ -s "$nvm_sh" ] && command -v bash >/dev/null 2>&1 || return 0
	version=$(cat Web/.node-version)
	if [ "${1:-}" = install ]; then
		node_bin=$(NVM_SH="$nvm_sh" V="$version" bash -c '. "$NVM_SH" >/dev/null 2>&1 &&
			nvm install "$V" >&2 && nvm which "$V"') || return 0
	else
		node_bin=$(NVM_SH="$nvm_sh" V="$version" bash -c '. "$NVM_SH" >/dev/null 2>&1 &&
			nvm which "$V"' 2>/dev/null) || return 0
	fi
	[ -x "$node_bin" ] || return 0
	PATH="$(dirname -- "$node_bin"):$PATH"
	export PATH
}

# A Mac whose first `node` on PATH is another version, but which has the pinned one installed as
# well (an agent session puts its runtime's own Node first; #4904): put that one first. Homebrew
# keeps each version under Cellar/node/<version>; its bin is checked last, as it may be a link
# to another version.
use_installed_node() {
	have_pinned_node && return 0
	version=$(cat Web/.node-version)
	for dir in /opt/homebrew/Cellar/node/"$version"/bin /usr/local/Cellar/node/"$version"/bin \
		/opt/homebrew/bin /usr/local/bin; do
		[ -x "$dir/node" ] && [ -x "$dir/npm" ] || continue
		[ "$("$dir/node" --version 2>/dev/null)" = "v$version" ] || continue
		PATH="$dir:$PATH"
		export PATH
		return 0
	done
	return 0
}

# The pinned Node from nvm, or else from where it is usually installed.
use_pinned_node() {
	use_nvm_node "$@"
	use_installed_node
}

# Web/dist is older than one of the inputs build.mjs hashes, or was never built.
dist_stale() {
	[ -f Web/dist/MANIFEST ] || return 0
	[ -n "$(find Web/src Web/assets Web/index.html Web/sandbox.html Web/build.mjs Web/lucide.mjs Web/tsconfig.json \
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
	exec scripts/wire.sh gen
	;;
build)
	use_pinned_node install
	need_node build
	build
	;;
dist)
	if ! dist_stale; then
		exit 0
	elif use_pinned_node && have_pinned_node; then
		build
	else
		# "warning:" is how an Xcode script phase shows one in the build log.
		echo "warning: web.sh: no Node $(cat Web/.node-version) here, so Agents Host is built without its web remote; install it and build again to serve the web page"
		mkdir -p Web/dist
	fi
	;;
test)
	use_pinned_node install
	need_node test
	cd Web
	[ -d node_modules ] || npm ci --ignore-scripts --no-audit --no-fund
	exec npm test
	;;
check)
	scripts/wire.sh check
	use_pinned_node install
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
