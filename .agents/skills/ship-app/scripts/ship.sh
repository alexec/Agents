#!/bin/zsh
# Build main, install the Remote on Alex's paired iPhone/iPad, and relaunch the
# real Mac app (window, daemon, bridge) on the new build.
#
#   ship.sh                 everything
#   ship.sh --no-build      reuse build/DD and build/DD-ios as they are
#   ship.sh --no-devices    skip the iPhone/iPad
#   ship.sh --no-mac        skip the Mac relaunch
#   ship.sh --device UDID   only this device (repeatable)
#   ship.sh --now           relaunch the Mac after 3s instead of 20s
#
# The Mac relaunch runs detached (nohup) because this session is usually hosted
# inside the app it is about to quit. Its log path is printed; read it afterwards.
set -u
setopt pipefail

BUILD=1 DEVICES=1 MAC=1 DELAY=20
typeset -a ONLY
while (( $# )); do
  case $1 in
    --no-build) BUILD=0 ;;
    --no-devices) DEVICES=0 ;;
    --no-mac) MAC=0 ;;
    --device) ONLY+=$2; shift ;;
    --now) DELAY=3 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

HERE=${0:A:h}
# The main checkout, wherever this script is run from (a worktree's copy included).
REPO=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)
REPO=${REPO:h}
BRANCH=$(git -C "$REPO" --no-optional-locks branch --show-current)
[[ $BRANCH == main ]] || { echo "main checkout $REPO is on '$BRANCH', not main; stop" >&2; exit 1; }
SHA=$(git -C "$REPO" rev-parse --short HEAD)
LOGS=/tmp/ship-app-$SHA; mkdir -p $LOGS
MACAPP=$REPO/build/DD/Build/Products/Debug/Agents.app
BRIDGEAPP=$REPO/build/DD/Build/Products/Debug/agents-bridge.app
IOSAPP=$REPO/build/DD-ios/Build/Products/Debug-iphoneos/Agents.app
echo "main $SHA  logs $LOGS"
if [[ -n $(git -C "$REPO" --no-optional-locks status --porcelain --untracked-files=no) ]]; then
  echo "note: main checkout has uncommitted changes; the build includes them"
fi

run() { # name, then the command; quiet unless it fails
  local name=$1; shift
  echo "$(date +%T) $name"
  if ! ( cd "$REPO" && "$@" ) > $LOGS/$name.log 2>&1; then
    echo "FAILED: $name (log $LOGS/$name.log)" >&2
    grep -E 'error:|BUILD FAILED|FAILED' $LOGS/$name.log | head -20 >&2
    exit 1
  fi
}

XFLAGS=(-skipPackagePluginValidation -skipMacroValidation)
if (( BUILD )); then
  # Sequential on purpose: the schemes share build databases and SwiftPM state.
  run xcodegen xcodegen generate
  if (( MAC )); then
    run build-mac xcodebuild -scheme Agents -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DD $XFLAGS build
    run build-bridge xcodebuild -scheme agents-bridge -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DD $XFLAGS build
  fi
  if (( DEVICES )); then
    run build-ios xcodebuild -scheme Remote -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/DD-ios -allowProvisioningUpdates $XFLAGS build
  fi
fi

if (( DEVICES )); then
  [[ -d $IOSAPP ]] || { echo "no device build at $IOSAPP" >&2; exit 1; }
  BID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' $IOSAPP/Info.plist)
  if (( ${#ONLY} )); then
    UDIDS=($ONLY)
  else
    xcrun devicectl list devices --json-output $LOGS/devices.json >/dev/null 2>&1
    UDIDS=($(python3 - $LOGS/devices.json <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and d.get("connectionProperties", {}).get("pairingState") == "paired" \
       and hw.get("platform") == "iOS":
        print(hw["udid"])
PY
))
  fi
  (( ${#UDIDS} )) || echo "no paired iPhone/iPad visible; skipping devices"
  # One installer at a time across agents: a directory lock, stale after 10 minutes.
  LOCK=/tmp/agents-device-install.lock
  for i in {1..60}; do
    mkdir $LOCK 2>/dev/null && break
    [[ -n $(find $LOCK -maxdepth 0 -mmin +10 2>/dev/null) ]] && { rmdir $LOCK; continue; }
    (( i == 1 )) && echo "another install is running; waiting"
    sleep 10
  done
  trap 'rmdir /tmp/agents-device-install.lock 2>/dev/null' EXIT
  for U in $UDIDS; do
    ok=0
    for t in 1 2 3; do
      if xcrun devicectl device install app --device $U $IOSAPP > $LOGS/install-$U.log 2>&1; then ok=1; break; fi
      echo "install on $U failed (try $t); retrying in 30s"; sleep 30
    done
    if (( ok )); then
      xcrun devicectl device process launch --terminate-existing --device $U $BID > $LOGS/launch-$U.log 2>&1 \
        && echo "$(date +%T) installed and launched on $U" \
        || echo "installed on $U but launch failed (locked? log $LOGS/launch-$U.log)"
    else
      echo "INSTALL FAILED on $U: $(tail -3 $LOGS/install-$U.log | tr '\n' ' ')"
    fi
  done
  rmdir $LOCK 2>/dev/null; trap - EXIT
fi

if (( MAC )); then
  [[ -d $MACAPP && -d $BRIDGEAPP ]] || { echo "no Mac build in $REPO/build/DD" >&2; exit 1; }
  if ps -axww -o command= | grep -q '[m]ain-restart-all-.*\.sh'; then
    echo "another session's restart is already pending: $(ps -axww -o command= | grep '[m]ain-restart-all-')" >&2
    echo "not queueing a second one" >&2; exit 1
  fi
  # A window with no --root that is not main's build would grab the real root when the daemon restarts.
  STRAY=$(ps -axww -o pid=,command= | grep -E '/Contents/MacOS/Agents$' | grep -v " $MACAPP/Contents/MacOS/Agents$")
  if [[ -n $STRAY ]]; then
    echo "other builds are attached to the real root; ask Alex before quitting them:" >&2
    echo "$STRAY" >&2; exit 1
  fi
  W=$(ps -axww -o pid=,command= | grep -E "^ *[0-9]+ $MACAPP/Contents/MacOS/Agents$" | awk '{print $1}' | head -1)
  B=$(ps -axww -o pid=,command= | grep '[a]gents-bridge.app/Contents/MacOS/agents-bridge' | awk '{print $1}' | head -1)
  S=/tmp/main-restart-all-$SHA.sh
  cp $HERE/restart-mac.sh $S; chmod +x $S
  nohup $S "$REPO" "$SHA" "${W:-0}" "${B:-0}" $DELAY >/dev/null 2>&1 &!
  echo "$(date +%T) Mac relaunch scheduled in ${DELAY}s (window ${W:-none}, bridge ${B:-none}); log /tmp/main-restart-all-$SHA.log"
fi
