#!/usr/bin/env bash
# `a && b || fail` is the assertion here; w1, w2 and row are run through branch().
# shellcheck disable=SC2015,SC2329
# merge-wave.sh's own test, in a throwaway clone of this repository: never the real main.
#
#   selftest.sh [scenario...]   clean, web, conflict, bisect, docs, reuse (all by default)
#
# Builds are a stub (MERGE_WAVE_STUB): it fails any step when the tree has a file
# called WAVE_BREAK, and passes otherwise. The one real build is the web scenario's
# `scripts/web.sh build` (Node, a few seconds), which is what rebuilds a Web/dist
# conflict: run this under the "build" lease.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MW=$HERE/merge-wave.sh
SRC=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)
SRC=$(dirname "$SRC")
T=/tmp/mw-selftest
STUB=$T-stub.sh

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

rm -rf "$T"
for w in /tmp/wave-*; do # waves of an earlier self-test only: their gitdir is in $T
	[ -e "$w/.git" ] && grep -q "$T/" "$w/.git" 2>/dev/null && rm -rf "$w"
done
git clone -q "$SRC" "$T"
cd "$T"
git config user.email selftest@example.com
git config user.name selftest
M=$(git rev-parse main)

cat >"$STUB" <<'EOF'
#!/bin/sh
# merge-wave's stand-in for a build: the real web build, anything else passes unless
# the tree carries WAVE_BREAK.
echo "stub $1 at $(git rev-parse --short HEAD)"
case $1 in rebuild-web) exec scripts/web.sh build ;; esac
if [ -n "$(git ls-files '*WAVE_BREAK')" ]; then echo "broken"; exit 1; fi
echo "$1" >>"$(git rev-parse --git-dir)/stub-ran"
EOF
chmod +x "$STUB"
export MERGE_WAVE_STUB=$STUB

reset() { git checkout -q main && git reset -q --hard "$M" && git clean -qfd -e Web/node_modules; }
branch() { # name, then a command that changes the tree; commits it on a branch off main
	local name=$1; shift
	git checkout -q -b "$name" "$M"
	"$@"
	git add -A && git commit -q -m "$name"
	git checkout -q main
}
wave_of() { echo "$1" | sed -n 's/^WAVE=//p'; }
run_wave() { # every step until finish or a stop; prints the log
	local wave=$1 n=0 line
	while :; do
		line=$("$MW" next "$wave") || return 3
		echo "$line"
		case $line in step=finish*) break ;; esac
		n=$((n + 1)); [ $n -lt 40 ] || fail "wave does not converge"
		"$MW" step "$wave"
	done
	"$MW" finish "$wave"
}
on_main() { git merge-base --is-ancestor "$1" main; }

scenario_clean() {
	reset
	branch s1-app sh -c 'echo "// wave self-test" >>App/Sources/AgentsApp.swift'
	branch s1-remote sh -c 'echo "// wave self-test" >>Remote/Sources/RemoteApp.swift'
	"$MW" plan s1-app s1-remote
	out=$("$MW" start "s1-app@$(git rev-parse s1-app)" s1-remote); echo "$out"
	wave=$(wave_of "$out")
	echo "$out" | grep -q "s1-app fast-forwards" || fail "s1-app should fast-forward"
	log=$(run_wave "$wave"); echo "$log"
	echo "$log" | grep -q '^step=build-remote' || fail "Remote change should build Remote"
	echo "$log" | grep -q '^step=build-host' && fail "the fast-forwarded App change should not be rebuilt"
	echo "$log" | grep -q 'SHIP=yes' || fail "should need a ship"
	on_main s1-app && on_main s1-remote || fail "both should be on main"
	[ "$(git rev-list --merges "$M"..main | wc -l | tr -d ' ')" = 1 ] || fail "one merge commit"
	"$MW" clean "$wave"
	ok "two clean branches: one fast-forward, one merge, Remote built once, main moved"
}

