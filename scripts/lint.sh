#!/bin/bash
# The linters (#1224): each one fast, with a fix mode, and only its bug and security rules on.
#
#   scripts/lint.sh [linter…]         lint the whole tree; with none named, every linter (on a
#                                     Mac, those for the branch's files: below)
#   scripts/lint.sh --all             every linter, on a Mac too
#   scripts/lint.sh --fix [linter…]   run each linter's fix mode first, then lint
#   scripts/lint.sh --tools DIR TOOL…  put the pinned binaries in DIR (CI): shellcheck, ruff,
#                                     golangci-lint, govulncheck (needs Go), biome, swiftlint, jscpd;
#                                     Linux x86_64 on Linux, macOS arm64 on a Mac
#
# Linters: shell (shellcheck), zsh (zsh -n), python (ruff), go (golangci-lint), govulncheck,
# web (biome lint), swift (SwiftLint), dupes (jscpd), checks (our own text checks). Their rules are in
# .shellcheckrc, ruff.toml, Go/.golangci.yml, Web/biome.json and .swiftlint.yml.
#
# On a Mac (not CI) with no linter named, only the linters for the files the branch changes
# since its merge base with origin/main, committed or not, run (#4710): go and govulncheck for
# Go/ or Packages/Wire/, swift for *.swift or .swiftlint.yml, web for Web/, python for *.py or
# ruff.toml, shell and zsh for a shell file or .shellcheckrc; checks and dupes always. A change
# to this script runs every one. It says which it skipped. CI runs every linter.
#
# A linter is "required" or "report". A required one is clean on main, and a finding fails
# this script. A report one prints its findings and exits 0: its old findings are listed in
# .agents/reviews/lint-2026-10-17.md, to be fixed per language before it is made required.
# With LINT_BASE set (CI: the pull request's base), a report linter also says which of its
# findings are in the files changed since LINT_BASE.
#
# go (golangci-lint) is one run (#2162). unused and ineffassign are required: a finding
# from them fails this script and CI's lint job. errcheck, gosec, staticcheck and govet
# only report. One run, not a second with only those two: the second would load every
# package again, which is the slow part even when the cache is warm.
#
# Every linter runs on the host, never in a container (#4709). On Linux a linter on the PATH
# is run as it is (CI, after --tools). On a Mac each one is the pinned macOS binary in
# ~/Library/Caches/Agents-build/lint-tools/<tool>-<version>/, which lint.sh gets with
# --tools the first time; govulncheck is built with the Mac's Go, and zsh is the Mac's own.
# Go's caches are Go/scripts/go.sh's, in ~/Library/Caches/Agents-build/go; golangci-lint's is
# go/lint there. On a Mac, golangci-lint and govulncheck read the Go files as CI's lint job
# does: GOOS=linux, GOARCH=amd64, cgo off.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 1

SHELLCHECK=0.11.0
RUFF=0.17.1
GOLANGCI=2.15.0
GOVULNCHECK=1.9.0
BIOME=2.5.15
SWIFTLINT=0.65.1
JSCPD=5.4.2
ZSH=5.9
CACHE=${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}

REQUIRED=" shell zsh checks "
ALL="shell zsh python go govulncheck web swift dupes checks"

