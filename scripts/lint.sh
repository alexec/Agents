#!/bin/bash
# The linters (#1224): each one fast, with a fix mode, and only its bug and security rules on.
#
#   scripts/lint.sh [linter…]         lint the whole tree; every linter when none is named
#   scripts/lint.sh --fix [linter…]   run each linter's fix mode first, then lint
#   scripts/lint.sh --tools DIR TOOL…  put pinned Linux x86_64 binaries in DIR (CI): shellcheck,
#                                     ruff, golangci-lint, govulncheck (needs Go), biome, swiftlint, jscpd
#
# Linters: shell (shellcheck), zsh (zsh -n), python (ruff), go (golangci-lint), govulncheck,
# web (biome lint), swift (SwiftLint), dupes (jscpd), checks (our own text checks). Their rules are in
# .shellcheckrc, ruff.toml, Go/.golangci.yml, Web/biome.json and .swiftlint.yml.
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
# On Linux a linter on the PATH is run as it is (CI, after --tools). Otherwise, as on a Mac,
# it runs in a pinned container, so nothing is installed on the Mac: Docker must be running.
# Go's caches are Go/scripts/go.sh's, in ~/Library/Caches/Agents-build/go.
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
GO_IMAGE=golang:1.26
ZSH=5.9
NODE=$(cat Web/.node-version)

REQUIRED=" shell zsh checks "
ALL="shell zsh python go govulncheck web swift dupes checks"

if [ "${1:-}" = --tools ]; then
	dir=${2:?usage: scripts/lint.sh --tools DIR TOOL…}
	shift 2
	mkdir -p "$dir" && cd "$dir" || exit 1
	set -e
	gh=https://github.com
	for t in "$@"; do
		[ -x "$t" ] && continue
		case $t in
		shellcheck)
			curl -sSfL "$gh/koalaman/shellcheck/releases/download/v$SHELLCHECK/shellcheck-v$SHELLCHECK.linux.x86_64.tar.xz" |
				tar -xJ --strip-components=1 "shellcheck-v$SHELLCHECK/shellcheck" ;;
		ruff)
			curl -sSfL "$gh/astral-sh/ruff/releases/download/$RUFF/ruff-x86_64-unknown-linux-musl.tar.gz" |
				tar -xz --strip-components=1 ruff-x86_64-unknown-linux-musl/ruff ;;
		golangci-lint)
			curl -sSfL "$gh/golangci/golangci-lint/releases/download/v$GOLANGCI/golangci-lint-$GOLANGCI-linux-amd64.tar.gz" |
				tar -xz --strip-components=1 "golangci-lint-$GOLANGCI-linux-amd64/golangci-lint" ;;
		govulncheck) GOBIN=$PWD go install "golang.org/x/vuln/cmd/govulncheck@v$GOVULNCHECK" ;;
		biome) curl -sSfLo biome "$gh/biomejs/biome/releases/download/@biomejs/biome@$BIOME/biome-linux-x64" && chmod +x biome ;;
		swiftlint)
			curl -sSfLo swiftlint.zip "$gh/realm/SwiftLint/releases/download/$SWIFTLINT/swiftlint_linux_amd64.zip"
			unzip -qo swiftlint.zip swiftlint-static && mv swiftlint-static swiftlint && rm swiftlint.zip ;;
		jscpd)
			curl -sSfL "$gh/kucherenko/jscpd/releases/download/v$JSCPD/jscpd-linux-x64-gnu.tar.gz" |
				tar -xz --strip-components=0 jscpd ;;
		*) echo "lint.sh: no tool $t" >&2; exit 2 ;;
		esac
	done
	exit 0
fi

fix=0
[ "${1:-}" = --fix ] && { fix=1; shift; }
linters=${*:-$ALL}

docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# native NAME: run NAME as it is, on Linux with it on the PATH.
native() { [ "$(uname -s)" = Linux ] && command -v "$1" >/dev/null 2>&1; }

# tool LINTER: the program it runs; checks needs no container.
tool() {
	case $1 in
	shell) echo shellcheck ;; python) echo ruff ;; go) echo golangci-lint ;;
	web) echo biome ;; swift) echo swiftlint ;; dupes) echo jscpd ;; *) echo "$1" ;;
	esac
}

# box IMAGE CMD…: CMD in IMAGE, the repository at /repo and the working folder kept.
box() {
	local image=$1
	shift
	docker run --rm -v "$root":/repo -w "/repo${PWD#"$root"}" "$image" "$@"
}

# gobox IMAGE CMD…: as box, with Go/scripts/go.sh's caches.
gobox() {
	local image=$1 cache="${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}/go"
	shift
	mkdir -p "$cache/gopath" "$cache/gocache" "$cache/lint"
	docker run --rm -v "$root":/repo -v "$cache/gopath":/go -v "$cache/gocache":/root/.cache/go-build \
		-v "$cache/lint":/root/.cache/golangci-lint -w /repo/Go "$image" "$@"
}

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
	if native shellcheck; then
		# shellcheck disable=SC2086 # one path per line, none with spaces
		[ "$fix" = 1 ] && shellcheck -S warning -f diff $files | git apply
		# shellcheck disable=SC2086
		shellcheck -S warning -f gcc $files
	else
		# shellcheck disable=SC2086
		[ "$fix" = 1 ] && box "koalaman/shellcheck:v$SHELLCHECK" -S warning -f diff $files | git apply
		# shellcheck disable=SC2086
		box "koalaman/shellcheck:v$SHELLCHECK" -S warning -f gcc $files
	fi
}

