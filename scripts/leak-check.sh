#!/bin/zsh
# Look for a credential everywhere it must not be (043, SC-003).
#
#   ./scripts/leak-check.sh <root> [ssh-destination …]
#
# Reads the credential from stdin (never an argument, which `ps` would show), then searches:
#   - the app's root (<root>: agents, transcripts, logs, hosts.json, credentials.json)
#   - this Mac's preferences for the app, and its crash reports
#   - the unified log for the last day
#   - each server's home, over ssh
# Prints each place it is found and exits 1; prints "clean" and exits 0 when it is nowhere.
# Only a short stretch from the middle of it is searched for, and never printed.
set -uo pipefail

root=${1:?root, e.g. /tmp/run-043}
shift
print -n "credential: " >&2
read -rs secret
print >&2
[[ ${#secret} -ge 20 ]] || { print -u2 "that is too short to be a credential"; exit 2; }
needle=${secret:12:16}
found=0

hit() { print "FOUND in $1"; found=1; }

grep -rlF -- "$needle" "$root" 2>/dev/null | while read -r f; do hit "$f"; done
for f in ~/Library/Preferences/*gents*.plist; do
  [[ -f $f ]] && plutil -convert xml1 -o - "$f" 2>/dev/null | grep -qF -- "$needle" && hit "$f"
done
grep -rlF -- "$needle" ~/Library/Logs/DiagnosticReports 2>/dev/null | while read -r f; do hit "$f"; done
/usr/bin/log show --last 1d --info --predicate 'process CONTAINS "gents"' 2>/dev/null | grep -qF -- "$needle" \
  && hit "the unified log"
for server in "$@"; do
  printf '%s' "$needle" | ssh -o BatchMode=yes -- "$server" \
    'n=$(cat); grep -rlF -- "$n" "$HOME" /tmp 2>/dev/null; true' | while read -r f; do hit "$server:$f"; done
done

(( found )) || print clean
exit $found
