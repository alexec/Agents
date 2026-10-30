#!/bin/zsh
# Build main and install Agents Host, the Mac window and the Remote.
#
# The Mac install runs by default. Pass --no-mac to leave Agents Host, the window and the
# login-item jobs alone. A development run and a merge wave do not run this script.
#
# Agents Host is swapped in at ~/Applications/Agents Host.app, where its Login Items point,
# and launchd restarts both jobs from it. The window runs from a copy in
# ~/Applications/AgentsLive/<sha>-<time>/, never from build/DD-store: every build in the
# main checkout writes over that. The relaunch is this file detached (`--restart`), because
# the host it restarts is usually the one running the session that started it.
#
# A device install is detached the same way (`--install-device`), one per device, and does
# not wait on or delay the Mac relaunch: a locked phone or a flaky connection retries every
# 2 minutes for up to an hour on its own, in the background.
#
# Everything is built in the Live configuration (#220): optimised like Release, signed for
# development like Debug. Release itself is the App Store archive's. Scratch walks
# (run-app), merge-wave's checks and the tests stay on Debug.
#
# Run from a worktree, it builds and installs that worktree, if clean and at origin/main
# (#797); run from the main checkout, the main checkout.
#
#   ship.sh                 install the Mac apps and Remote (the default)
#   ship.sh --no-mac        skip the Mac install and restart
#   ship.sh --install-mac   accepted as an alias for the default
#   ship.sh --no-build      reuse build/DD-host, build/DD-store and build/DD-ios as they are
#   ship.sh --no-linux      skip rebuilding the Linux hosts in App/Resources/servers
#   ship.sh --no-devices    skip the iPhone/iPad
#   ship.sh --device UDID   only this device (repeatable)
#   ship.sh --now           relaunch the Mac after 3s instead of 20s
#   ship.sh --list-devices  say which devices it would install on, and why it skips any;
#                           nothing is built or installed
#   ship.sh --build-only    build in this checkout (a worktree's copy builds the worktree),
#                           check the products are optimised, and stop: nothing is installed
set -u
setopt pipefail

HOSTAPP_AT=$HOME/Applications/"Agents Host.app"
ROOT="$HOME/Library/Application Support/Agents"
GUI=gui/$(id -u)
# Agents Host's two jobs.
HOST_JOBS=(com.alexecollins.agentshost.control com.alexecollins.agentshost.daemon)
# Its relay, loaded only while Relay for my devices is on. It is started again with the
# others: its command line names no path, so the clean-up below cannot see that it runs
# from the old copy, and CloudKit refuses a client whose binary is gone (#1103).
RELAY_JOB=com.alexecollins.agentshost.relay
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
  for j in $HOST_JOBS $RELAY_JOB; do
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

install_device() { # udid bid app sha
  local udid=$1 bid=$2 app=$3 sha=$4
  exec >> /tmp/ship-install-$udid-$sha.log 2>&1
  echo "$(date) retrying install on $udid every 2m, for up to 1h"
  local deadline=$(( $(date +%s) + 3600 )) ok=0
  while (( $(date +%s) < deadline )); do
    # One installer at a time across agents: a directory lock, stale after 10 minutes.
    # Held only for this attempt, not the whole hour, so other installs are not starved.
    local LOCK=/tmp/agents-device-install.lock i
    for i in {1..60}; do
      mkdir $LOCK 2>/dev/null && break
      [[ -n $(find $LOCK -maxdepth 0 -mmin +10 2>/dev/null) ]] && { rmdir $LOCK; continue; }
      sleep 10
    done
    trap 'rmdir $LOCK 2>/dev/null' EXIT
    xcrun devicectl device install app --device $udid "$app" > /tmp/ship-install-$udid-$sha-attempt.log 2>&1 && ok=1
    rmdir $LOCK 2>/dev/null; trap - EXIT
    if (( ok )); then
      xcrun devicectl device process launch --terminate-existing --device $udid $bid \
        && echo "$(date +%T) installed and launched on $udid" \
        || echo "installed on $udid but launch failed (locked?)"
      break
    fi
    echo "$(date +%T) install on $udid failed: $(tail -3 /tmp/ship-install-$udid-$sha-attempt.log | tr '\n' ' ')"
    echo "$(date +%T) retrying in 2m"
    sleep 120
  done
  (( ok )) || echo "$(date +%T) gave up on $udid after 1h"
  echo "$(date) done"
}

if [[ ${1:-} == --restart ]]; then
  shift
  restart "$@"
  exit
fi
if [[ ${1:-} == --install-device ]]; then
  shift
  install_device "$@"
  exit
fi

BUILD=1 DEVICES=1 MAC=1 DELAY=20 LINUX=1 BUILD_ONLY=0 LIST_DEVICES=0
typeset -a ONLY
while (( $# )); do
  case $1 in
    --no-build) BUILD=0 ;;
    --no-linux) LINUX=0 ;;
    --no-devices) DEVICES=0 ;;
    --install-mac) MAC=1 ;;
    --no-mac) MAC=0 ;;
    --device) ONLY+=$2; shift ;;
    --now) DELAY=3 ;;
    --build-only) BUILD_ONLY=1 ;;
    --list-devices) LIST_DEVICES=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