run_zsh() {
	local f status=0
	if command -v zsh >/dev/null 2>&1; then
		for f in $(tracked zsh); do zsh -n "$f" 2>&1 || status=1; done
		return $status
	fi
	# shellcheck disable=SC2016,SC2046 # $f is the container's; one path per line, none with spaces
	box "zshusers/zsh:$ZSH" zsh -c 'rc=0; for f in "$@"; do zsh -n "$f" || rc=1; done; exit $rc' zsh $(tracked zsh)
}

run_python() {
	if native ruff; then
		[ "$fix" = 1 ] && ruff check --fix --quiet .
		ruff check --no-cache --output-format concise .
	else
		[ "$fix" = 1 ] && box "ghcr.io/astral-sh/ruff:$RUFF" check --fix --quiet .
		box "ghcr.io/astral-sh/ruff:$RUFF" check --no-cache --output-format concise .
	fi
}

run_go() {
	local args=(run --max-issues-per-linter 0 --max-same-issues 0 --show-stats=false
		--output.text.print-issued-lines=false ./...)
	[ "$fix" = 1 ] && args=("${args[@]}" --fix)
	if native golangci-lint; then
		(cd Go && golangci-lint "${args[@]}")
	else
		gobox "golangci/golangci-lint:v$GOLANGCI" golangci-lint "${args[@]}"
	fi | sed 's|^|Go/|'
	return "${PIPESTATUS[0]}"
}

run_govulncheck() {
	if native govulncheck; then
		(cd Go && govulncheck ./...)
	else
		gobox "$GO_IMAGE" go run "golang.org/x/vuln/cmd/govulncheck@v$GOVULNCHECK" ./...
	fi
}

# Biome's github reporter, turned into path:line:col: lines with the path from the root.
run_web() {
	local args=(lint --max-diagnostics=none --reporter=github)
	[ "$fix" = 1 ] && args=("${args[@]}" --write)
	cd Web || return 1
	if native biome; then
		biome "${args[@]}" .
	else
		mkdir -p "$HOME/Library/Caches/Agents-build/npm"
		docker run --rm -v "$root":/repo -v "$HOME/Library/Caches/Agents-build/npm":/root/.npm -w /repo/Web \
			"node:$NODE" npx -y --loglevel=error "@biomejs/biome@$BIOME" "${args[@]}" .
	fi 2>&1 | sed -nE 's#^::(error|warning) title=([^,]*),file=([^,]*),line=([0-9]+)[^:]*,col=([0-9]+)[^:]*::(.*)#Web/\3:\4:\5: \1: \6 (\2)#p' |
		sed -E 's#^Web/(/repo/Web/|'"$root"'/Web/|\./)?#Web/#'
	local status=${PIPESTATUS[0]}
	cd "$root" || return 1
	return "$status"
}

run_swift() {
	if native swiftlint; then
		[ "$fix" = 1 ] && swiftlint --fix --quiet
		swiftlint lint --quiet
	else
		[ "$fix" = 1 ] && box "ghcr.io/realm/swiftlint:$SWIFTLINT" --fix --quiet
		box "ghcr.io/realm/swiftlint:$SWIFTLINT" lint --quiet
	fi | sed -E "s#^(/repo/|$root/)##"
	return "${PIPESTATUS[0]}"
}

run_dupes() {
	local out log status
	out=$(mktemp -d "$root/.agents/reviews/.jscpd-lint.XXXXXX") || return 1
	log="$out/run.log"
	if native jscpd; then
		jscpd --reporters json --output "$out" >"$log" 2>&1
		status=$?
	else
		local relative_out=${out#"$root/"}
		docker run --rm -v "$root":/src -w /src \
			"ghcr.io/kucherenko/jscpd:$JSCPD" --reporters json --output "$relative_out" >"$log" 2>&1
		status=$?
	fi
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
	python3 scripts/check-store-window.py || status=1
	python3 scripts/check-store-entitlements.py || status=1
	python3 scripts/check-store-profiles.py --selftest || status=1
	python3 scripts/check-stacked-labels.py --selftest || status=1
	python3 scripts/check-stacked-labels.py || status=1
	python3 scripts/check-workflow-github-reads.py --selftest || status=1
	python3 scripts/check-workflow-github-reads.py || status=1
	python3 scripts/check-deploy-bounds.py --selftest || status=1
	python3 scripts/check-deploy-bounds.py || status=1
	python3 scripts/pr-risk.py --selftest || status=1
	python3 -m unittest discover -s .agents/skills/ship-app/scripts -p 'test_*.py' -q || status=1
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
	if [ "$linter" != checks ] && ! native "$(tool "$linter")" && ! docker_ok; then
		echo "== $linter: skipped, as it is not on the PATH and Docker is not running"
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
