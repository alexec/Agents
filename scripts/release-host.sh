#!/bin/zsh
# Build Agent Loops for a GitHub release (#669, #4225): the window and this Mac's host in one app,
# signed with Developer ID, notarized and stapled, in a .dmg and a .zip, beside the Linux agentsd
# as tarballs and a SHA256SUMS. The zip is for Macs that may not mount a disk image (#675:
# CyberArk, no hdiutil): unzip, then move the app to ~/Applications, which needs no admin rights.
#
# Agent Loops was Agents (#5297), and Agents Host before that (#4224). An Agents updates
# itself from Agents-<version>.zip and wants an Agents.app in it; an Agents Host from
# Agents-Host-<version>.zip, with an Agents Host.app. So the release also carries the same app
# under each old name; once it runs, it renames itself Agent Loops.app (agentsd, takeNewName).
#
#   scripts/release-host.sh 0.2.0 [build]        everything, into build/release/
#   scripts/release-host.sh --dry-run 0.2.0      ad-hoc signed, not notarized: proves the
#                                                build and the packaging with no certificate
#
# A release needs, on this Mac or the runner:
#   - the "Developer ID Application" identity in a keychain;
#   - ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the App Store Connect key's .p8), for
#     notarytool.
# The Linux agentsd (Go, #1136) has to be in App/Resources/servers already
# (scripts/build-linux-agentsd.sh, or the release workflow's linux job): Agent Loops carries
# it for servers, and the release offers it on its own for Linux hosts.
set -euo pipefail

root=${0:A:h:h}
dry=0
[[ ${1:-} == --dry-run ]] && { dry=1; shift }
version=${1:?usage: release-host.sh [--dry-run] VERSION [BUILD]}
build=${2:-1}
out=$root/build/release
servers=$root/App/Resources/servers
cd $root

for arch in x86_64 aarch64; do
    [[ -f $servers/agentsd-linux-$arch && -f $servers/github-mcp-linux-$arch && -f $servers/linear-mcp-linux-$arch && -f $servers/gitlab-mcp-linux-$arch && -f $servers/email-mcp-linux-$arch && -f $servers/jira-mcp-linux-$arch && -f $servers/slack-mcp-linux-$arch && -f $servers/googlechat-mcp-linux-$arch && -f $servers/whatsapp-mcp-linux-$arch && -f $servers/sentry-mcp-linux-$arch && -f $servers/betterstack-mcp-linux-$arch && -f $servers/forgejo-mcp-linux-$arch && -f $servers/bitbucket-mcp-linux-$arch && -f $servers/azuredevops-mcp-linux-$arch && -f $servers/azureboards-mcp-linux-$arch ]] || {
        print -u2 "No $servers/agentsd-linux-$arch, github-mcp-linux-$arch, linear-mcp-linux-$arch, gitlab-mcp-linux-$arch, email-mcp-linux-$arch, jira-mcp-linux-$arch, slack-mcp-linux-$arch, googlechat-mcp-linux-$arch, whatsapp-mcp-linux-$arch, sentry-mcp-linux-$arch, betterstack-mcp-linux-$arch, forgejo-mcp-linux-$arch, bitbucket-mcp-linux-$arch, azuredevops-mcp-linux-$arch or azureboards-mcp-linux-$arch: run scripts/build-linux-agentsd.sh first (with Docker or Go)."
        exit 1
    }
done

rm -rf $out
mkdir -p $out
xcodegen generate --quiet

xcodebuild=(xcodebuild)
[[ -x $root/scripts/build-cache.sh ]] && xcodebuild=($root/scripts/build-cache.sh xcodebuild)
signing=()
# A dry run signs ad hoc: no identity, no profile, so nothing restricted can be signed in.
(( dry )) && signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER=
    CODE_SIGN_ENTITLEMENTS= OTHER_CODE_SIGN_FLAGS=)

print "archiving Agent Loops $version ($build)…"
$xcodebuild archive -project Agents.xcodeproj -scheme AgentsHost -configuration Release \
    -destination 'generic/platform=macOS' -archivePath $out/AgentsHost.xcarchive \
    -skipPackagePluginValidation -skipMacroValidation \
    MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$build $signing > $out/archive.log 2>&1 || {
    grep -E "error:|BUILD FAILED|ARCHIVE FAILED" $out/archive.log | head -20 >&2
    print -u2 "archive failed; the log is $out/archive.log"
    exit 1
}