HERE=${0:A:h}

# Sets UDIDS to the devices to install on, from devicectl's list, and says for each device
# why it is installed on or skipped (#1310): devices.py, so a device with no
# hardwareProperties is not dropped without a word.
choose_devices() { # json file
  local plan line action udid rest
  UDIDS=()
  rm -f $1
  xcrun devicectl list devices --json-output $1 >/dev/null 2>&1
  [[ -s $1 ]] || { echo "devicectl gave no device list; see: xcrun devicectl list devices" >&2; return 1; }
  plan=$(python3 "$HERE/devices.py" $1) || return 1
  for line in ${(f)plan}; do
    read -r action udid rest <<< $line
    case $action in
      install) UDIDS+=$udid; echo "will install on $udid $rest" ;;
      skip) echo "skipping $udid $rest" ;;
    esac
  done
}
if (( LIST_DEVICES )); then
  LISTING=$(mktemp -d -t ship-devices)/devices.json
  choose_devices $LISTING || exit 1
  rm -rf ${LISTING:h}
  (( ${#UDIDS} )) || echo "no paired iPhone/iPad to install on"
  exit 0
fi

# The main checkout, wherever this script is run from (a worktree's copy included).
REPO=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)
REPO=${REPO:h}
if (( BUILD_ONLY )); then
  # The checkout this copy of the script is in, so a worktree never writes over main's build.
  REPO=$(git -C "$HERE" rev-parse --show-toplevel)
  (( BUILD )) || { echo "--build-only with --no-build has nothing to do" >&2; exit 2; }
elif [[ $(git -C "$HERE" rev-parse --show-toplevel) != $REPO ]]; then
  # Run from a worktree (#797): ship that worktree, so the live app is never built in the
  # main checkout. Only a clean one at origin/main.
  REPO=$(git -C "$HERE" rev-parse --show-toplevel)
  git -C "$REPO" fetch -q origin main || { echo "cannot fetch origin main; stop" >&2; exit 1; }
  [[ $(git -C "$REPO" rev-parse HEAD) == $(git -C "$REPO" rev-parse origin/main) ]] \
    || { echo "worktree $REPO is not at origin/main; stop" >&2; exit 1; }
  [[ -z $(git -C "$REPO" status --porcelain --untracked-files=no) ]] \
    || { echo "worktree $REPO has uncommitted changes; stop" >&2; exit 1; }
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
echo "$( (( BUILD_ONLY )) && echo "build only, $REPO" || echo "main, $REPO") $SHA  logs $LOGS"
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

# No point building the Remote to install it on nothing: check before the build, not
# after. --build-only still builds it even with no device, to prove the build itself.
if (( DEVICES )) && (( ! BUILD_ONLY )); then
  if (( ${#ONLY} )); then
    UDIDS=($ONLY)
  else
    choose_devices $LOGS/devices.json || exit 1
    (( ${#UDIDS} )) || { echo "no paired iPhone/iPad available; skipping the Remote build and install"; DEVICES=0 }
  fi
fi

# The apps say the version of this commit, X.Y.Z after its tag (#1748): project.yml's is only
# for a plain xcodebuild; a release sets its own from the tag.
XFLAGS=(-skipPackagePluginValidation -skipMacroValidation MARKETING_VERSION=$("$REPO/scripts/version.sh" --marketing))
if (( BUILD )); then
  # Sequential on purpose: the schemes share SwiftPM state. Each Mac app has build data
  # of its own; packages and compiled outputs come from the shared build cache.
  run xcodegen xcodegen generate
  if (( MAC )); then
    # The Linux hosts a server is given, which Agents Host carries and its control plane
    # serves: gitignored build outputs, so stale until rebuilt here.
    (( LINUX )) && run build-linux scripts/build-linux-agentsd.sh
    run build-host scripts/build-cache.sh xcodebuild -scheme AgentsHost -configuration $CONFIG -destination 'platform=macOS' -derivedDataPath build/DD-host $XFLAGS build
    run build-window scripts/build-cache.sh xcodebuild -scheme AgentsStore -configuration $CONFIG -destination 'platform=macOS' -derivedDataPath build/DD-store $XFLAGS build
  fi
  if (( DEVICES )); then
    run build-ios scripts/build-cache.sh xcodebuild -scheme Remote -configuration $CONFIG -destination 'generic/platform=iOS' -derivedDataPath build/DD-ios -allowProvisioningUpdates $XFLAGS build
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
  for U in $UDIDS; do
    nohup ${0:A} --install-device $U $BID $IOSAPP $SHA >/dev/null 2>&1 &!
    echo "$(date +%T) installing on $U in the background, retrying up to 1h; log /tmp/ship-install-$U-$SHA.log"
  done
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
else
  echo "leaving the Mac app where it is: no copy into Applications, no login-item restart"
fi
