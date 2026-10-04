#!/bin/zsh
# Build main, install the Remote on Alex's paired iPhone/iPad, and put the new build
# live on this Mac: Agents Host (the control plane and this Mac's host, kept running by
# launchd) and the window (the App Store build, a client of the control plane like the
# phone). One script: the relaunch is this file detached (`--restart`), because the host
# it restarts is usually the one running the session that started it.
#
# Agents Host lives at ~/Applications/Agents Host.app, where its Login Items point. The
# new build is swapped in whole, and launchd restarts both jobs from it.
#
# The window runs from a copy in ~/Applications/AgentsLive/<sha>-<time>/, never from
# build/DD-store: every build in the main checkout writes over that.
#
# Everything is built in the Live configuration (#220): optimised like Release, signed for
# development like Debug. Release itself is the App Store archive's. Scratch walks
# (run-app), merge-wave's checks and the tests stay on Debug.
#
#   ship.sh                 everything
#   ship.sh --no-build      reuse build/DD-host, build/DD-store and build/DD-ios as they are
#   ship.sh --no-linux      skip rebuilding the Linux hosts in App/Resources/servers
#   ship.sh --no-devices    skip the iPhone/iPad
#   ship.sh --no-mac        skip the Mac
#   ship.sh --device UDID   only this device (repeatable)
#   ship.sh --now           relaunch the Mac after 3s instead of 20s
#   ship.sh --build-only    build in this checkout (a worktree's copy builds the worktree),
#                           check the products are optimised, and stop: nothing is installed
set -u
setopt pipefail

HOSTAPP_AT=$HOME/Applications/"Agents Host.app"
ROOT="$HOME/Library/Application Support/Agents"
GUI=gui/$(id -u)
# Agents Host's two jobs.
HOST_JOBS=(com.alexecollins.agentshost.control com.alexecollins.agentshost.daemon)
STORE_ID=com.alexecollins.agents.store

loaded() { launchctl print $GUI/$1 >/dev/null 2>&1 }
job_pid() { launchctl print $GUI/$1 2>/dev/null | awk '/^\tpid = /{print $3; exit}' }
any_loaded() { local j; for j in "$@"; do loaded $j && return 0; done; return 1 }
# "pid bundle" for each app running from a live copy with this bundle id.
live_apps() {
  local pid cmd bundle
  ps -axww -o pid=,command= | grep -E "^ *[0-9]+ $HOME/Applications/AgentsLive/[^/]+/Agents.app/Contents/MacOS/Agents$" |
    while read -r pid cmd; do
      bundle=${cmd%/Contents/MacOS/Agents}
      [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null) == $1 ]] && echo "$pid $bundle"
    done
}

