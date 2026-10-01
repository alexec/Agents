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
#   ship.sh                 everything
#   ship.sh --switch        once (058, T105a): the developer window's own control plane
#                           and host make way for Agents Host's
#   ship.sh --no-build      reuse build/DD-host, build/DD-store and build/DD-ios as they are
#   ship.sh --no-devices    skip the iPhone/iPad
#   ship.sh --no-mac        skip the Mac
#   ship.sh --device UDID   only this device (repeatable)
#   ship.sh --now           relaunch the Mac after 3s instead of 20s
set -u
setopt pipefail

HOSTAPP_AT=$HOME/Applications/"Agents Host.app"
ROOT="$HOME/Library/Application Support/Agents"
CONTROL_HOME="$HOME/Library/Application Support/Agents Control"
GUI=gui/$(id -u)
# Agents Host's two jobs, and the developer window's from before the switch.
HOST_JOBS=(com.alexecollins.agentshost.control com.alexecollins.agentshost.daemon)
WINDOW_JOBS=(com.alexecollins.agents.control com.alexecollins.agents.host com.alexecollins.agents.hostonly)
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

restart() { # live-folder sha switch delay
  local LIVE=$1 SHA=$2 SWITCH=$3 DELAY=${4:-20}
  exec >> /tmp/main-restart-all-$SHA.log 2>&1
  echo "$(date) start"
  sleep $DELAY
  local -a CLEAN
  CLEAN=(env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR"
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin LANG=en_US.UTF-8)
  local pid cmd j

  if (( SWITCH )); then
    # Only the bundle that registered a job may unregister it: the running developer
    # window's own copy is asked to, and launchd stops the bridge-hosted control plane
    # and the daemon with them. Agents are left running.
    local OLDBUNDLE
    live_apps com.alexecollins.agents | head -1 | read -r pid OLDBUNDLE
    if [[ -z ${OLDBUNDLE:-} ]]; then echo "no developer window running to let its jobs go; stop"; exit 1; fi
    echo "quitting developer window $pid"
    kill -TERM $pid; for i in {1..50}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
    # The running copy predates --remove-services, so this build takes its place, at the
    # same path macOS registered the jobs from.
    echo "unregistering the window's jobs from $OLDBUNDLE"
    rm -rf "$OLDBUNDLE" && ditto "$LIVE/developer/Agents.app" "$OLDBUNDLE"
    "$OLDBUNDLE/Contents/MacOS/Agents" --remove-services
    for i in {1..75}; do any_loaded $WINDOW_JOBS || break; sleep 0.2; done
    if any_loaded $WINDOW_JOBS; then
      # Stopped now, but macOS may start them again at the next login: Alex turns
      # "Agents" off under System Settings ▸ General ▸ Login Items.
      echo "UNREGISTER FAILED; booting the window's jobs out instead"
      for j in $WINDOW_JOBS; do loaded $j && launchctl bootout $GUI/$j; done
      sleep 2
      if any_loaded $WINDOW_JOBS; then echo "the window's jobs are still loaded; stop"; exit 1; fi
    fi
    rm -rf "$LIVE/developer"
    # ship.sh's own bridges from before: the stuck one that never got 8790, and any other.
    ps -axww -o pid=,command= | grep -E "^ *[0-9]+ $HOME/Applications/AgentsLive/[^/]+/agents-bridge.app/Contents/MacOS/agents-bridge$" |
      while read -r pid cmd; do echo "quitting bridge $pid"; kill -TERM $pid; done
    # The bridge-hosted control plane's folder. Agents Host's control plane starts afresh
    # in the same place; the old one is kept beside it.
    if [[ -d $CONTROL_HOME ]]; then
      echo "moving $CONTROL_HOME aside"
      mv "$CONTROL_HOME" "$CONTROL_HOME (bridge $(date +%Y%m%d-%H%M%S))"
    fi
  fi

  # Agents Host: the new bundle in place of the old, then launchd starts each job again
  # from it. Its window, if open, is reopened on the new build.
  local HOSTUI=0
  ps -axww -o pid=,command= | grep -F "$HOSTAPP_AT/Contents/MacOS/Agents Host" | grep -v -- --launch-control |
    while read -r pid cmd; do echo "quitting Agents Host window $pid"; HOSTUI=1; kill -TERM $pid; done
  if [[ -d $HOSTAPP_AT ]]; then
    mkdir -p $HOME/Applications/AgentsLive
    mv "$HOSTAPP_AT" "$HOME/Applications/AgentsLive/host-before-$SHA-$(date +%H%M%S).app"
  fi
  mv "$LIVE/Agents Host.app" "$HOSTAPP_AT"
  echo "$(date) Agents Host $SHA at $HOSTAPP_AT"
  for j in $HOST_JOBS; do
    if loaded $j; then launchctl kickstart -k $GUI/$j && echo "restarted $j"; fi
  done
  if (( SWITCH || HOSTUI )) || ! any_loaded $HOST_JOBS; then
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
  (( SWITCH )) && echo "SWITCH: in Agents Host, Run it here (allow it under Login Items), Move Across…, then pair the window, iPhone and iPad"

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

BUILD=1 DEVICES=1 MAC=1 DELAY=20 SWITCH=0
typeset -a ONLY
while (( $# )); do
  case $1 in
    --no-build) BUILD=0 ;;
    --no-devices) DEVICES=0 ;;
    --no-mac) MAC=0 ;;
    --switch) SWITCH=1 ;;
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
HOSTAPP=$REPO/build/DD-host/Build/Products/Debug/"Agents Host.app"
STOREAPP=$REPO/build/DD-store/Build/Products/Debug/Agents.app
IOSAPP=$REPO/build/DD-ios/Build/Products/Debug-iphoneos/Agents.app
echo "main $SHA  logs $LOGS"
if [[ -n $(git -C "$REPO" --no-optional-locks status --porcelain --untracked-files=no) ]]; then
  echo "note: main checkout has uncommitted changes; the build includes them"
