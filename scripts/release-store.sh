#!/bin/zsh
# Build the Remote for TestFlight (#914): an .ipa for the App Store record (Loops, Apple ID
# 6817621595, #659), iPhone and iPad only since the Mac is one Developer ID app (#4229). The
# archive passes scripts/check-store-archive.sh, is exported for App Store Connect and uploaded.
# Nothing is submitted to App Review.
#
#   scripts/release-store.sh 0.3.0 [build]          archive, check, export, upload
#   scripts/release-store.sh --no-upload 0.3.0 [b]  archive, check, export; stop before altool
#   scripts/release-store.sh --dry-run 0.3.0        archive without a certificate and check: proves
#                                                   the build and the archive's contents
#
# The build number must be new for the version (the release workflow gives its run number).
# Apart from a dry run it needs, on this Mac or the runner:
#   - the "Apple Distribution" identity in a keychain;
#   - the three App Store profiles installed: "Agents Remote App Store", "Agents Remote Notify
#     App Store", "Agents Remote Widget App Store", "Agents Remote Share App Store";
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
cd $root

umask 022
rm -rf $out
mkdir -p $out
xcodegen generate --quiet

xcodebuild=(xcodebuild)
[[ -x $root/scripts/build-cache.sh ]] && xcodebuild=($root/scripts/build-cache.sh xcodebuild)
# A dry run leaves the archive unsigned, as us8-store.md's first archives were.
ios_signing=()
(( dry )) && ios_signing=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE_SPECIFIER=)

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

archive Remote 'generic/platform=iOS' ios $ios_signing
(( dry )) && { print "dry run: the archive passes check-store-archive.sh; nothing exported"; exit 0 }

# export NAME PROFILES-DICT
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
  <key>provisioningProfiles</key><dict>$2</dict>
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

export_archive ios \
    '<key>com.alexecollins.agents.remote</key><string>Agents Remote App Store</string>
     <key>com.alexecollins.agents.remote.notify</key><string>Agents Remote Notify App Store</string>
     <key>com.alexecollins.agents.remote.widget</key><string>Agents Remote Widget App Store</string>
     <key>com.alexecollins.agents.remote.share</key><string>Agents Remote Share App Store</string>'

ipa=( $out/ios/*.ipa(N) )
(( ${#ipa} == 1 )) || { print -u2 "expected one .ipa under $out"; exit 1 }
print "exported: ${ipa[1]:t}"
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
print "uploaded $version ($build) for iOS"