restart() { # live-folder sha delay
  local LIVE=$1 SHA=$2 DELAY=${3:-20}
  exec >> /tmp/main-restart-all-$SHA.log 2>&1
  echo "$(date) start"
  sleep $DELAY
  local -a CLEAN
  CLEAN=(env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR"
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin LANG=en_US.UTF-8)
  local pid cmd j

  # Agents Host: the new bundle in place of the old, then launchd starts each job again
  # from it. Its window, if open, is reopened on the new build.
  local HOSTUI=0
  # By exact command line: a grep for the path would find the grep itself.
  ps -axww -o pid=,command= | while read -r pid cmd; do
    [[ $cmd == "$HOSTAPP_AT/Contents/MacOS/Agents Host" ]] || continue
    echo "quitting Agents Host window $pid"; HOSTUI=1; kill -TERM $pid
  done
  if [[ -d $HOSTAPP_AT ]]; then
    mkdir -p $HOME/Applications/AgentsLive
    mv "$HOSTAPP_AT" "$HOME/Applications/AgentsLive/host-before-$SHA-$(date +%H%M%S).app"
  fi
  mv "$LIVE/Agents Host.app" "$HOSTAPP_AT"
  echo "$(date) Agents Host $SHA at $HOSTAPP_AT"
  for j in $HOST_JOBS; do
    if loaded $j; then launchctl kickstart -k $GUI/$j && echo "restarted $j"; fi
  done
  if (( HOSTUI )) || ! any_loaded $HOST_JOBS; then
    $CLEAN open "$HOSTAPP_AT"
    echo "opened Agents Host"
  fi

  # The window: quit the store build's, open the new one. It finds the control plane
  # with the pairing in its container.
  live_apps $STORE_ID | while read -r pid cmd; do
    echo "quitting window $pid"; kill -TERM $pid
    for i in {1..50}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
  done
  echo "$(date) opening window $SHA"
  $CLEAN open "$LIVE/Agents.app"

  sleep 8
  for j in $HOST_JOBS; do
    pid=$(job_pid $j)
    if [[ -n $pid ]]; then
      echo "$j: $pid $(ps -o command= -p $pid)"
      echo "  CLAUDE vars: $(ps eww -p $pid | tr ' ' '\n' | grep -c ^CLAUDE)"
    else
      echo "$j: not running"
    fi
  done
  echo "window: $(ps -axww -o pid=,command= | grep -E "^ *[0-9]+ $LIVE/Agents.app/Contents/MacOS/Agents$")"

  # Earlier copies nothing runs from any more. The daemon keeps its own copy of the
  # helper in the root, so no agent needs these.
  local old
  for old in $HOME/Applications/AgentsLive/*(N/); do
    [[ $old == $LIVE ]] && continue
    if ps -axww -o command= | grep -F -q "$old/"; then echo "keeping $old: still running"; continue; fi
    echo "removing $old"; rm -rf "$old"
  done
  echo "$(date) done"
}

if [[ ${1:-} == --restart ]]; then
  shift
  restart "$@"
  exit
fi

BUILD=1 DEVICES=1 MAC=1 DELAY=20 LINUX=1 BUILD_ONLY=0
typeset -a ONLY
while (( $# )); do
  case $1 in
    --no-build) BUILD=0 ;;
    --no-linux) LINUX=0 ;;
    --no-devices) DEVICES=0 ;;
    --no-mac) MAC=0 ;;
    --device) ONLY+=$2; shift ;;
    --now) DELAY=3 ;;
    --build-only) BUILD_ONLY=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

HERE=${0:A:h}
# The main checkout, wherever this script is run from (a worktree's copy included).
REPO=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)
REPO=${REPO:h}
if (( BUILD_ONLY )); then
  # The checkout this copy of the script is in, so a worktree never writes over main's build.
  REPO=$(git -C "$HERE" rev-parse --show-toplevel)
  (( BUILD )) || { echo "--build-only with --no-build has nothing to do" >&2; exit 2; }
else
  BRANCH=$(git -C "$REPO" --no-optional-locks branch --show-current)
  [[ $BRANCH == main ]] || { echo "main checkout $REPO is on '$BRANCH', not main; stop" >&2; exit 1; }
fi
SHA=$(git -C "$REPO" rev-parse --short HEAD)
LOGS=/tmp/ship-app-$SHA; (( BUILD_ONLY )) && LOGS+=-build-only; mkdir -p $LOGS
CONFIG=Live
HOSTAPP=$REPO/build/DD-host/Build/Products/$CONFIG/"Agents Host.app"
STOREAPP=$REPO/build/DD-store/Build/Products/$CONFIG/Agents.app
IOSAPP=$REPO/build/DD-ios/Build/Products/$CONFIG-iphoneos/Agents.app
echo "$( (( BUILD_ONLY )) && echo "build only, $REPO" || echo main) $SHA  logs $LOGS"
if [[ -n $(git -C "$REPO" --no-optional-locks status --porcelain --untracked-files=no) ]]; then
  echo "note: $REPO has uncommitted changes; the build includes them"
fi

# Any build run from inside the main checkout, rather than from a live copy or a
# worktree, means an agent ran it there instead of creating a worktree.
typeset -a BAD
while read -r pid cmd; do
  case $cmd in
    $REPO/build/*/Contents/MacOS/*) BAD+=("$pid $cmd") ;;
  esac
done < <(ps -axww -o pid=,command=)
if (( ${#BAD} && ! BUILD_ONLY )); then
  echo "An agent failed to create a worktree. Nothing runs from the main checkout's build." >&2
  printf '%s\n' "${BAD[@]}" >&2
  exit 1
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
  # Sequential on purpose: the schemes share SwiftPM state. Each Mac app has build data
  # of its own.
  run xcodegen xcodegen generate
  if (( MAC )); then
    # The Linux hosts a server is given, which Agents Host carries and its control plane
    # serves: gitignored build outputs, so stale until rebuilt here.
    (( LINUX )) && run build-linux scripts/build-linux-agentsd.sh
    run build-host xcodebuild -scheme AgentsHost -configuration $CONFIG -destination 'platform=macOS' -derivedDataPath build/DD-host $XFLAGS build
    run build-window xcodebuild -scheme AgentsStore -configuration $CONFIG -destination 'platform=macOS' -derivedDataPath build/DD-store $XFLAGS build
  fi
  if (( DEVICES )); then
    run build-ios xcodebuild -scheme Remote -configuration $CONFIG -destination 'generic/platform=iOS' -derivedDataPath build/DD-ios -allowProvisioningUpdates $XFLAGS build
  fi
fi

# A Debug build carries its code in a .debug.dylib (and a __preview.dylib) beside a stub;
# an optimised one has neither. Checked before anything is installed.
debug_parts() { # bundle...
  local b
  for b in "$@"; do [[ -d $b ]] && find "$b" \( -name '*.debug.dylib' -o -name '__preview.dylib' \) -print; done
}
typeset -a BUILT
(( MAC )) && BUILT+=("$HOSTAPP" "$STOREAPP")
(( DEVICES )) && BUILT+=("$IOSAPP")
if [[ -n $(debug_parts $BUILT) ]]; then
  echo "these builds are not optimised (Debug parts in them); not shipping:" >&2
  debug_parts $BUILT >&2; exit 1
fi
if (( BUILD_ONLY )); then
  for b in $BUILT; do
    [[ -d $b ]] || { echo "missing $b" >&2; exit 1; }
    echo "built $b ($(du -sh "$b" | cut -f1), no Debug parts; $(codesign -dv "$b" 2>&1 | grep -E '^TeamIdentifier='))"
  done
  exit 0
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
  [[ -d $HOSTAPP && -d $STOREAPP ]] || { echo "no Mac build in $REPO/build/DD-host and build/DD-store" >&2; exit 1; }
  if ps -axww -o command= | grep -E -q '[s]hip\.sh --restart|[m]ain-restart-all-.*\.sh'; then
    echo "another session's restart is already pending: $(ps -axww -o command= | grep -E '[s]hip\.sh --restart|[m]ain-restart-all-')" >&2
    echo "not queueing a second one" >&2; exit 1
  fi
  # A folder of its own each time, never written again: what is running is never
  # what a build or a later ship is writing. Agents Host moves on from here into place.
  LIVE=$HOME/Applications/AgentsLive/$SHA-$(date +%Y%m%d-%H%M%S)
  mkdir -p $LIVE.partial
  ditto $STOREAPP $LIVE.partial/Agents.app && ditto $HOSTAPP "$LIVE.partial/Agents Host.app" \
    && codesign --verify --deep --strict $LIVE.partial/Agents.app 2>/dev/null \
    && codesign --verify --deep --strict "$LIVE.partial/Agents Host.app" 2>/dev/null \
    && ! codesign -dv "$LIVE.partial/Agents Host.app/Contents/Helpers/agentsd" 2>&1 | grep -q 'TeamIdentifier=not set' \
    || { echo "the Mac builds are not signed by the team (built with CODE_SIGNING_ALLOWED=NO?); rebuild without --no-build" >&2
         rm -rf $LIVE.partial; exit 1; }
  mv $LIVE.partial $LIVE
  echo "$(date +%T) staged $LIVE"
  nohup ${0:A} --restart "$LIVE" "$SHA" $DELAY >/dev/null 2>&1 &!
  echo "$(date +%T) Mac relaunch scheduled in ${DELAY}s; log /tmp/main-restart-all-$SHA.log"
fi
