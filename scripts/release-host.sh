#!/bin/zsh
# Build Agents Host for a GitHub release (#669): signed with Developer ID, notarized and
# stapled, in a .dmg and a .zip, beside the Linux agentsd as tarballs and a SHA256SUMS. The zip
# is for Macs that may not mount a disk image (#675: CyberArk, no hdiutil): unzip, then move the
# app to ~/Applications, which needs no admin rights.
#
#   scripts/release-host.sh 0.2.0 [build]        everything, into build/release/
#   scripts/release-host.sh --dry-run 0.2.0      ad-hoc signed, not notarized: proves the
#                                                build and the packaging with no certificate
#
# A release needs, on this Mac or the runner:
#   - the "Developer ID Application" identity in a keychain;
#   - the "Agents Relay Developer ID" profile installed (the relay reaches CloudKit);
#   - ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the App Store Connect key's .p8), for
#     notarytool.
# The Linux agentsd has to be in App/Resources/servers already (scripts/build-linux-agentsd.sh,
# or the release workflow's linux job): Agents Host carries it for servers, and the release
# offers it on its own for Linux hosts.
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
    [[ -f $servers/agentsd-linux-$arch && -f $servers/ci-watcher-linux-$arch ]] || {
        print -u2 "No $servers/agentsd-linux-$arch or ci-watcher-linux-$arch: run scripts/build-linux-agentsd.sh first."
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

print "archiving Agents Host $version ($build)…"
$xcodebuild archive -project Agents.xcodeproj -scheme AgentsHost -configuration Release \
    -destination 'generic/platform=macOS' -archivePath $out/AgentsHost.xcarchive \
    -skipPackagePluginValidation -skipMacroValidation \
    MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$build $signing > $out/archive.log 2>&1 || {
    grep -E "error:|BUILD FAILED|ARCHIVE FAILED" $out/archive.log | head -20 >&2
    print -u2 "archive failed; the log is $out/archive.log"
    exit 1
}

app="$out/export/Agents Host.app"
if (( dry )); then
    mkdir -p $out/export
    ditto "$out/AgentsHost.xcarchive/Products/Applications/Agents Host.app" "$app"
else
    cat > $out/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>6T4RVD5724</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict>
    <key>com.alexecollins.agents.bridge</key><string>Agents Relay Developer ID</string>
  </dict>
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
for helper in agentsd agents-control agents-relay.app ci-watcher workspace-commands; do
    [[ -e "$app/Contents/Helpers/$helper" ]] || { print -u2 "Agents Host has no Helpers/$helper"; exit 1 }
done
codesign --verify --deep --strict "$app"
print "signed: $(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

dmg=$out/Agents-Host-$version.dmg
stage=$out/dmg
mkdir -p $stage
ditto "$app" "$stage/Agents Host.app"
ln -s /Applications $stage/Applications
hdiutil create -quiet -volname "Agents Host" -srcfolder $stage -fs HFS+ -format UDZO $dmg
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
ditto -c -k --keepParent "$app" $out/Agents-Host-$version.zip

for arch in x86_64 aarch64; do
    # The MCP servers Agents ships (#700) go beside it: a Linux host puts them in its bin/.
    tar -czf $out/agentsd-linux-$arch-$version.tar.gz -C $servers agentsd-linux-$arch \
        agentsd-linux-$arch.sha256 ci-watcher-linux-$arch ci-watcher-linux-$arch.sha256 VERSION
done
(cd $out && shasum -a 256 *.dmg *.zip *.tar.gz > SHA256SUMS)
print "\n$out:"
(cd $out && ls -lh *.dmg *.zip *.tar.gz SHA256SUMS)