app="$out/export/Agent Loops.app"
if (( dry )); then
    mkdir -p $out/export
    ditto "$out/AgentsHost.xcarchive/Products/Applications/Agent Loops.app" "$app"
else
    cat > $out/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>6T4RVD5724</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
    xcodebuild -exportArchive -archivePath $out/AgentsHost.xcarchive -exportPath $out/export \
        -exportOptionsPlist $out/export.plist > $out/export.log 2>&1 || {
        tail -20 $out/export.log >&2
        exit 1
    }
fi

# What the bundle must hold, signed: the helpers, the MCP servers it ships (#700) and the
# Linux agentsd.
for helper in agentsd agents-control github-mcp linear-mcp gitlab-mcp email-mcp jira-mcp slack-mcp googlechat-mcp whatsapp-mcp sentry-mcp betterstack-mcp forgejo-mcp bitbucket-mcp azuredevops-mcp azureboards-mcp workspace-commands; do
    [[ -e "$app/Contents/Helpers/$helper" ]] || { print -u2 "Agent Loops has no Helpers/$helper"; exit 1 }
done
codesign --verify --deep --strict "$app"
print "signed: $(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

dmg=$out/Agent-Loops-$version.dmg
stage=$out/dmg
mkdir -p $stage
ditto "$app" "$stage/Agent Loops.app"
ln -s /Applications $stage/Applications
hdiutil create -quiet -volname "Agent Loops" -srcfolder $stage -fs HFS+ -format UDZO $dmg
rm -rf $stage

if (( ! dry )); then
    codesign --sign "Developer ID Application" --timestamp $dmg
    : ${ASC_KEY_ID:?} ${ASC_ISSUER_ID:?} ${ASC_KEY_PATH:?}
    print "notarizing $dmg…"
    xcrun notarytool submit $dmg --key $ASC_KEY_PATH --key-id $ASC_KEY_ID \
        --issuer $ASC_ISSUER_ID --wait --timeout 30m
    xcrun stapler staple $dmg
    spctl --assess --type open --context context:primary-signature --verbose $dmg
    # Notarizing the image notarized the app inside it: staple its ticket for the zip too.
    xcrun stapler staple "$app"
fi
ditto -c -k --keepParent "$app" $out/Agent-Loops-$version.zip
# For the self-update of an Agents or an Agents Host: the same app, signed and stapled, under
# each old name.
bridge=$out/bridge
for old zip in Agents Agents "Agents Host" Agents-Host; do
    mkdir -p $bridge
    ditto "$app" "$bridge/$old.app"
    ditto -c -k --keepParent "$bridge/$old.app" $out/$zip-$version.zip
    rm -rf $bridge
done

for arch in x86_64 aarch64; do
    # The MCP servers Agent Loops ships (#700) go beside it: a Linux host puts them in its bin/.
    tar -czf $out/agentsd-linux-$arch-$version.tar.gz -C $servers agentsd-linux-$arch \
        agentsd-linux-$arch.sha256 \
        github-mcp-linux-$arch github-mcp-linux-$arch.sha256 \
        linear-mcp-linux-$arch linear-mcp-linux-$arch.sha256 \
        gitlab-mcp-linux-$arch gitlab-mcp-linux-$arch.sha256 \
        email-mcp-linux-$arch email-mcp-linux-$arch.sha256 \
        jira-mcp-linux-$arch jira-mcp-linux-$arch.sha256 \
        slack-mcp-linux-$arch slack-mcp-linux-$arch.sha256 \
        googlechat-mcp-linux-$arch googlechat-mcp-linux-$arch.sha256 \
        whatsapp-mcp-linux-$arch whatsapp-mcp-linux-$arch.sha256 \
        sentry-mcp-linux-$arch sentry-mcp-linux-$arch.sha256 \
        betterstack-mcp-linux-$arch betterstack-mcp-linux-$arch.sha256 \
        forgejo-mcp-linux-$arch forgejo-mcp-linux-$arch.sha256 \
        bitbucket-mcp-linux-$arch bitbucket-mcp-linux-$arch.sha256 \
        azuredevops-mcp-linux-$arch azuredevops-mcp-linux-$arch.sha256 \
        azureboards-mcp-linux-$arch azureboards-mcp-linux-$arch.sha256 VERSION
done
(cd $out && shasum -a 256 *.dmg *.zip *.tar.gz > SHA256SUMS)
print "\n$out:"
(cd $out && ls -lh *.dmg *.zip *.tar.gz SHA256SUMS)
