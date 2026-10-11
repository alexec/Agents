#!/bin/zsh
# Set up the GitHub release's `release` environment and its secrets, once (#669).
#
#   scripts/release-secrets.sh path/to/DeveloperID.p12
#
# The .p12 is the Developer ID Application identity, exported from Keychain Access (My
# Certificates ▸ Developer ID Application: … ▸ Export…). The script asks for its password.
# The relay's profile is the installed "Agents Relay Developer ID". The App Store Connect key
# is read from ~/.private_keys (asc.env and the AuthKey_*.p8 beside it).
# Nothing is written to disk; delete the .p12 afterwards.
set -euo pipefail

p12=${1:?usage: release-secrets.sh path/to/DeveloperID.p12}
repo=${RELEASE_REPO:-alexec/Agents}
keys=~/.private_keys

profile=
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile(N); do
    name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)
    [[ $name == "Agents Relay Developer ID" ]] && { profile=$f; break }
done
[[ -n $profile ]] || { print -u2 "No installed \"Agents Relay Developer ID\" profile."; exit 1 }
p8=( $keys/AuthKey_*.p8(N) )
(( ${#p8} == 1 )) || { print -u2 "Expected one AuthKey_*.p8 in $keys."; exit 1 }
asc_key_id=$(sed -n 's/^ASC_KEY_ID=//p' $keys/asc.env)
asc_issuer_id=$(sed -n 's/^ASC_ISSUER_ID=//p' $keys/asc.env)

read -rs "password?Password for $p12: "
print
openssl pkcs12 -in $p12 -passin "pass:$password" -nokeys -legacy 2>/dev/null | grep -q "Developer ID Application" ||
    openssl pkcs12 -in $p12 -passin "pass:$password" -nokeys 2>/dev/null | grep -q "Developer ID Application" ||
    { print -u2 "$p12 does not open with that password, or holds no Developer ID Application certificate."; exit 1 }

print "the release environment, for v* tags only…"
gh api -X PUT repos/$repo/environments/release --silent --input - <<<'{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
gh api repos/$repo/environments/release/deployment-branch-policies --jq '.branch_policies[].name' | grep -qx 'v\*' ||
    gh api -X POST repos/$repo/environments/release/deployment-branch-policies -f name='v*' -f type=tag --silent

print "its secrets…"
base64 -i $p12 | gh secret set DEVELOPER_ID_P12 --env release -R $repo
print -rn -- $password | gh secret set DEVELOPER_ID_P12_PASSWORD --env release -R $repo
base64 -i "$profile" | gh secret set RELAY_PROFILE --env release -R $repo
gh secret set ASC_KEY_P8 --env release -R $repo < $p8[1]
print -rn -- $asc_key_id | gh secret set ASC_KEY_ID --env release -R $repo
print -rn -- $asc_issuer_id | gh secret set ASC_ISSUER_ID --env release -R $repo
gh secret list --env release -R $repo
print "Done. Delete $p12, then tag main to release (docs/how-to/release-agents-host.md)."
