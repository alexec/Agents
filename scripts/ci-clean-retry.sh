# Sourced by CI's build steps (#269): run a build, and when it fails on top of a restored
# cache, delete what the cache put there and run it once more from clean.
#
# A restored build graph that is not this commit's own is a warm start, and usually a good
# one, but it can leave objects the new sources no longer match: main's push run failed
# from 2026-10-02 linking AgentsKitTests with AgentsKitCore symbols undefined, on a cache
# restored from an older key. A clean rebuild of the same commit linked. So a failure
# after a restore is not trusted until a clean build has failed too; a failure with
# nothing restored is the build's own and is not repeated.
#
# Usage, in a step:
#   source scripts/ci-clean-retry.sh
#   build() { xcodebuild … && xcodebuild …; }   # chain with &&: -e is off in here
#   clean_retry "<cache-matched-key>" <folder>… -- build
clean_retry() {
	local restored=$1
	shift
	local folders=()
	while [[ $# -gt 0 && $1 != -- ]]; do
		folders+=("$1")
		shift
	done
	shift

	"$@" && return 0
	local status=$?
	if [[ -z $restored ]]; then
		return "$status"
	fi
	echo "::warning::The build failed on a cache restored from ${restored}. Deleting ${folders[*]} and building once more from clean."
	rm -rf "${folders[@]}"
	"$@"
}