if [ "${1:-}" = --tools ]; then
	dir=${2:?usage: scripts/lint.sh --tools DIR TOOL…}
	shift 2
	mkdir -p "$dir" && cd "$dir" || exit 1
	set -e
	gh=https://github.com
	mac=0
	[ "$(uname -s)" = Darwin ] && mac=1
	for t in "$@"; do
		[ -x "$t" ] && continue
		case $t in
		shellcheck)
			a=linux.x86_64; [ $mac = 1 ] && a=darwin.aarch64
			curl -sSfL "$gh/koalaman/shellcheck/releases/download/v$SHELLCHECK/shellcheck-v$SHELLCHECK.$a.tar.xz" |
				tar -xJ --strip-components=1 "shellcheck-v$SHELLCHECK/shellcheck" ;;
		ruff)
			a=x86_64-unknown-linux-musl; [ $mac = 1 ] && a=aarch64-apple-darwin
			curl -sSfL "$gh/astral-sh/ruff/releases/download/$RUFF/ruff-$a.tar.gz" |
				tar -xz --strip-components=1 "ruff-$a/ruff" ;;
		golangci-lint)
			a=linux-amd64; [ $mac = 1 ] && a=darwin-arm64
			curl -sSfL "$gh/golangci/golangci-lint/releases/download/v$GOLANGCI/golangci-lint-$GOLANGCI-$a.tar.gz" |
				tar -xz --strip-components=1 "golangci-lint-$GOLANGCI-$a/golangci-lint" ;;
		govulncheck) GOBIN=$PWD "$root/Go/scripts/go.sh" install "golang.org/x/vuln/cmd/govulncheck@v$GOVULNCHECK" ;;
		biome)
			a=linux-x64; [ $mac = 1 ] && a=darwin-arm64
			curl -sSfLo biome "$gh/biomejs/biome/releases/download/@biomejs/biome@$BIOME/biome-$a" && chmod +x biome ;;
		swiftlint)
			if [ $mac = 1 ]; then
				curl -sSfLo swiftlint.zip "$gh/realm/SwiftLint/releases/download/$SWIFTLINT/portable_swiftlint.zip"
				unzip -qo swiftlint.zip swiftlint && rm swiftlint.zip
			else
				curl -sSfLo swiftlint.zip "$gh/realm/SwiftLint/releases/download/$SWIFTLINT/swiftlint_linux_amd64.zip"
				unzip -qo swiftlint.zip swiftlint-static && mv swiftlint-static swiftlint && rm swiftlint.zip
			fi ;;
		jscpd)
			a=linux-x64-gnu; [ $mac = 1 ] && a=darwin-arm64
			curl -sSfL "$gh/kucherenko/jscpd/releases/download/v$JSCPD/jscpd-$a.tar.gz" |
				tar -xz --strip-components=0 jscpd ;;
		*) echo "lint.sh: no tool $t" >&2; exit 2 ;;
		esac
	done
	exit 0
fi

fix=0
all=0
while [ $# -gt 0 ]; do
	case $1 in
	--fix) fix=1 ;;
	--all) all=1 ;;
	*) break ;;
	esac
	shift
done

