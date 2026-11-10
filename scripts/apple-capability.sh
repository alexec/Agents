#!/usr/bin/env bash
# Turn on an App ID capability and make its provisioning profiles again (#4284), through the
# App Store Connect API, in one step:
#
#   scripts/apple-capability.sh BUNDLE-ID CAPABILITY [options]
#
# It finds the App ID (or registers it), turns on the capability, makes each profile of the App ID
# that the change made invalid again (same name, type, certificates and devices), makes the
# profiles that --profile names, and installs them in ~/Library/Developer/Xcode/UserData/
# Provisioning Profiles. It first prints what it would change, then asks for "yes" on its input.
#
#   --dry-run                 print what it would change, and change nothing
#   --platform mac|ios|universal
#                             the platform of an App ID it registers (default: mac)
#   --name NAME               the name of an App ID it registers (default: the bundle id)
#   --profile TYPE:NAME       also make (or remake) this profile, e.g.
#                             --profile "MAC_APP_DIRECT:Agents Developer ID"
#                             --profile "MAC_APP_DEVELOPMENT:Agents Development" (this Mac as device)
#
# CAPABILITY is App Store Connect's capabilityType (APPLE_ID_AUTH, PUSH_NOTIFICATIONS,
# APP_GROUPS, …) or a short name: sign-in-with-apple, push, app-groups, associated-domains,
# icloud. Sign in with Apple is turned on with this App ID as its own primary App ID.
#
# A real run changes Alex's Apple Developer account, and it deletes the invalid profiles that it
# makes again: a lane runs --dry-run, shows its output to Alex in a form (ask_question), and runs
# it for real only after Alex approves that form, with the answer on its input:
#
#   print yes | scripts/apple-capability.sh com.alexecollins.agents.host sign-in-with-apple …
#
# The key is ~/.private_keys/asc.env and the AuthKey_<id>.p8 beside it, as for
# scripts/release-secrets.sh (or ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH). The script never
# prints it. Exit 0: done, or nothing to change; 1: declined, or App Store Connect refused;
# 2: a usage or key problem.
set -euo pipefail
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
	exit 0
fi
exec swift "$(dirname "$0")/apple-capability.swift" "$@"
