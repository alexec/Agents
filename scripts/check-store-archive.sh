#!/bin/zsh
# An App Store archive holds the app and nothing that runs beside it (058, T090).
#
#   scripts/check-store-archive.sh path/to/Some.xcarchive
#
# Lists every Mach-O in the archive's app and fails on any that is not one of:
#   - the app's own executable;
#   - an app extension's executable (PlugIns/*.appex), the Remote's notification extension;
#   - a framework or dylib under Frameworks/ (the Swift runtime, when it is copied in).
# A helper in Contents/Helpers, a tool in Resources, a daemon anywhere: each is a failure,
# because the sandboxed window reaches every host through the control plane and runs nothing.
#
# For a Mac archive it also checks the app's entitlements are T044's list and no more:
# the sandbox, network client, audio input and user-selected read-write files (Export…, #2302), plus the
# identifiers signing adds, and one app group (#1118, #1546): 6T4RVD5724.com.alexecollins.agents,
# where agentsd's socket for the window is. A team-prefixed group needs no registration on
# macOS, and the Mac App Store profile allows 6T4RVD5724.*. Any other group is a failure.
#
# For a Mac archive every file must be readable by everyone: App Store Connect refuses an
# installer package holding one only its owner can read (90255), which a shell with umask
# 077 leaves in _CodeSignature.
#
# scripts/check-store-entitlements.py checks App/Agents-Store.entitlements against the same
# list, so a pull request fails on a new entitlement before a release's archive does (#2498).

set -euo pipefail
expected=(
  application-identifier com.apple.application-identifier com.apple.developer.team-identifier
  com.apple.security.app-sandbox com.apple.security.device.audio-input
  com.apple.security.files.user-selected.read-write com.apple.security.network.client
  com.apple.security.get-task-allow keychain-access-groups
  com.apple.security.application-groups com.apple.developer.applesignin
)

archive=${1:?usage: check-store-archive.sh path/to/Some.xcarchive}
[[ -d $archive/Products ]] || { print -u2 "$archive is not an archive (no Products)"; exit 2 }

apps=( $archive/Products/Applications/*.app(N) )
(( ${#apps} == 1 )) || { print -u2 "expected one app in $archive/Products/Applications, found ${#apps}"; exit 2 }
app=$apps[1]
mac=0
[[ -d $app/Contents ]] && mac=1

if (( mac )); then
  executable=$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' $app/Contents/Info.plist)
else
  executable=$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' $app/Info.plist)
fi

failures=0
count=0
while IFS= read -r -d '' file; do
  # Mach-O by magic: thin 32/64-bit either way round, and universal.
  magic=$(xxd -p -l 4 "$file" 2>/dev/null || true)
  case $magic in
    feedfacf|cffaedfe|feedface|cefaedfe|cafebabe|bebafeca) ;;
    *) continue ;;
  esac
  count=$(( count + 1 ))
  relative=${file#$app/}
  if [[ $file == $executable ]]; then
    print "ok  $relative (the app)"
  elif [[ $relative == PlugIns/*.appex/* || $relative == Contents/PlugIns/*.appex/* ]]; then
    appex=${relative%%.appex/*}.appex
    info=$app/$appex/Info.plist
    [[ -f $info ]] || info=$app/$appex/Contents/Info.plist
    own=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' $info 2>/dev/null || true)
    if [[ ${file:t} == $own ]]; then
      print "ok  $relative (an extension)"
    else
      print "BAD $relative (inside an extension, not its executable)"
      failures=$(( failures + 1 ))
    fi
  elif [[ $relative == Frameworks/* || $relative == Contents/Frameworks/* ]]; then
    print "ok  $relative (a framework)"
  else
    print "BAD $relative (runs beside the app)"
    failures=$(( failures + 1 ))
  fi
done < <(find $app -type f -print0)
print "$count Mach-O files"

if (( mac )); then
  while IFS= read -r -d '' file; do
    print "BAD ${file#$app/} (not readable by everyone; archive with umask 022)"
    failures=$(( failures + 1 ))
  done < <(find $app ! -perm -o+r -print0)
fi

if (( mac )); then
  # The only app group the window may join: the one it shares with Agents Host (#1118).
  groups_allowed=( 6T4RVD5724.com.alexecollins.agents )
  # get-task-allow is a development signature's; an App Store export removes it.
  entitlements=$(codesign -d --entitlements :- $app 2>/dev/null | plutil -convert json -o - -)
  keys=( ${(f)"$(print -r -- $entitlements | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))')"} )
  groups=( ${(f)"$(print -r -- $entitlements | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("com.apple.security.application-groups", [])))')"} )
  for group in $groups; do
    if (( ${groups_allowed[(Ie)$group]} )); then
      print "ok  app group $group"
    else
      print "BAD app group $group (only ${groups_allowed[*]} is allowed)"
      failures=$(( failures + 1 ))
    fi
  done
  for key in $keys; do
    if (( ${expected[(Ie)$key]} )); then
      print "ok  entitlement $key"
    else
      print "BAD entitlement $key (not in T044's list)"
      failures=$(( failures + 1 ))
    fi
  done
  for required in com.apple.security.app-sandbox com.apple.security.network.client; do
    (( ${keys[(Ie)$required]} )) || { print "BAD entitlement $required missing"; failures=$(( failures + 1 )) }
  done
fi

if (( failures )); then
  print -u2 "$failures problem(s): this archive would carry more than the app"
  exit 1
fi
print "The archive holds the app and nothing that runs beside it."