scenario_web() {
	reset
	# The page source merges cleanly; its built bundle and the parity table cannot.
	scripts/web.sh build >/dev/null 2>&1 || fail "web.sh build on main"
	[ -z "$(git status --porcelain Web/dist)" ] || fail "main's Web/dist is not what its source builds"
	row() { sed -i '' "/^| Assess a runtime/a\\
| wave row $1 | #0 | lacks | has | — | — | self-test |
" specs/071-web-remote/walks/parity.md; }
	w1() { sed -i '' '1i\
console.debug("wave one");
' Web/src/main.tsx && scripts/web.sh build >/dev/null 2>&1 && row one; }
	w2() { echo 'console.debug("wave two");' >>Web/src/main.tsx && scripts/web.sh build >/dev/null 2>&1 && row two; }
	branch s2-one w1
	branch s2-two w2
	git checkout -q -b s2-base "$M" && git commit -q --allow-empty -m "main moves" && git checkout -q main
	git merge -q --ff-only s2-base && M2=$(git rev-parse main)
	"$MW" plan s2-one s2-two
	out=$("$MW" start s2-one s2-two); echo "$out"
	wave=$(wave_of "$out")
	log=$(run_wave "$wave"); echo "$log"
	echo "$log" | grep -q 'Web/dist conflicts' || echo "$out" | grep -q 'Web/dist conflicts' || fail "expected a Web/dist conflict"
	git show main:Web/src/main.tsx | grep -q 'wave one' && git show main:Web/src/main.tsx | grep -q 'wave two' || fail "both source changes"
	grep -q 'wave one' <(git show main:Web/dist/app.js) && grep -q 'wave two' <(git show main:Web/dist/app.js) ||
		fail "the rebuilt bundle has both"
	git show main:specs/071-web-remote/walks/parity.md | grep -q 'wave row one' &&
		git show main:specs/071-web-remote/walks/parity.md | grep -q 'wave row two' || fail "both parity rows"
	# The rebuilt dist is exactly what the merged source builds.
	git checkout -q main && scripts/web.sh build >/dev/null 2>&1
	[ -z "$(git status --porcelain Web/dist)" ] || fail "merged Web/dist is not what the merged source builds"
	echo "$log" | grep -q 'SHIP=yes' || fail "a Web change ships"
	[ "$(git rev-list --merges "$M2"..main | wc -l | tr -d ' ')" = 2 ] || fail "one merge commit per branch"
	"$MW" clean "$wave"
	ok "Web/dist conflict rebuilt from merged source, both parity rows kept"
}

scenario_conflict() {
	reset
	branch s3-one sh -c 'sed -i "" "1s/.*/# Agents (one)/" README.md'
	branch s3-two sh -c 'sed -i "" "1s/.*/# Agents (two)/" README.md'
	out=$("$MW" plan s3-one s3-two); echo "$out"
	echo "$out" | grep -q 'a person must settle' || fail "plan should see the conflict"
	out=$("$MW" start s3-one s3-two 2>&1) && fail "start should stop" || true
	echo "$out"
	echo "$out" | grep -q 'README.md' || fail "names the file"
	wave=$(wave_of "$out")
	"$MW" next "$wave" && fail "next should exit 3" || [ $? = 3 ] || fail "next should exit 3"
	[ "$(git rev-parse main)" = "$M" ] || fail "main must not move"
	"$MW" drop "$wave" s3-two
	out=$("$MW" finish "$wave"); echo "$out"
	echo "$out" | grep -q 's3-two .*DROPPED' || fail "summary says dropped"
	on_main s3-one || fail "s3-one on main"
	on_main s3-two && fail "s3-two must not be on main"
	"$MW" clean "$wave"
	ok "a real conflict stops the wave; dropping by hand finishes the rest"
}

scenario_bisect() {
	reset
	git checkout -q -b s4-base "$M" && git commit -q --allow-empty -m "main moves" && git checkout -q main
	git merge -q --ff-only s4-base && M4=$(git rev-parse main)
	branch s4-host sh -c 'echo "// wave self-test" >>Host/Sources/ControlKey.swift'
	branch s4-bad sh -c 'echo "// wave self-test" >>App/Sources/AgentsApp.swift && touch App/WAVE_BREAK'
	branch s4-web sh -c 'echo "<!-- wave -->" >>docs/index.md && echo "// wave self-test" >>Shared/UI/Paper.swift'
	out=$("$MW" start s4-host s4-bad s4-web); echo "$out"
	wave=$(wave_of "$out")
	log=$(run_wave "$wave"); echo "$log"
	echo "$log" | grep -q 'bisect build-host' || fail "should bisect"
	echo "$log" | grep -q 'dropped s4-bad' || fail "should drop s4-bad"
	echo "$log" | grep -q 's4-bad .*DROPPED' || fail "summary"
	on_main s4-host && on_main s4-web || fail "the good two on main"
	on_main s4-bad && fail "s4-bad must not be on main"
	[ "$(git rev-list --merges "$M4"..main | wc -l | tr -d ' ')" = 2 ] || fail "two merge commits"
	"$MW" clean "$wave"
	ok "a failing check is bisected to its branch, dropped, and the rest re-verified and merged"
}

scenario_docs() {
	reset
	git checkout -q -b s5-base "$M" && git commit -q --allow-empty -m "main moves" && git checkout -q main
	git merge -q --ff-only s5-base
	branch s5-docs sh -c 'echo "wave" >>docs/index.md'
	branch s5-spec sh -c 'mkdir -p specs/999-wave && echo wave >specs/999-wave/spec.md && echo "# x" >.agents/workflows/wave-test.md'
	out=$("$MW" start s5-docs s5-spec); echo "$out"
	wave=$(wave_of "$out")
	echo "$out" | grep -q '^step=finish' || fail "docs-only: straight to finish"
	log=$(run_wave "$wave"); echo "$log"
	echo "$log" | grep -q 'SHIP=no' || fail "no ship"
	[ ! -e "$(git -C "$wave" rev-parse --git-dir)/stub-ran" ] || fail "no step ran"
	on_main s5-docs && on_main s5-spec || fail "both on main"
	"$MW" clean "$wave"
	ok "docs-only wave: no builds, no ship"
}

scenario_reuse() {
	reset
	git checkout -q -b s6-base "$M" && git commit -q --allow-empty -m "main moves" && git checkout -q main
	git merge -q --ff-only s6-base
	branch s6-one sh -c 'echo "// wave self-test six" >>Host/Sources/ControlKey.swift'
	branch s6-two sh -c 'echo "// wave self-test six" >>Remote/Sources/RemoteApp.swift'
	out=$("$MW" start s6-one s6-two); echo "$out"
	wave=$(wave_of "$out")
	"$MW" next "$wave" | grep -q 'lease=build' || fail "the first wave builds"
	while line=$("$MW" next "$wave"); [ "${line#step=finish}" = "$line" ]; do "$MW" step "$wave" >/dev/null; done
	ran=$(wc -l <"$(git -C "$wave" rev-parse --git-dir)/stub-ran" | tr -d ' ')
	[ "$ran" -gt 0 ] || fail "the first wave ran its checks"
	"$MW" clean "$wave" --force
	# The same branches on the same main: the same tree, so nothing is built again.
	out=$("$MW" start s6-one s6-two); echo "$out"
	wave=$(wave_of "$out")
	echo "$out" | grep -q 'lease=none.*passed at this tree before' || fail "the second wave reuses the first's passes"
	log=$(run_wave "$wave"); echo "$log"
	echo "$log" | grep -q 'lease=build' && fail "nothing needs the build lease the second time"
	[ ! -e "$(git -C "$wave" rev-parse --git-dir)/stub-ran" ] || fail "no step ran the second time"
	on_main s6-one && on_main s6-two || fail "both on main"
	"$MW" clean "$wave"
	ok "a check that passed at the same tree is not run again ($ran checks reused)"
}

for s in "${@:-clean web conflict bisect docs reuse}"; do
	for one in $s; do "scenario_$one"; done
done
echo "all passed"
