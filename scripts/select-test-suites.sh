#!/usr/bin/env bash
# Choose conservative SwiftPM test runs from the files changed since a base commit.
#
# Package source changes run that package's full suite: there is no reliable way to
# infer source-to-test dependencies from filenames. When only conventional *Tests.swift
# files changed, run just those Swift Testing suites. Unrecognized changes run both
# suites so a new dependency or build setting cannot silently bypass tests.
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
				Packages/AgentsKit/*|Daemon/*)
					agentskit_touched=true
					agentskit_only_tests=false
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
				Packages/CodeText/*)
					codetext_touched=true
					codetext_only_tests=false
					;;
				# These areas cannot affect either SwiftPM package's tests.
				App/*|Remote/*|RemoteNotify/*|Bridge/*|Shared/UI/*|docs/*|specs/*|design/*|.agents/*|.claude/*)
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
				if $agentskit_only_tests && ((${#agentskit_suites[@]} > 0)); then
					agentskit=filter
					# SwiftPM treats --filter as a regular expression over the fully
					# qualified test identifier. Suite names here are Swift identifiers.
					agentskit_filter=$(IFS='|'; printf '%s' "${agentskit_suites[*]}")
				else
					agentskit=full
				fi
			fi
			if $codetext_touched; then
				if $codetext_only_tests && ((${#codetext_suites[@]} > 0)); then
					codetext=filter
					codetext_filter=$(IFS='|'; printf '%s' "${codetext_suites[*]}")
				else
					codetext=full
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
