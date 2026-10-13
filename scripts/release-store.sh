#!/bin/zsh
# Build the Universal app for TestFlight (#914): the Mac window (`AgentsStore`) as a .pkg and
# the Remote as an .ipa, one App Store record (Loops, Apple ID 6817621595, #659). Each archive
# passes scripts/check-store-archive.sh, is exported for App Store Connect and uploaded. Nothing
# is submitted to App Review.
#
#   scripts/release-store.sh 0.3.0 [build]          archive, check, export, upload
#   scripts/release-store.sh --no-upload 0.3.0 [b]  archive, check, export; stop before altool
#   scripts/release-store.sh --dry-run 0.3.0        archive without a certificate and check: proves
#                                                   the build and the archives' contents
#
# The build number must be new for the version on each platform (the release workflow gives
# its run number). Apart from a dry run it needs, on this Mac or the runner:
#   - the "Apple Distribution" and "3rd Party Mac Developer Installer" identities in a keychain;
#   - the four App Store profiles installed: "Agents Universal Mac App Store", "Agents Remote
#     App Store", "Agents Remote Notify App Store", "Agents Remote Widget App Store";
#   - for the upload, ASC_KEY_ID and ASC_ISSUER_ID, with the key's AuthKey_<id>.p8 where altool
#     looks (~/.private_keys or ~/.appstoreconnect/private_keys), or ASC_KEY_PATH naming it.
set -euo pipefail

root=${0:A:h:h}
dry=0 upload=1
while [[ ${1:-} == --* ]]; do
    case $1 in
        --dry-run) dry=1 upload=0 ;;
        --no-upload) upload=0 ;;
        *) print -u2 "unknown option $1"; exit 2 ;;
    esac
    shift
done
version=${1:?usage: release-store.sh [--dry-run|--no-upload] VERSION [BUILD]}
build=${2:-1}
out=$root/build/store
team=6T4RVD5724
# The Universal record. altool needs it for the Mac .pkg until the record has a macOS
# platform ("Unable to find Apple ID … on platform 'macOS App'", us8-store.md).
apple_id=6817621595
cd $root

# App Store Connect refuses a .pkg holding a file only its owner can read (90255).
umask 022
rm -rf $out
mkdir -p $out
xcodegen generate --quiet

xcodebuild=(xcodebuild)
[[ -x $root/scripts/build-cache.sh ]] && xcodebuild=($root/scripts/build-cache.sh xcodebuild)
# A dry run signs the Mac archive ad hoc, keeping its entitlements for the check, and leaves
# the iOS one unsigned, as us8-store.md's first archives were.
mac_signing=() ios_signing=()
(( dry )) && {
    mac_signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER=)
    ios_signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE_SPECIFIER=)
}

# archive SCHEME DESTINATION NAME [SETTINGS…]
archive() {
    local scheme=$1 destination=$2 name=$3
    shift 3
    print "archiving $scheme $version ($build)…"
    $xcodebuild archive -project Agents.xcodeproj -scheme $scheme -configuration Release \
        -destination $destination -archivePath $out/$name.xcarchive \
        -skipPackagePluginValidation -skipMacroValidation \
        MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$build "$@" > $out/$name-archive.log 2>&1 || {
        grep -E "error:|BUILD FAILED|ARCHIVE FAILED" $out/$name-archive.log | head -20 >&2
        print -u2 "archive of $scheme failed; the log is $out/$name-archive.log"
        exit 1
    }
    chmod -R go+rX $out/$name.xcarchive
    scripts/check-store-archive.sh $out/$name.xcarchive
}

archive AgentsStore 'generic/platform=macOS' mac $mac_signing
archive Remote 'generic/platform=iOS' ios $ios_signing
(( dry )) && { print "dry run: both archives pass check-store-archive.sh; nothing exported"; exit 0 }

# export NAME PROFILES-DICT [EXTRA-KEYS]: the ios call passes no EXTRA-KEYS, hence ${3:-} under -u (#954)
export_archive() {
    cat > $out/$1-export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>uploadSymbols</key><true/>
  <key>provisioningProfiles</key><dict>$2</dict>${3:-}
</dict></plist>
EOF
    print "exporting $1…"
    xcodebuild -exportArchive -archivePath $out/$1.xcarchive -exportPath $out/$1 \
        -exportOptionsPlist $out/$1-export.plist > $out/$1-export.log 2>&1 || {
        tail -20 $out/$1-export.log >&2
        print -u2 "export of $1 failed; the log is $out/$1-export.log"
        exit 1
    }
}

export_archive mac \
    '<key>com.alexecollins.agents.remote</key><string>Agents Universal Mac App Store</string>' \
    '<key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>'
export_archive ios \
    '<key>com.alexecollins.agents.remote</key><string>Agents Remote App Store</string>
     <key>com.alexecollins.agents.remote.notify</key><string>Agents Remote Notify App Store</string>
     <key>com.alexecollins.agents.remote.widget</key><string>Agents Remote Widget App Store</string>'

pkg=( $out/mac/*.pkg(N) )
ipa=( $out/ios/*.ipa(N) )
(( ${#pkg} == 1 && ${#ipa} == 1 )) || { print -u2 "expected one .pkg and one .ipa under $out"; exit 1 }
print "exported: ${pkg[1]:t} and ${ipa[1]:t}"
(( upload )) || exit 0

: ${ASC_KEY_ID:?ASC_KEY_ID is not set} ${ASC_ISSUER_ID:?ASC_ISSUER_ID is not set}
if [[ -n ${ASC_KEY_PATH:-} ]]; then
    keys=~/.appstoreconnect/private_keys
    mkdir -p $keys
    cp $ASC_KEY_PATH $keys/AuthKey_$ASC_KEY_ID.p8
fi
auth=(--apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID)
print "uploading the .ipa…"
xcrun altool --upload-app -f $ipa[1] -t ios $auth
print "uploading the .pkg…"
xcrun altool --upload-app -f $pkg[1] -t macos --apple-id $apple_id $auth
print "uploaded $version ($build) for iOS and macOS"