# changed_linters: the linters for the files this branch changes since its merge base with
# origin/main, committed or not; every one when that cannot be told or this script changed.
changed_linters() {
	local base f line want=" checks dupes " l out=
	base=$(git merge-base origin/main HEAD 2>/dev/null) || { echo "$ALL"; return; }
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		case $f in
		scripts/lint.sh) echo "$ALL"; return ;;
		Go/* | Packages/Wire/*) want="$want go govulncheck " ;;
		esac
		case $f in
		*.swift | .swiftlint.yml) want="$want swift " ;;
		Web/*) want="$want web " ;;
		*.py | ruff.toml) want="$want python " ;;
		*.sh | *.bash | *.zsh | .shellcheckrc) want="$want shell zsh " ;;
		*)
			# An executable script with no extension: its first line says sh or zsh.
			if [ -f "$f" ] && [ -x "$f" ]; then
				IFS= read -r line <"$f" || line=
				case $line in '#!'*sh*) want="$want shell zsh " ;; esac
			fi ;;
		esac
	done < <({ git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)
	for l in $ALL; do
		case "$want" in *" $l "*) out="$out $l" ;; esac
	done
	echo "${out# }"
}

if [ $# -gt 0 ]; then
	linters=$*
elif [ "$all" = 0 ] && [ "$(uname -s)" = Darwin ] && [ -z "${CI:-}" ]; then
	linters=$(changed_linters)
	skipped=
	for l in $ALL; do
		case " $linters " in *" $l "*) ;; *) skipped="$skipped $l" ;; esac
	done
	[ -n "$skipped" ] && echo "lint.sh: only the linters for this branch's files ($linters); skipped:$skipped. --all runs every one."
else
	linters=$ALL
fi

# tool LINTER: the program it runs; zsh and checks need none of ours.
tool() {
	case $1 in
	shell) echo shellcheck ;; python) echo ruff ;; go) echo golangci-lint ;;
	web) echo biome ;; swift) echo swiftlint ;; dupes) echo jscpd ;; govulncheck) echo govulncheck ;;
	*) ;;
	esac
}

# version TOOL: the version this script pins.
version() {
	case $1 in
	shellcheck) echo "$SHELLCHECK" ;; ruff) echo "$RUFF" ;; golangci-lint) echo "$GOLANGCI" ;;
	govulncheck) echo "$GOVULNCHECK" ;; biome) echo "$BIOME" ;; swiftlint) echo "$SWIFTLINT" ;;
	jscpd) echo "$JSCPD" ;;
	esac
}

# have TOOL: make TOOL runnable. On Linux it is on the PATH (CI). On a Mac it is the pinned
# binary in the cache, got the first time, its folder put first on the PATH.
have() {
	[ -n "$1" ] || return 0
	if [ "$(uname -s)" != Darwin ]; then
		command -v "$1" >/dev/null 2>&1
		return
	fi
	local dir tmp
	dir="$CACHE/lint-tools/$1-$(version "$1")"
	if [ ! -x "$dir/$1" ]; then
		echo "== getting $1 $(version "$1") into $dir"
		# Got beside it, then renamed: two lanes may get it at once.
		mkdir -p "$dir" && tmp=$(mktemp -d "$CACHE/lint-tools/.get.XXXXXX") || return 1
		"$root/scripts/lint.sh" --tools "$tmp" "$1" >&2 && mv -f "$tmp/$1" "$dir/$1"
		rm -rf "$tmp"
		[ -x "$dir/$1" ] || return 1
	fi
	touch "$dir" # scripts/build-cache.sh prune takes a version not used in a week
	case ":$PATH:" in *":$dir:"*) ;; *) PATH="$dir:$PATH" ;; esac
}

# Go's caches on a Mac: Go/scripts/go.sh's, and golangci-lint's beside them.
if [ "$(uname -s)" = Darwin ] && [ -z "${CI:-}" ]; then
	mkdir -p "$CACHE/go/gopath" "$CACHE/go/gocache" "$CACHE/go/lint"
	export GOPATH="${GOPATH:-$CACHE/go/gopath}" GOMODCACHE="${GOMODCACHE:-$CACHE/go/gopath/pkg/mod}" \
		GOCACHE="${GOCACHE:-$CACHE/go/gocache}" GOLANGCI_LINT_CACHE="${GOLANGCI_LINT_CACHE:-$CACHE/go/lint}" \
		GOTOOLCHAIN="${GOTOOLCHAIN:-go$(awk '$1 == "go" { print $2; exit }' Go/go.mod)}" # as Go/scripts/go.sh
	PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
	# The files CI's lint job reads, on Linux: not the _darwin.go ones in their place.
	golinux=(env GOOS=linux GOARCH=amd64 CGO_ENABLED=0)
else
	golinux=()
fi

# tracked FILTER: tracked files whose first line (or name) says FILTER: sh or zsh.
tracked() {
	git ls-files -z | while IFS= read -r -d '' f; do
		[ -f "$f" ] || continue
		case "$f" in
		.specify/*) continue ;;                  # spec-kit's own scripts, vendored
		*/Tests/*/Samples/*) continue ;;          # CodeText's highlighting samples
		*.sh | *.bash | *.zsh) ;;
		*) [ -x "$f" ] || continue ;;
		esac
		IFS= read -r line <"$f" || line=
		case "$line" in
		*zsh*) kind="zsh" ;;
		*bash* | */sh*) kind="sh" ;;
		'#!'*) continue ;;
		*) case "$f" in *.sh) kind="sh" ;; *) continue ;; esac ;;
		esac
		[ "$kind" = "$1" ] && printf '%s\n' "$f"
	done
}

