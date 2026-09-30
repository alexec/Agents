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
# the sandbox, network client, audio input and user-selected read-only files, plus the
# identifiers signing adds.

set -euo pipefail
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
  expected=(
    application-identifier com.apple.application-identifier com.apple.developer.team-identifier
    com.apple.security.app-sandbox com.apple.security.device.audio-input
    com.apple.security.files.user-selected.read-only com.apple.security.network.client
    com.apple.security.get-task-allow keychain-access-groups
  )
  # get-task-allow is a development signature's; an App Store export removes it.
  keys=( ${(f)"$(codesign -d --entitlements :- $app 2>/dev/null | plutil -convert json -o - - | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))')"} )
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
