#!/usr/bin/env bash
# Choose conservative SwiftPM test runs from the files changed since a base commit.
#
# Package source changes run co-changed, named test suites when available, and the
# full package suite when no test suite changed alongside the source. Test-only edits
# also filter to named suites. Unrecognized changes run both package suites.
#
# Usage: scripts/select-test-suites.sh <base-commit> >> "$GITHUB_OUTPUT"
set -euo pipefail

base=${1:-}
agentskit=skip
codetext=skip
agentskit_filter=
codetext_filter=

full_both() {
	agentskit=full
	codetext=full
	agentskit_filter=
	codetext_filter=
}

if [[ -z "$base" ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
	full_both
else
	if git diff --quiet "${base}...HEAD"; then
		# No changed paths is unusual in CI; don't turn an unexpected diff problem into
		# a green build that ran no tests.
		full_both
	else
		unknown=false
		agentskit_touched=false
		codetext_touched=false
		agentskit_source_touched=false
		codetext_source_touched=false
		agentskit_full_required=false
		codetext_full_required=false
		agentskit_only_tests=true
		codetext_only_tests=true
		agentskit_suites=()
		codetext_suites=()

		while IFS= read -r -d '' path; do
			case "$path" in
				Packages/AgentsKit/Tests/*)
					agentskit_touched=true
					name=${path##*/}
					if [[ "$name" == *Tests.swift ]]; then
						suite=${name%.swift}
						if [[ -f "$path" ]] && grep -Eq "(^|[[:space:]])(struct|class)[[:space:]]+${suite}([[:space:]<{:]|$)" "$path"; then
							agentskit_suites+=("$suite")
						else
							agentskit_only_tests=false
						fi
					else
						agentskit_only_tests=false
					fi
					;;
				Daemon/Package.swift)
					agentskit_touched=true
					agentskit_full_required=true
					;;
				Packages/AgentsKit/Sources/*|Daemon/*)
					agentskit_touched=true
					agentskit_source_touched=true
					;;
				Packages/AgentsKit/*)
					agentskit_touched=true
					agentskit_full_required=true
					;;
				Packages/CodeText/Tests/*)
					codetext_touched=true
					name=${path##*/}
					if [[ "$name" == *Tests.swift ]]; then
						suite=${name%.swift}
						if [[ -f "$path" ]] && grep -Eq "(^|[[:space:]])(struct|class)[[:space:]]+${suite}([[:space:]<{:]|$)" "$path"; then
							codetext_suites+=("$suite")
						else
							codetext_only_tests=false
						fi
					else
						codetext_only_tests=false
					fi
					;;
				Packages/CodeText/Sources/*)
					codetext_touched=true
					codetext_source_touched=true
					;;
				Packages/CodeText/*)
					codetext_touched=true
					codetext_full_required=true
					;;
				# These areas cannot affect either SwiftPM package's tests.
				App/*|Remote/*|RemoteNotify/*|Bridge/*|Shared/UI/*|docs/*|specs/*|design/*|.agents/*|.claude/*|.github/workflows/*|scripts/select-test-suites.sh|scripts/slow-tests.sh|scripts/flaky-tests.sh|scripts/normalize-metaltoolchain-cache.py)
					;;
				*)
					# Root config, CI, scripts, or a new area may change test behavior.
					unknown=true
					;;
			esac
		done < <(git diff --name-only -z "${base}...HEAD")

		if $unknown; then
			full_both
		else
			if $agentskit_touched; then
				if $agentskit_full_required; then
					agentskit=full
				elif $agentskit_source_touched && ((${#agentskit_suites[@]} > 0)); then
					agentskit=filter
				elif ! $agentskit_source_touched && $agentskit_only_tests && ((${#agentskit_suites[@]} > 0)); then
					agentskit=filter
					# SwiftPM treats --filter as a regular expression over the fully
					# qualified test identifier. Suite names here are Swift identifiers.
					agentskit_filter=$(IFS='|'; printf '%s' "${agentskit_suites[*]}")
				else
					agentskit=full
				fi
				if [[ "$agentskit" == filter ]]; then
					agentskit_filter=$(IFS='|'; printf '%s' "${agentskit_suites[*]}")
				fi
			fi
			if $codetext_touched; then
				if $codetext_full_required; then
					codetext=full
				elif $codetext_source_touched && ((${#codetext_suites[@]} > 0)); then
					codetext=filter
				elif ! $codetext_source_touched && $codetext_only_tests && ((${#codetext_suites[@]} > 0)); then
					codetext=filter
				else
					codetext=full
				fi
				if [[ "$codetext" == filter ]]; then
					codetext_filter=$(IFS='|'; printf '%s' "${codetext_suites[*]}")
				fi
			fi
		fi
	fi
fi

{
	printf 'agentskit=%s\n' "$agentskit"
	printf 'agentskit_filter=%s\n' "$agentskit_filter"
	printf 'codetext=%s\n' "$codetext"
	printf 'codetext_filter=%s\n' "$codetext_filter"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