run_shell() {
	local files
	files=$(tracked sh)
	# shellcheck disable=SC2086 # one path per line, none with spaces
	[ "$fix" = 1 ] && shellcheck -S warning -f diff $files | git apply
	# shellcheck disable=SC2086
	shellcheck -S warning -f gcc $files
}

run_zsh() {
	local f status=0
	if command -v zsh >/dev/null 2>&1; then
		for f in $(tracked zsh); do zsh -n "$f" 2>&1 || status=1; done
		return $status
	fi
	# CI's Linux runner has no zsh: the pinned zsh container there. A Mac has zsh.
	[ "$(uname -s)" = Linux ] && command -v docker >/dev/null 2>&1 ||
		{ echo "lint.sh: no zsh on the PATH" >&2; return 1; }
	# shellcheck disable=SC2016,SC2046 # $f is the container's; one path per line, none with spaces
	docker run --rm -v "$root":/repo -w /repo "zshusers/zsh:$ZSH" \
		zsh -c 'rc=0; for f in "$@"; do zsh -n "$f" || rc=1; done; exit $rc' zsh $(tracked zsh)
}

run_python() {
	[ "$fix" = 1 ] && ruff check --fix --quiet .
	ruff check --no-cache --output-format concise .
}

run_go() {
	local args=(run --max-issues-per-linter 0 --max-same-issues 0 --show-stats=false
		--output.text.print-issued-lines=false ./...)
	[ "$fix" = 1 ] && args=("${args[@]}" --fix)
	(cd Go && ${golinux[@]+"${golinux[@]}"} golangci-lint "${args[@]}") | sed 's|^|Go/|'
	return "${PIPESTATUS[0]}"
}

run_govulncheck() {
	(cd Go && ${golinux[@]+"${golinux[@]}"} govulncheck ./...)
}

# Biome's github reporter, turned into path:line:col: lines with the path from the root.
run_web() {
	local args=(lint --max-diagnostics=none --reporter=github)
	[ "$fix" = 1 ] && args=("${args[@]}" --write)
	cd Web || return 1
	biome "${args[@]}" . 2>&1 | sed -nE 's#^::(error|warning) title=([^,]*),file=([^,]*),line=([0-9]+)[^:]*,col=([0-9]+)[^:]*::(.*)#Web/\3:\4:\5: \1: \6 (\2)#p' |
		sed -E 's#^Web/(/repo/Web/|'"$root"'/Web/|\./)?#Web/#'
	local status=${PIPESTATUS[0]}
	cd "$root" || return 1
	return "$status"
}

run_swift() {
	[ "$fix" = 1 ] && swiftlint --fix --quiet
	swiftlint lint --quiet | sed -E "s#^(/repo/|$root/)##"
	return "${PIPESTATUS[0]}"
}

run_dupes() {
	local out log status
	out=$(mktemp -d "$root/.agents/reviews/.jscpd-lint.XXXXXX") || return 1
	log="$out/run.log"
	jscpd --reporters json --output "$out" >"$log" 2>&1
	status=$?
	if [ -f "$out/jscpd-report.json" ]; then
		python3 scripts/jscpd-report.py "$out/jscpd-report.json"
	else
		cat "$log"
	fi
	rm -rf "$out"
	return "$status"
}

# Our own checks that read only text, and so run anywhere: the rest need a build.
run_checks() {
	local status=0
	python3 scripts/check-test-indexing.py --selftest || status=1
	python3 scripts/check-test-indexing.py || status=1
	python3 scripts/check-window-defaults.py || status=1
	python3 scripts/check-store-profiles.py --selftest || status=1
	python3 scripts/check-stacked-labels.py --selftest || status=1
	python3 scripts/check-stacked-labels.py || status=1
	python3 scripts/check-approval-words.py --selftest || status=1
	python3 scripts/check-approval-words.py || status=1
	python3 scripts/check-workflow-github-reads.py --selftest || status=1
	python3 scripts/check-workflow-github-reads.py || status=1
	python3 scripts/check-deploy-bounds.py --selftest || status=1
	python3 scripts/check-deploy-bounds.py || status=1
	python3 scripts/wire-compat.py --selftest || status=1
	sh scripts/design.sh selftest || status=1
	sh scripts/design.sh check || status=1
	python3 scripts/check-colour-tokens.py --selftest || status=1
	python3 scripts/check-colour-tokens.py || status=1
	python3 -m unittest discover -s .agents/skills/ship-app/scripts -p 'test_*.py' -q || status=1
	python3 .agents/skills/run-app/scripts/place.py --selftest || status=1
	sh scripts/version.sh --selftest || status=1
	bash scripts/build-cache-test.sh || status=1
	python3 .agents/skills/release/scripts/capability-changes.py --selftest || status=1
	python3 .agents/skills/release/scripts/release-plan.py --selftest || status=1
	python3 .agents/skills/release/scripts/advisory.py --selftest || status=1
	return $status
}

