#!/usr/bin/env bash
# Choose conservative SwiftPM test runs from the files changed since a base commit.
#
# Package source changes run co-changed, named test suites when available, and the
# full package suite when no test suite changed alongside the source. Test-only edits
# also filter to named suites. Unrecognized changes run every package suite.
#
# The wire (#1135): Packages/Wire is the source of the wire's types. A change to it or to
# the generated files adds WireSchemaTests, which holds today's Swift encoders to the schema,
# and runs `go`, whose wiregen test holds Go/wire and Web/src/protocol/generated.ts to
# Packages/Wire; a filtered run for AgentsKitCore's source adds WireSchemaTests too.
# A change under
# Web/ alone runs AgentsKit's three suites that hold Web/ to Swift: the dist manifest, the
# ported rules' fixtures and the key vectors. CI's web job checks the rest of Web/ with Node,
# on every run. A change to App/Sources, Remote/Sources or Shared/UI runs the suites that
# scan those views (ConsistencyTests, OneGroupingTests), and one to App/Resources/toolsets
# the two that read the bundled toolsets. The MCP servers Agents ships (#700) are Go, so
# `go` runs their tests. `go` builds and tests the Go module at Go/ (#1135), on Linux, on any
# change under it; a change under Go/ alone runs no Swift suite and no macOS job. The Swift
# agentsd and agents-control, and the `linux` and `packages` jobs that built them, went in
# #1314.
#
# CI's macOS jobs are chosen here as well (#594): `apps` is skip only when every changed
# path is prose or agent config that no build reads.
#
# Usage: scripts/select-test-suites.sh <base-commit> >> "$GITHUB_OUTPUT"
set -euo pipefail

base=${1:-}
agentskit=skip
codetext=skip
go=skip
agentskit_filter=
codetext_filter=
apps=build

full_both() {
	agentskit=full
	codetext=full
	go=run
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
		web_touched=false
		views_touched=false
		wire_touched=false
		core_source_touched=false
		toolsets_touched=false
		agentskit_source_touched=false
		codetext_source_touched=false
		agentskit_full_required=false
		codetext_full_required=false
		agentskit_only_tests=true
		codetext_only_tests=true
		agentskit_suites=()
		codetext_suites=()
		apps=skip

		while IFS= read -r -d '' path; do
			case "$path" in
				docs/*|mkdocs.yml|specs/*|design/*|.agents/*|.claude/*|*.md|Go/*|Packages/Wire/*|scripts/wire.sh|scripts/pr-areas.py|scripts/replay-conflicts.py|scripts/rerun-cancelled-ci.py|scripts/lint.sh|ruff.toml|.shellcheckrc|.swiftlint.yml|Web/biome.json) ;;
				*) apps=build ;;
			esac
			case "$path" in
				# The main CI workflow defines these suites; run them when their execution changes.
				.github/workflows/ci.yml)
					unknown=true
					;;
				# The linters' own files (#1224): CI's lint job reads them, no build or test does.
				scripts/lint.sh|ruff.toml|.shellcheckrc|.swiftlint.yml|Web/biome.json)
					;;
				# Quarantine annotations and their inventory do not change test behavior.
				Packages/AgentsKit/Tests/AgentsKitTests/Support/FlakyUnderLoad.swift)
					agentskit_touched=true
					;;
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
				Packages/AgentsKit/Sources/*)
					agentskit_touched=true
					agentskit_source_touched=true
					[[ "$path" == Packages/AgentsKit/Sources/AgentsKitCore/* ]] && core_source_touched=true
					;;
				Packages/AgentsKit/*)
					agentskit_touched=true
					agentskit_full_required=true
					;;
				Packages/Wire/*|scripts/wire.sh|Web/src/protocol/generated.ts)
					go=run
					agentskit_touched=true
					if ! $wire_touched; then
						agentskit_suites+=(WireSchemaTests WebSignaturesTests)
						wire_touched=true
					fi
					if [[ "$path" == Web/* ]] && ! $web_touched; then
						agentskit_suites+=(WebDistManifestTests ControlAgreementVectorTests WebFixturesTests)
						web_touched=true
					fi
					;;
				Go/*)
					go=run
					;;
				Web/*)
					agentskit_touched=true
					if ! $web_touched; then
						agentskit_suites+=(WebDistManifestTests ControlAgreementVectorTests WebFixturesTests)
						web_touched=true
					fi
					;;
				# AgentsKit's source scans read the apps' views and the bundled toolsets from
				# disk (#475): a view edit alone must still run the scans that hold it.
				App/Sources/*|Remote/Sources/*|Shared/UI/*)
					agentskit_touched=true
					if ! $views_touched; then
						agentskit_suites+=(ConsistencyTests OneGroupingTests)
						views_touched=true
					fi
					;;
				App/Resources/toolsets/*)
					agentskit_touched=true
					if ! $toolsets_touched; then
						agentskit_suites+=(ToolsetTests ArchiveToolsetTests)
						toolsets_touched=true
					fi
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
				App/*|Host/*|Remote/*|RemoteNotify/*|RemoteWidget/*|docs/*|mkdocs.yml|specs/*|design/*|.agents/*|.claude/*|.github/workflows/*|scripts/select-test-suites.sh|scripts/check-test-indexing.py|scripts/web.sh|scripts/slow-tests.sh|scripts/flaky-tests.sh|scripts/normalize-metaltoolchain-cache.py|scripts/pr-areas.py|scripts/replay-conflicts.py|scripts/rerun-cancelled-ci.py)
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
					# A filtered run for AgentsKitCore's source also holds it to the schema.
					if $core_source_touched && ! $wire_touched; then
						agentskit_suites+=(WireSchemaTests)
					fi
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
	printf 'go=%s\n' "$go"
	printf 'apps=%s\n' "$apps"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
