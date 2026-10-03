#!/usr/bin/env bash
# sed over a variable reads more plainly here than ${var//}; the filters are quoted for bash -c.
# shellcheck disable=SC2001,SC2016
# Merge a wave of ready lane branches into main: together, in one scratch worktree,
# verified once on the combined tip by the paths they change, and main fast-forwarded
# once at the end (#150).
#
#   merge-wave.sh plan BRANCH[@SHA]...     what a wave would do; touches nothing (also --dry-run)
#   merge-wave.sh start BRANCH[@SHA]...    make the wave worktree, merge what needs no build
#   merge-wave.sh next WAVE                the next step, and whether it needs the "build" lease
#   merge-wave.sh step WAVE [NAME]         run that step (NAME, if given, must be the next one)
#   merge-wave.sh finish WAVE              fast-forward main, prove every branch is on it
#   merge-wave.sh status WAVE              one line per branch, so far
#   merge-wave.sh clean WAVE               remove the wave's own worktree and branch
#
# BRANCH@SHA pins the sha the lane verified: the wave refuses a branch that has moved past it.
#
# The script cannot lease anything itself, so it never builds unasked: `next` names the
# step and the lease it wants, and the agent runs `step` inside that lease. A step is one
# build, one test run, or one bisect probe. `next` prints, on one line:
#   step=<name> lease=<build|none> minutes=<n>  <what it does>
# and exits 0 while there is something to do, 3 when the wave has stopped for a person.
#
# MERGE_WAVE_STUB=<executable>, for proving the plumbing: every build step runs
# `<stub> <step>` in the wave worktree instead of its real command.
set -euo pipefail

me=$(basename "$0")
die() { echo "$me: $*" >&2; exit 1; }
say() { echo "$me: $*"; }

# The main checkout is the one that owns the git directory, wherever this is run from.
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die "run me inside the repository"
MAIN=$(dirname "$common")

# --- what a set of paths needs --------------------------------------------------------

# Each check is a name, a lease size in minutes and a command run in the wave worktree.
XFLAGS="-skipPackagePluginValidation -skipMacroValidation"
check_minutes() {
	case $1 in
	build-host | build-store) echo 30 ;;
	build-remote) echo 30 ;;
	web) echo 10 ;;
	test-*) echo 30 ;;
	smoke) echo 30 ;;
	*) echo 15 ;;
	esac
}
check_command() { # name [filter]
	case $1 in
	# build/DD, as run-app's launch.sh builds, so the smoke check after them is incremental.
	build-host) echo "xcodegen generate >/dev/null && xcodebuild -scheme AgentsHost -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DD $XFLAGS build" ;;
	build-store) echo "xcodegen generate >/dev/null && xcodebuild -scheme AgentsStore -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DD $XFLAGS build" ;;
	build-remote) echo "xcodegen generate >/dev/null && xcodebuild -scheme Remote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DD-sim $XFLAGS build" ;;
	# What CI's web job runs: check, tests, and a rebuild that must change nothing.
	web) echo "scripts/web.sh build && git diff --exit-code --stat -- Web/dist Web/src/protocol/generated.ts && cd Web && npm run check && npm test" ;;
	test-agentskit) echo "swift test --package-path Packages/AgentsKit${2:+ --filter '$2'}" ;;
	test-codetext) echo "swift test --package-path Packages/CodeText${2:+ --filter '$2'}" ;;
	test-controlplane) echo "swift test --package-path Packages/ControlPlane" ;;
	test-webtypes) echo "swift test --package-path Packages/WebTypes" ;;
	smoke) echo "smoke" ;;
	*) die "no check called $1" ;;
	esac
}