summary=${GITHUB_STEP_SUMMARY:-/dev/null}
changed=$(mktemp)
trap 'rm -f "$changed"' EXIT
[ -n "${LINT_BASE:-}" ] && git diff --name-only "$LINT_BASE"...HEAD >"$changed" 2>/dev/null
failed=
printf '| Linter | Mode | Findings | In changed files | Seconds |\n|---|---|---|---|---|\n' >>"$summary"
for linter in $linters; do
	case " $ALL " in *" $linter "*) ;; *)
		echo "lint.sh: no linter $linter (one of: $ALL)" >&2
		exit 2
		;;
	esac
	mode=report
	case "$REQUIRED" in *" $linter "*) mode=required ;; esac
	# unused and ineffassign fail; the rest of this one run only reports (#2162).
	[ "$linter" = go ] && mode="unused, ineffassign required"
	if ! have "$(tool "$linter")"; then
		echo "== $linter: skipped, as $(tool "$linter") is not on the PATH and could not be got"
		continue
	fi
	echo "== $linter ($mode)"
	out=$(mktemp)
	start=$(date +%s)
	"run_$linter" >"$out" 2>&1
	status=$?
	took=$(($(date +%s) - start))
	cat "$out"
	if [ "$linter" = govulncheck ]; then
		count=$(grep -c '^Vulnerability #' "$out")
	else
		count=$(grep -cE '^[^:[:space:]]+:[0-9]+(:[0-9]+)?: ' "$out")
	fi
	raw=$count
	[ "$status" != 0 ] && [ "$count" = 0 ] && count="failed ($status)"
	# Lines whose linter, in the trailing parentheses, is one that fails the script.
	go_required=
	if [ "$linter" = go ]; then
		go_required=$(grep -E ' \((unused|ineffassign)\)$' "$out" || true)
	fi
	mine=-
	if [ -s "$changed" ] && [ "$linter" != govulncheck ]; then
		# The findings whose path, before its first colon, this branch changed.
		mine=$(awk -F: 'NR == FNR { c[$0] = 1; next } /^[^:[:space:]]+:[0-9]+/ && ($1 in c)' "$changed" "$out")
		if [ -n "$mine" ]; then
			echo "-- $linter: in the files this branch changes:"
			printf '%s\n' "$mine"
			mine=$(printf '%s\n' "$mine" | wc -l | tr -d ' ')
		else
			mine=0
		fi
	fi
	rm -f "$out"
	printf '| %s | %s | %s | %s | %s |\n' "$linter" "$mode" "$count" "$mine" "$took" >>"$summary"
	echo "-- $linter: $count finding(s), ${took}s, exit $status"
	if [ "$linter" = go ]; then
		if [ -n "$go_required" ]; then
			echo "-- go: unused and ineffassign are required:"
			printf '%s\n' "$go_required"
			failed="$failed go"
		elif [ "$status" != 0 ] && [ "$raw" = 0 ]; then
			# The run did not finish, so those two rules were not checked.
			failed="$failed go"
		fi
	fi
	[ "$mode" = required ] && [ "$status" != 0 ] && failed="$failed $linter"
done

if [ -n "$failed" ]; then
	echo "lint.sh: required linters failed:$failed (scripts/lint.sh --fix fixes what it can)" >&2
	exit 1
fi
