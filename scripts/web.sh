#!/bin/sh
# The web remote (071): its generated types, its checked-in build, and the checks CI runs.
#
#   scripts/web.sh types   regenerate Web/src/protocol/generated.ts from AgentsKitCore's source
#   scripts/web.sh build   install the pinned packages and rebuild Web/dist (needs Node)
#   scripts/web.sh test    the web app's tests (needs Node)
#   scripts/web.sh check   everything CI checks: types fresh, Web/dist matches its manifest,
#                          and, when Node is here, tsc, lint, licences, tests and a rebuild
#                          that must change nothing
#
# Building Agents from source needs none of this: Web/dist and generated.ts are checked in.
# Only changing the web app, or a protocol type in Swift, does.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

have_node() {
	command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1
}

need_node() {
	have_node || { echo "web.sh: $1 needs Node $(cat Web/.node-version) and npm" >&2; exit 1; }
}

case "${1:-}" in
types)
	exec swift run --package-path Packages/WebTypes agents-webtypes --root "$root"
	;;
build)
	need_node build
	cd Web
	npm ci --ignore-scripts --no-audit --no-fund
	exec npm run build
	;;
test)
	need_node test
	cd Web
	[ -d node_modules ] || npm ci --ignore-scripts --no-audit --no-fund
	exec npm test
	;;
check)
	swift run --package-path Packages/WebTypes agents-webtypes --root "$root" --check
	swift test --package-path Packages/AgentsKit --filter 'WebDistManifestTests|ControlAgreementVectorTests'
	if have_node; then
		cd Web
		npm ci --ignore-scripts --no-audit --no-fund
		npm run check
		npm test
		npm run build
		cd "$root"
		git diff --exit-code -- Web/dist Web/src/protocol/generated.ts ||
			{ echo "web.sh: Web/dist is not what this source builds; commit the rebuilt files" >&2; exit 1; }
	else
		echo "web.sh: no Node here; checked the manifest only (CI's web job rebuilds with Node)" >&2
	fi
	;;
*)
	echo "usage: scripts/web.sh types | build | test | check" >&2
	exit 2
	;;
esac