fi

# Which set-up this Mac has. The developer window's own jobs mean the switch has not
# happened: refuse without --switch, since shipping either way would leave two control
# planes wanting 8791 and one root.
if (( MAC )); then
  if any_loaded $WINDOW_JOBS; then
    if (( ! SWITCH )); then
      echo "the developer window still runs this Mac's control plane and host ($(for j in $WINDOW_JOBS; do loaded $j && print -n "$j "; done))." >&2
      echo "ship.sh --switch moves them to Agents Host, once. Ask Alex first: he has to press Run it here and pair his devices again." >&2
      exit 1
    fi
  elif (( SWITCH )); then
    echo "nothing to switch: the developer window runs no jobs" >&2; exit 1
  fi
fi

# Any build run from inside the main checkout, rather than from a live copy or a
# worktree, means an agent ran it there instead of creating a worktree.
typeset -a BAD
while read -r pid cmd; do
  case $cmd in
    $REPO/build/*/Contents/MacOS/*) BAD+=("$pid $cmd") ;;
  esac
done < <(ps -axww -o pid=,command=)
if (( ${#BAD} )); then
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
  # of its own: the window and the developer window are both Agents.app.
  run xcodegen xcodegen generate
  if (( MAC )); then
    run build-host xcodebuild -scheme AgentsHost -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DD-host $XFLAGS build
    run build-window xcodebuild -scheme AgentsStore -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DD-store $XFLAGS build
    # Only to let the developer window's jobs go (see --restart).
    (( SWITCH )) && run build-developer xcodebuild -scheme Agents -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DD $XFLAGS build
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
  if (( SWITCH )); then
    DEVAPP=$REPO/build/DD/Build/Products/Debug/Agents.app
    [[ -d $DEVAPP ]] || { echo "no developer window build in $REPO/build/DD" >&2; rm -rf $LIVE.partial; exit 1; }
    ditto $DEVAPP $LIVE.partial/developer/Agents.app
  fi
  mv $LIVE.partial $LIVE
  echo "$(date +%T) staged $LIVE"
  nohup ${0:A} --restart "$LIVE" "$SHA" $SWITCH $DELAY >/dev/null 2>&1 &!
  echo "$(date +%T) Mac relaunch scheduled in ${DELAY}s; log /tmp/main-restart-all-$SHA.log"
fi