# Paths on stdin; the Xcode builds and the web check they need, one per line.
builds_for_paths() {
	local host=0 remote=0 web=0 p
	while IFS= read -r p; do
		case $p in
		App/* | Host/* | Daemon/* | Packages/ControlPlane/* | Packages/WebTypes/*) host=1 ;;
		Packages/* | Shared/* | project.yml) host=1 remote=1 ;;
		Remote/* | RemoteNotify/* | RemoteWidget/*) remote=1 ;;
		Web/*) web=1 ;;
		esac
	done
	if [ $host = 1 ]; then echo build-host; echo build-store; fi
	if [ $remote = 1 ]; then echo build-remote; fi
	if [ $web = 1 ]; then echo web; fi
}

# Paths on stdin; yes when any of them reaches the apps, the hosts or the page.
shippable() {
	grep -Eq '^(App|Host|Daemon|Packages|Shared|Remote|RemoteNotify|RemoteWidget|Web)/|^project\.yml$' && echo yes || echo no
}

# The swift test runs CI would choose for base...HEAD, as "name filter" lines.
tests_since() { # dir base
	local out
	out=$(cd "$1" && GITHUB_OUTPUT=/dev/stdout bash scripts/select-test-suites.sh "$2")
	val() { echo "$out" | sed -n "s/^$1=//p"; }
	[ "$(val agentskit)" = skip ] || echo "test-agentskit $(val agentskit_filter)"
	[ "$(val codetext)" = skip ] || echo "test-codetext $(val codetext_filter)"
	[ "$(val controlplane)" = skip ] || echo "test-controlplane"
	[ "$(val webtypes)" = skip ] || echo "test-webtypes"
}

# --- reading branches -------------------------------------------------------------------

# "name sha" for BRANCH[@SHA], refusing a branch that moved past the verified sha.
resolve() {
	local arg=$1 name pin tip
	name=${arg%@*}
	pin=
	[ "$name" = "$arg" ] || pin=${arg##*@}
	tip=$(git rev-parse --verify -q "refs/heads/$name^{commit}") || die "no branch $name"
	if [ -n "$pin" ]; then
		pin=$(git rev-parse --verify -q "$pin^{commit}") || die "$name: no commit $pin"
		[ "$pin" = "$tip" ] || die "$name moved since it was verified: verified ${pin:0:10}, now ${tip:0:10}. Ask its lane, then pin the new sha."
	fi
	echo "$name $tip"
}

# Conflicted paths a wave settles itself: the web page's build and the parity table.
is_web_generated() { case $1 in Web/dist/* | Web/src/protocol/generated.ts) return 0 ;; *) return 1 ;; esac; }
PARITY=specs/071-web-remote/walks/parity.md

# --- plan -------------------------------------------------------------------------------

plan() {
	[ $# -gt 0 ] || die "name the lane branches"
	local main ff='' arg name sha
	main=$(git rev-parse main)
	local resolved=()
	for arg in "$@"; do resolved+=("$(resolve "$arg")"); done
	echo "main ${main:0:10}"
	for arg in "${resolved[@]}"; do
		read -r name sha <<<"$arg"
		if [ -z "$ff" ] && git merge-base --is-ancestor "$main" "$sha"; then ff=$name; fi
	done

	# The merges, simulated with merge-tree: commit objects only, no ref or file touched.
	local tip=$main paths="" tree status conflicts c kind
	if [ -n "$ff" ]; then
		for arg in "${resolved[@]}"; do read -r name sha <<<"$arg"; [ "$name" = "$ff" ] && tip=$sha; done
	fi
	for arg in "${resolved[@]}"; do
		read -r name sha <<<"$arg"
		if [ "$name" = "$ff" ]; then
			echo "  $name ${sha:0:10}: fast-forwards from main; verified at its tip, so no build"
			continue
		fi
		git merge-base --is-ancestor "$main" "$sha" || echo "  note: $name is not rebased onto current main"
		status=0
		tree=$(git merge-tree --write-tree --name-only --no-messages "$tip" "$sha") || status=$?
		[ $status -le 1 ] || die "merge-tree failed on $name"
		if [ $status = 1 ]; then
			conflicts=$(echo "$tree" | sed 1d | sed '/^$/d')
			kind=settled
			while IFS= read -r c; do
				is_web_generated "$c" || [ "$c" = "$PARITY" ] || kind=stops
			done <<<"$conflicts"
			if [ $kind = stops ]; then
				echo "  $name ${sha:0:10}: merges with a conflict a person must settle:"
				echo "$conflicts" | sed 's/^/      /'
				echo "    (the wave stops there; the branches after it are planned as if it were left out)"
				continue
			fi
			echo "  $name ${sha:0:10}: merges; rebuilds Web/dist or keeps both parity rows for:"
			echo "$conflicts" | sed 's/^/      /'
			tree=$(echo "$tree" | head -1)
		else
			echo "  $name ${sha:0:10}: merges cleanly"
		fi
		paths+=$(git diff --name-only "$tip" "$tree")$'\n'
		tip=$(git commit-tree "$tree" -p "$tip" -p "$sha" -m "plan")
	done
	echo "checks on the combined tip:"
	local checks
	checks=$(printf '%s' "$paths" | sed '/^$/d' | builds_for_paths)
	if [ -n "$checks" ]; then echo "$checks" | sed 's/^/  /'; else echo "  no builds"; fi
	echo "  and the swift tests scripts/select-test-suites.sh picks for them, once merged"
	local all
	all=$(git diff --name-only "$main" "$tip")
	echo "ship after: $(echo "$all" | shippable)"
}

# --- the wave's state -------------------------------------------------------------------
# A directory beside the wave worktree's own git directory: plain files, one fact each.

wave_open() {
	WAVE=$(cd "${1:?name the wave worktree}" && pwd)
	ST=$(git -C "$WAVE" rev-parse --path-format=absolute --git-dir)/merge-wave
	[ -d "$ST" ] || die "$WAVE is not a wave"
	WBRANCH=$(cat "$ST/branch")
}
g() { git -C "$WAVE" "$@"; }
lines() { [ -s "$ST/$1" ] && cat "$ST/$1" || true; }
pop_pending() { sed 1d "$ST/pending" >"$ST/pending.new" && mv "$ST/pending.new" "$ST/pending"; }

start() {
	[ $# -gt 0 ] || die "name the lane branches"
	[ "$(git -C "$MAIN" branch --show-current)" = main ] || die "the main checkout $MAIN is not on main"
	local main stamp ff='' ffsha='' name sha arg resolved=()
	main=$(git rev-parse main)
	for arg in "$@"; do resolved+=("$(resolve "$arg")"); done
	for arg in "${resolved[@]}"; do
		read -r name sha <<<"$arg"
		if [ -z "$ff" ] && git merge-base --is-ancestor "$main" "$sha"; then ff=$name ffsha=$sha; fi
	done
	stamp=$(date +%Y%m%d-%H%M%S)
	WAVE=/tmp/wave-$stamp
	WBRANCH=lead/wave-$stamp
	git worktree add -q -b "$WBRANCH" "$WAVE" "${ffsha:-$main}"
	ST=$(git -C "$WAVE" rev-parse --path-format=absolute --git-dir)/merge-wave
	mkdir -p "$ST"
	echo "$WBRANCH" >"$ST/branch"
	echo "$main" >"$ST/main"
	g rev-parse HEAD >"$ST/base"
	: >"$ST/pending"
	: >"$ST/merged"
	: >"$ST/dropped"
	for arg in "${resolved[@]}"; do
		echo "$arg" >>"$ST/branches"
		read -r name sha <<<"$arg"
		[ "$name" = "$ff" ] || echo "$arg" >>"$ST/pending"
	done
	echo "${ff:+$ff $ffsha}" >"$ST/ff"
	echo "WAVE=$WAVE"
	[ -z "$ff" ] || say "$ff fast-forwards from main: the wave starts at its verified tip"
	merge_pending
	next
}

# Merge the pending branches in order until one needs a build or a person.
merge_pending() {
	local name sha
	while [ -s "$ST/pending" ]; do
		read -r name sha <"$ST/pending"
		if g merge --no-ff -q -m "Merge branch '$name' into $WBRANCH" "$sha" >"$ST/merge.log" 2>&1; then
			echo "$name $sha $(g rev-parse HEAD)" >>"$ST/merged"
			pop_pending
			say "merged $name"
			continue
		fi
		settle "$name" "$sha" || return 0
	done
	[ -s "$ST/checks" ] || plan_checks
}

# A merge stopped on conflicts: keep both parity rows; leave Web/dist for a rebuild step;
# anything else stops the wave. Returns 1 when the merge is still open.
settle() {
	local name=$1 sha=$2 c web=0 other=""
	while IFS= read -r c; do
		[ -n "$c" ] || continue
		if [ "$c" = "$PARITY" ]; then
			keep_both "$c"
		elif is_web_generated "$c"; then
			web=1
		else
			other+="$c"$'\n'
		fi
	done < <(g diff --name-only --diff-filter=U)
	if [ -n "$other" ]; then
		{
			echo "$name: conflicts that need judgement:"
			printf '%s' "$other" | sed 's/^/  /'
			echo "Settle them in $WAVE and commit the merge, then run: $me resume $WAVE"
			echo "Or leave $name out: $me drop $WAVE $name"
		} | tee "$ST/stopped" >&2
		return 1
	fi
	if [ $web = 1 ]; then
		echo "$name $sha" >"$ST/rebuild"
		say "$name: Web/dist conflicts; rebuilt from the merged source in the next step"
		return 1
	fi
	g commit -q --no-edit
	echo "$name $sha $(g rev-parse HEAD)" >>"$ST/merged"
	pop_pending
	say "merged $name (kept both sides' rows in $PARITY)"
}

keep_both() { # path: the union of both sides, as git's union merge driver would
	local f=$1 tmp
	tmp=$(mktemp -d)
	g show ":1:$f" >"$tmp/base" 2>/dev/null || : >"$tmp/base"
	g show ":2:$f" >"$tmp/ours"
	g show ":3:$f" >"$tmp/theirs"
	git merge-file --union "$tmp/ours" "$tmp/base" "$tmp/theirs" || true
	cp "$tmp/ours" "$WAVE/$f"
	rm -rf "$tmp"
	g add -- "$f"
}

# The checks for what the merged branches brought, from scratch.
plan_checks() {
	local base m paths
	base=$(cat "$ST/base")
	paths=$(g diff --name-only "$base" HEAD)
	: >"$ST/checks"
	if [ -z "$(lines merged)" ]; then return; fi
	{
		echo "$paths" | builds_for_paths
		tests_since "$WAVE" "$base"
	} | while read -r name filter; do
		echo "$name todo" >>"$ST/checks"
		check_command "$name" "$filter" >"$ST/cmd.$name"
	done
	if [ "$(echo "$paths" | shippable)" = yes ] && grep -q '^build-host ' "$ST/checks"; then
		echo "smoke todo" >>"$ST/checks"
		echo smoke >"$ST/cmd.smoke"
	fi
	m=$(cut -d' ' -f1 "$ST/checks" | tr '\n' ' ')
	say "checks: ${m:-none}"
}

# --- next and step ----------------------------------------------------------------------

# Prints the next step's line; sets NEXT, NEXT_LEASE.
decide() {
	NEXT='' NEXT_LEASE=none NEXT_MIN=0 NEXT_WHAT=''
	if [ -s "$ST/finished" ]; then
		NEXT="done" NEXT_WHAT="main is fast-forwarded; see $me status $WAVE"
		return
	fi
	if [ -s "$ST/stopped" ]; then
		NEXT=stopped NEXT_WHAT="stopped for a person: $(head -1 "$ST/stopped")"
		return
	fi
	if [ -s "$ST/rebuild" ]; then
		NEXT=rebuild-web NEXT_LEASE=build NEXT_MIN=15 NEXT_WHAT="rebuild Web/dist from the merged source of $(cut -d' ' -f1 "$ST/rebuild")"
		return
	fi
	if [ -s "$ST/pending" ]; then
		NEXT=merge NEXT_WHAT="merge $(cut -d' ' -f1 "$ST/pending" | tr '\n' ' ')"
		return
	fi
	if [ -s "$ST/bisect" ]; then
		local check lo hi probe
		read -r check lo hi <"$ST/bisect"
		probe=$(bisect_probe "$lo" "$hi")
		NEXT=bisect NEXT_LEASE=build NEXT_MIN=$(check_minutes "$check")
		NEXT_WHAT="bisect $check: try it at $(probe_name "$probe")"
		return
	fi
	local name state
	while read -r name state; do
		if [ "$state" = todo ] || [ "$state" = again ]; then
			NEXT=$name NEXT_LEASE=build NEXT_MIN=$(check_minutes "$name")
			NEXT_WHAT=$(cat "$ST/cmd.$name")
			[ "$state" = todo ] || NEXT_WHAT="once more, as tests flake under load: $NEXT_WHAT"
			return
		fi
	done < <(lines checks)
	NEXT=finish NEXT_WHAT="every check passed: $me finish $WAVE"
}

next() {
	decide
	echo "step=$NEXT lease=$NEXT_LEASE minutes=$NEXT_MIN  $NEXT_WHAT"
	[ "$NEXT" != stopped ] || exit 3
}

run_logged() { # name command: in the wave worktree, log in the state dir
	local name=$1 cmd=$2 log="$ST/log.$1"
	say "$name: $cmd"
	say "  log $log"
	if [ -n "${MERGE_WAVE_STUB:-}" ]; then
		(cd "$WAVE" && "$MERGE_WAVE_STUB" "$name") >"$log" 2>&1
	elif [ "$cmd" = smoke ]; then
		(cd "$WAVE" && smoke) >"$log" 2>&1
	else
		(cd "$WAVE" && bash -c "$cmd") >"$log" 2>&1
	fi
}

# The run-app smoke check: the wave's own scratch host, control plane and window, the
# socket answering, a screenshot, then stopped.
smoke() {
	# Called where errexit is off (inside an if), so every failure returns by hand.
	local S=.agents/skills/run-app/scripts slug ROOT='' ok=0 launched
	slug=w$(basename "$WAVE" | tr -cd 0-9 | tail -c 7)
	launched=$($S/launch.sh --slug "$slug") || { echo "launch.sh failed"; return 1; }
	eval "$launched"
	[ -n "$ROOT" ] || { echo "launch.sh printed no ROOT"; return 1; }
	if $S/rpc.py "$ROOT" call daemon/ping && $S/rpc.py "$ROOT" call agents/list '{"includeArchived":false}'; then
		ok=1
		sleep 5
		$S/shot.sh "$ROOT" "$ROOT-smoke.png" && echo "screenshot: $ROOT-smoke.png" ||
			echo "no screenshot (locked?); the socket answered"
	fi
	$S/stop.sh "$ROOT"
	[ $ok = 1 ]
}

step() {
	decide
	[ -z "${1:-}" ] || [ "$1" = "$NEXT" ] || die "the next step is $NEXT, not $1"
	case $NEXT in
	stopped) cat "$ST/stopped" >&2; exit 3 ;;
	finish) say "nothing left to run: $me finish $WAVE"; return ;;
	merge) merge_pending ;;
	rebuild-web) rebuild_web ;;
	bisect) bisect_step ;;
	*)
		if run_logged "$NEXT" "$(cat "$ST/cmd.$NEXT")"; then
			mark "$NEXT" pass
			say "$NEXT passed"
		else
			say "$NEXT FAILED; last lines:"
			tail -15 "$ST/log.$NEXT" | sed 's/^/  /'
			# The test suites flake under load: one more run before a branch is blamed.
			if case $NEXT in test-*) true ;; *) false ;; esac && grep -q "^$NEXT todo$" "$ST/checks"; then
				mark "$NEXT" again
			else
				mark "$NEXT" fail
				start_bisect "$NEXT"
			fi
		fi
		;;
	esac
	next
}

mark() { sed "s/^$1 .*/$1 $2/" "$ST/checks" >"$ST/checks.new" && mv "$ST/checks.new" "$ST/checks"; }

rebuild_web() {
	local name sha c types=0
	read -r name sha <"$ST/rebuild"
	while IFS= read -r c; do
		[ "$c" = Web/src/protocol/generated.ts ] && types=1
		g checkout -q --ours -- "$c" 2>/dev/null || g rm -q --cached -- "$c"
	done < <(g diff --name-only --diff-filter=U)
	local cmd="scripts/web.sh build"
	[ $types = 0 ] || cmd="scripts/web.sh types && $cmd"
	if ! run_logged rebuild-web "$cmd"; then
		tail -15 "$ST/log.rebuild-web" | sed 's/^/  /' >&2
		echo "rebuild-web failed for $name; the merge is still open in $WAVE" | tee "$ST/stopped" >&2
		exit 3
	fi
	g add -A -- Web/dist Web/src/protocol/generated.ts
	[ -z "$(g diff --name-only --diff-filter=U)" ] || die "conflicts left after the rebuild"
	g commit -q --no-edit
	echo "$name $sha $(g rev-parse HEAD)" >>"$ST/merged"
	pop_pending
	rm -f "$ST/rebuild"
	say "merged $name with Web/dist rebuilt from the merged source"
	merge_pending
}

# --- bisect -----------------------------------------------------------------------------
# Over the wave's merge commits, 0-based in merged; -1 is the wave's base. lo is known
# good, hi known bad. When hi is 0 and the base is untested, the base is tried first, so a
# failure main already had is not pinned on the first branch.

start_bisect() {
	local check=$1 n
	n=$(lines merged | wc -l | tr -d ' ')
	echo "$check -2 $((n - 1))" >"$ST/bisect"
	bisect_settle
}

bisect_probe() { # lo hi -> the index to try
	local lo=$1 hi=$2
	if [ "$lo" = -2 ]; then
		[ "$hi" = 0 ] && echo -1 || echo $(((hi - 1) / 2))
	else
		echo $(((lo + hi) / 2))
	fi
}
probe_name() {
	[ "$1" = -1 ] && echo "the wave's base" || echo "the merge of $(sed -n "$(($1 + 1))p" "$ST/merged" | cut -d' ' -f1)"
}
probe_sha() {
	if [ "$1" = -1 ]; then cat "$ST/base"; else sed -n "$(($1 + 1))p" "$ST/merged" | cut -d' ' -f3; fi
}

bisect_step() {
	local check lo hi probe ok=0
	read -r check lo hi <"$ST/bisect"
	probe=$(bisect_probe "$lo" "$hi")
	g checkout -q --detach "$(probe_sha "$probe")"
	run_logged "$check" "$(cat "$ST/cmd.$check")" && ok=1
	g checkout -q "$WBRANCH"
	if [ $ok = 1 ]; then
		say "$check passes at $(probe_name "$probe")"
		lo=$probe
	else
		say "$check fails at $(probe_name "$probe")"
		if [ "$probe" = -1 ]; then
			echo "$check fails at the wave's base too: main (or the branch it fast-forwarded to) is broken, not a merged branch. Log $ST/log.$check" | tee "$ST/stopped" >&2
			rm -f "$ST/bisect"
			exit 3
		fi
		hi=$probe
	fi
	echo "$check $lo $hi" >"$ST/bisect"
	bisect_settle
}

# Once lo and hi touch, hi is the branch at fault: drop it, merge the rest again.
bisect_settle() {
	local check lo hi culprit
	read -r check lo hi <"$ST/bisect"
	[ "$lo" != -2 ] && [ $((hi - lo)) = 1 ] || return 0
	culprit=$(sed -n "$((hi + 1))p" "$ST/merged" | cut -d' ' -f1)
	rm -f "$ST/bisect"
	cp "$ST/log.$check" "$ST/log.$check.$culprit"
	drop "$culprit" "fails $check (log $ST/log.$check.$culprit)"
}

# Leave a branch out: back to just before its merge, and the ones after it merged again.
drop() {
	local name=$1 why=$2 i=0 n before='' line lname lsha keep=() redo=()
	n=$(lines merged | wc -l | tr -d ' ')
	while IFS= read -r line; do
		i=$((i + 1))
		read -r lname lsha _ <<<"$line"
		if [ "$lname" = "$name" ]; then before=$i; continue; fi
		if [ -z "$before" ]; then keep+=("$line"); else redo+=("$lname $lsha"); fi
	done < <(lines merged)
	[ -n "$before" ] || die "$name is not merged in this wave"
	if [ "$before" = 1 ]; then g reset -q --hard "$(cat "$ST/base")"; else g reset -q --hard "$(sed -n "$((before - 1))p" "$ST/merged" | cut -d' ' -f3)"; fi
	printf '%s\n' "${keep[@]+"${keep[@]}"}" | sed '/^$/d' >"$ST/merged"
	{ printf '%s\n' "${redo[@]+"${redo[@]}"}" | sed '/^$/d'; lines pending; } >"$ST/pending.new"
	mv "$ST/pending.new" "$ST/pending"
	echo "$name $why" >>"$ST/dropped"
	rm -f "$ST/checks" "$ST"/cmd.*
	say "dropped $name: $why"
	merge_pending
}

# By hand, after a stop: a person settled and committed the merge, or leaves the branch out.
resume() {
	wave_open "$1"
	[ -s "$ST/stopped" ] || die "the wave has not stopped"
	if [ -n "$(g diff --name-only --diff-filter=U)" ] || g rev-parse -q --verify MERGE_HEAD >/dev/null; then
		die "the merge in $WAVE is still open: settle and commit it first"
	fi
	local name sha
	if [ -s "$ST/pending" ]; then
		read -r name sha <"$ST/pending"
		g merge-base --is-ancestor "$sha" HEAD || die "$name is not merged yet"
		echo "$name $sha $(g rev-parse HEAD)" >>"$ST/merged"
		pop_pending
	fi
	rm -f "$ST/stopped"
	rm -f "$ST/checks" "$ST"/cmd.*
	merge_pending
	next
}
drop_cmd() {
	wave_open "$1"
	local name=$2 sha
	if [ -s "$ST/pending" ] && [ "$(head -1 "$ST/pending" | cut -d' ' -f1)" = "$name" ]; then
		g merge --abort 2>/dev/null || g reset -q --hard HEAD
		read -r name sha <"$ST/pending"
		pop_pending
		echo "$name left out by hand" >>"$ST/dropped"
		rm -f "$ST/stopped" "$ST/rebuild" "$ST/checks" "$ST"/cmd.*
		say "dropped $name"
		merge_pending
	else
		rm -f "$ST/stopped"
		drop "$name" "left out by hand"
	fi
	next
}

# --- finish -----------------------------------------------------------------------------

finish() {
	decide
	[ "$NEXT" = finish ] || die "not finished: next is $NEXT"
	[ -z "$(g status --porcelain --untracked-files=no)" ] || die "the wave worktree has uncommitted changes"
	[ "$(git -C "$MAIN" branch --show-current)" = main ] || die "the main checkout $MAIN is not on main"
	local main
	main=$(git rev-parse main)
	if ! git merge-base --is-ancestor "$main" "$WBRANCH"; then
		die "main moved since the wave began (was $(cut -c1-10 "$ST/main"), now ${main:0:10}): start a new wave with the same branches"
	fi
	if [ "$main" = "$(g rev-parse HEAD)" ]; then
		say "main is already at the wave's tip"
	else
		git -C "$MAIN" merge --ff-only -q "$WBRANCH"
	fi
	local name sha bad=0
	while read -r name sha; do
		grep -q "^$name " "$ST/dropped" && continue
		if git merge-base --is-ancestor "$sha" main; then :; else echo "NOT ON MAIN: $name ${sha:0:10}" >&2; bad=1; fi
	done <"$ST/branches"
	[ $bad = 0 ] || die "a branch is missing from main"
	echo "done" >"$ST/finished"
	summary
}

summary() {
	local name sha m line verify main ship
	main=$(git rev-parse main)
	echo "wave $WBRANCH  main ${main:0:10}"
	verify=$(lines checks | awk '{printf "%s%s:%s", (NR>1?" ":""), $1, $2}')
	while read -r name sha; do
		if line=$(grep "^$name " "$ST/dropped"); then
			echo "  $name ${sha:0:10}: DROPPED, ${line#"$name "}"
		elif [ "$(cut -d' ' -f1 "$ST/ff")" = "$name" ]; then
			echo "  $name ${sha:0:10}: fast-forward, verified by its lane"
		elif m=$(grep "^$name " "$ST/merged"); then
			m=$(echo "$m" | cut -d' ' -f3)
			echo "  $name ${sha:0:10}: merged as ${m:0:10}, ${verify:-no checks needed}"
		else
			echo "  $name ${sha:0:10}: not merged yet"
		fi
	done <"$ST/branches"
	if [ -s "$ST/finished" ]; then
		ship=$(git diff --name-only "$(cat "$ST/main")" main | shippable)
		echo "SHIP=$ship"
		if [ "$ship" = yes ]; then
			echo "  something shippable changed: nohup .agents/skills/ship-app/scripts/ship.sh, once, under the build lease"
		else
			echo "  nothing shippable changed: no ship"
		fi
	fi
}

clean() {
	wave_open "$1"
	[ -s "$ST/finished" ] || [ "${2:-}" = --force ] || die "the wave is not finished (add --force to throw it away)"
	git worktree remove --force "$WAVE"
	git branch -q -D "$WBRANCH"
	say "removed $WAVE and $WBRANCH"
}

case ${1:-} in
plan | --dry-run) shift; plan "$@" ;;
start) shift; start "$@" ;;
next) wave_open "${2:-}"; next ;;
step) wave_open "${2:-}"; step "${3:-}" ;;
resume) resume "${2:-}" ;;
drop) [ $# = 3 ] || die "usage: $me drop WAVE BRANCH"; drop_cmd "$2" "$3" ;;
finish) wave_open "${2:-}"; finish ;;
status) wave_open "${2:-}"; summary; next ;;
clean) clean "${2:-}" "${3:-}" ;;
*)
	sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
