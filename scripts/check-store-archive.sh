#!/bin/zsh
# An App Store archive holds the app and nothing that runs beside it (058, T090).
#
#   scripts/check-store-archive.sh path/to/Some.xcarchive
#
# Lists every Mach-O in the archive's app and fails on any that is not one of:
#   - the app's own executable;
#   - an app extension's executable (PlugIns/*.appex), the Remote's notification extension;
#   - a framework or dylib under Frameworks/ (the Swift runtime, when it is copied in).
# A helper, a tool in the bundle, a daemon anywhere: each is a failure, because the Remote
# reaches every host through the control plane and runs nothing. The App Store has only the
# Remote since the Mac became one Developer ID app (#4229).

set -euo pipefail

archive=${1:?usage: check-store-archive.sh path/to/Some.xcarchive}
[[ -d $archive/Products ]] || { print -u2 "$archive is not an archive (no Products)"; exit 2 }

apps=( $archive/Products/Applications/*.app(N) )
(( ${#apps} == 1 )) || { print -u2 "expected one app in $archive/Products/Applications, found ${#apps}"; exit 2 }
app=$apps[1]
executable=$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' $app/Info.plist)

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
  elif [[ $relative == PlugIns/*.appex/* ]]; then
    appex=${relative%%.appex/*}.appex
    info=$app/$appex/Info.plist
    own=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' $info 2>/dev/null || true)
    if [[ ${file:t} == $own ]]; then
      print "ok  $relative (an extension)"
    else
      print "BAD $relative (inside an extension, not its executable)"
      failures=$(( failures + 1 ))
    fi
  elif [[ $relative == Frameworks/* ]]; then
    print "ok  $relative (a framework)"
  else
    print "BAD $relative (runs beside the app)"
    failures=$(( failures + 1 ))
  fi
done < <(find $app -type f -print0)
print "$count Mach-O files"

if (( failures )); then
  print -u2 "$failures problem(s): this archive would carry more than the app"
  exit 1
fi
print "The archive holds the app and nothing that runs beside it."
