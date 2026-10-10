#!/usr/bin/env bash
# Choose conservative SwiftPM test runs from the files changed since a base commit.
#
# Package source changes run co-changed, named test suites when available, and the
# full package suite when no test suite changed alongside the source. Test-only edits
# also filter to named suites. Unrecognized changes run every package suite.
#
# The web remote (071): WebTypes runs on any change to AgentsKitCore's source, to the
# generator or to Web/, so a protocol type changed in Swift without regenerating fails.
# ControlPlane runs on any change to it or to AgentsKit, which it links. A change under
# Web/ alone runs AgentsKit's three suites that hold Web/ to Swift: the dist manifest, the
# ported rules' fixtures and the key vectors. CI's web job checks the rest of Web/ with Node,
# on every run. A change to App/Sources, Remote/Sources or Shared/UI runs the suites that
# scan those views (ConsistencyTests, OneGroupingTests), and one to App/Resources/toolsets
# the two that read the bundled toolsets.
#
# CI's macOS jobs are chosen here as well (#594): `apps` is skip only when every changed
# path is prose or agent config that no build reads, and `packages` (the job that runs
# WebTypes and ControlPlane) is skip when neither of those is selected.
#
# Usage: scripts/select-test-suites.sh <base-commit> >> "$GITHUB_OUTPUT"
set -euo pipefail

base=${1:-}
agentskit=skip
codetext=skip
webtypes=skip
controlplane=skip
agentskit_filter=
codetext_filter=
apps=build

full_both() {
	agentskit=full
	codetext=full
	webtypes=run
	controlplane=run
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
				docs/*|mkdocs.yml|specs/*|design/*|.agents/*|.claude/*|*.md) ;;
				*) apps=build ;;
			esac
			case "$path" in
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
				Daemon/Package.swift)
					agentskit_touched=true
					agentskit_full_required=true
					;;
				Packages/AgentsKit/Sources/*|Daemon/*)
					agentskit_touched=true
					agentskit_source_touched=true
					controlplane=run
					[[ "$path" == Packages/AgentsKit/Sources/AgentsKitCore/* ]] && webtypes=run
					;;
				Packages/AgentsKit/*)
					agentskit_touched=true
					agentskit_full_required=true
					controlplane=run
					;;
				Packages/WebTypes/*)
					webtypes=run
					;;
				Packages/ControlPlane/*)
					controlplane=run
					;;
				Web/*)
					webtypes=run
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
				App/*|Host/*|Remote/*|RemoteNotify/*|RemoteWidget/*|docs/*|mkdocs.yml|specs/*|design/*|.agents/*|.claude/*|.github/workflows/*|scripts/select-test-suites.sh|scripts/check-agentsd-links-no-parsers.sh|scripts/web.sh|scripts/slow-tests.sh|scripts/flaky-tests.sh|scripts/normalize-metaltoolchain-cache.py)
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

# Whether the AgentsKit run needs Daemon/'s agentsd built first. Only the fake-ssh suites
# that read ServerLinkTests.agentsd run it, and a filtered run rarely names one, yet the
# build costs three to five minutes on the runner. The filter is a regular expression over
# the qualified test id, so it is matched against these suites' own ids. Keep the list to
# the suites that read ServerLinkTests.agentsd; one left out still builds it, inside its run.
agentsd=skip
if [[ "$agentskit" == full ]]; then
	agentsd=build
elif [[ "$agentskit" == filter ]]; then
	for suite in FakeSSHSuites/ServerLinkTests FakeSSHSuites/ServerConnectionTests FakeSSHSuites/ToolsetInstallTests; do
		if [[ "$suite" =~ $agentskit_filter ]]; then
			agentsd=build
		fi
	done
fi

{
	printf 'agentskit=%s\n' "$agentskit"
	printf 'agentskit_filter=%s\n' "$agentskit_filter"
	printf 'codetext=%s\n' "$codetext"
	printf 'codetext_filter=%s\n' "$codetext_filter"
	printf 'webtypes=%s\n' "$webtypes"
	printf 'controlplane=%s\n' "$controlplane"
	printf 'agentsd=%s\n' "$agentsd"
	printf 'apps=%s\n' "$apps"
	if [[ "$webtypes" == skip && "$controlplane" == skip ]]; then
		printf 'packages=skip\n'
	else
		printf 'packages=run\n'
	fi
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
