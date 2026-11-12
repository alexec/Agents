#!/bin/zsh
# Set up the GitHub release's `release` environment and its secrets, once (#669).
#
#   scripts/release-secrets.sh path/to/DeveloperID.p12
#
# The .p12 is the Developer ID Application identity, exported from Keychain Access (My
# Certificates ▸ Developer ID Application: … ▸ Export…). The script asks for its password.
# The App Store Connect key is read from ~/.private_keys (asc.env and the AuthKey_*.p8
# beside it).
# Nothing is written to disk; delete the .p12 afterwards.
#
#   scripts/release-secrets.sh --store path/to/Distribution.p12
#
# The TestFlight upload's secrets (#914), into the same environment: the Apple Distribution
# identity, exported from Keychain Access as a .p12, and the Remote's four installed App Store
# profiles, found by name. The Mac is not in the App Store (#4229). Run
# the plain form first: it makes the environment and sets the App Store Connect key both use.
#
#   scripts/release-secrets.sh --app-store [reviewer]
#
# The App Review gate (#3657): the `app-store` environment, for v* tags only, with the reviewer
# (the signed-in GitHub user by default) required, and the App Store Connect key from
# ~/.private_keys. Without a required reviewer app-store.yml submits nothing.
set -euo pipefail

repo=${RELEASE_REPO:-alexec/Agents}
keys=~/.private_keys
profiles=~/Library/Developer/Xcode/UserData/Provisioning\ Profiles

# The installed profile with this name, or nothing.
profile_named() {
    local f name
    for f in $profiles/*.(provisionprofile|mobileprovision)(N); do
        name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)
        [[ $name == "$1" ]] && { print -r -- $f; return }
    done
}

# set_identity SECRET FILE CERTIFICATE-NAME: the .p12 and its password, once it opens.
set_identity() {
    local password
    read -rs "password?Password for $2: "
    print
    { openssl pkcs12 -in $2 -passin "pass:$password" -nokeys -legacy 2>/dev/null ||
        openssl pkcs12 -in $2 -passin "pass:$password" -nokeys 2>/dev/null } | grep -q "$3" ||
        { print -u2 "$2 does not open with that password, or holds no $3 certificate."; exit 1 }
    base64 -i $2 | gh secret set $1 --env release -R $repo
    print -rn -- $password | gh secret set ${1}_PASSWORD --env release -R $repo
}

if [[ ${1:-} == --store ]]; then
    distribution=${2:?usage: release-secrets.sh --store Distribution.p12}
    gh api repos/$repo/environments/release --silent ||
        { print -u2 "No release environment: run release-secrets.sh with the Developer ID .p12 first."; exit 1 }
    typeset -A wanted=(
        PROFILE_REMOTE "Agents Remote App Store"
        PROFILE_REMOTE_NOTIFY "Agents Remote Notify App Store"
        PROFILE_REMOTE_WIDGET "Agents Remote Widget App Store"
        PROFILE_REMOTE_SHARE "Agents Remote Share App Store"
    )
    typeset -A found
    for secret name in ${(kv)wanted}; do
        found[$secret]=$(profile_named $name)
        [[ -n $found[$secret] ]] || { print -u2 "No installed \"$name\" profile."; exit 1 }
    done
    # The release checks the same before it archives (#2781): a stale profile stops here.
    checks=()
    for secret file in ${(kv)found}; do checks+=("$secret=$file"); done
    python3 ${0:A:h}/check-store-profiles.py $checks ||
        { print -u2 "Make the profiles above again and install them; no secret was set."; exit 1 }
    print "the App Store identity…"
    set_identity APPLE_DISTRIBUTION_P12 $distribution "Apple Distribution"
    print "the App Store profiles…"
    for secret file in ${(kv)found}; do
        base64 -i "$file" | gh secret set $secret --env release -R $repo
    done
    gh secret list --env release -R $repo
    print "Done. Delete the .p12 file. The next v* tag also uploads to TestFlight."
    exit 0
fi

p8=( $keys/AuthKey_*.p8(N) )
(( ${#p8} == 1 )) || { print -u2 "Expected one AuthKey_*.p8 in $keys."; exit 1 }
asc_key_id=$(sed -n 's/^ASC_KEY_ID=//p' $keys/asc.env)
asc_issuer_id=$(sed -n 's/^ASC_ISSUER_ID=//p' $keys/asc.env)

# set_asc ENVIRONMENT: the App Store Connect key, into that environment.
set_asc() {
    gh secret set ASC_KEY_P8 --env $1 -R $repo < $p8[1]
    print -rn -- $asc_key_id | gh secret set ASC_KEY_ID --env $1 -R $repo
    print -rn -- $asc_issuer_id | gh secret set ASC_ISSUER_ID --env $1 -R $repo
}

# tags_only ENVIRONMENT: only a v* tag reaches it.
tags_only() {
    gh api repos/$repo/environments/$1/deployment-branch-policies --jq '.branch_policies[].name' | grep -qx 'v\*' ||
        gh api -X POST repos/$repo/environments/$1/deployment-branch-policies -f name='v*' -f type=tag --silent
}

if [[ ${1:-} == --app-store ]]; then
    reviewer=${2:-$(gh api user --jq .login)}
    reviewer_id=$(gh api users/$reviewer --jq .id)
    print "the app-store environment, for v* tags only, with $reviewer required…"
    gh api -X PUT repos/$repo/environments/app-store --silent --input - <<JSON
{"reviewers":[{"type":"User","id":$reviewer_id}],"prevent_self_review":false,
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
    tags_only app-store
    print "its secrets…"
    set_asc app-store
    gh secret list --env app-store -R $repo
    print "Done. The next v* tag waits for $reviewer before it goes to App Review."
    exit 0
fi

p12=${1:?usage: release-secrets.sh path/to/DeveloperID.p12 | --store Distribution.p12 Installer.p12 | --app-store [reviewer]}

read -rs "password?Password for $p12: "
print
openssl pkcs12 -in $p12 -passin "pass:$password" -nokeys -legacy 2>/dev/null | grep -q "Developer ID Application" ||
    openssl pkcs12 -in $p12 -passin "pass:$password" -nokeys 2>/dev/null | grep -q "Developer ID Application" ||
    { print -u2 "$p12 does not open with that password, or holds no Developer ID Application certificate."; exit 1 }

print "the release environment, for v* tags only…"
gh api -X PUT repos/$repo/environments/release --silent --input - <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
tags_only release

print "its secrets…"
base64 -i $p12 | gh secret set DEVELOPER_ID_P12 --env release -R $repo
print -rn -- $password | gh secret set DEVELOPER_ID_P12_PASSWORD --env release -R $repo
set_asc release
gh secret list --env release -R $repo
print "Done. Delete $p12, then tag main to release (docs/how-to/release-agents-host.md)."
