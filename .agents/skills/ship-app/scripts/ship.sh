#!/bin/zsh
# Build main and install Agents (the Mac window and this Mac's host, one app since #4225)
# and the Remote.
#
# The Mac install runs by default. Pass --no-mac to leave Agents and the login-item jobs
# alone. A development run and a merge wave do not run this script.
#
# Agents is swapped in at ~/Applications/Agents.app, where its Login Items point, and launchd
# restarts both jobs from it. It is staged in ~/Applications/AgentsLive/<sha>-<time>/ first,
# never moved from build/DD-host: every build in the main checkout writes over that. The
# relaunch is this file detached (`--restart`), because the host it restarts is usually the
# one running the session that started it. Agents Host's copy (~/Applications/Agents
# Host.app) and the App Store window's (a live copy) go, the first time.
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
#   ship.sh --no-build      reuse build/DD-host and build/DD-ios as they are
#   ship.sh --no-linux      skip rebuilding the Linux hosts in App/Resources/servers
#   ship.sh --no-devices    skip the iPhone/iPad
#   ship.sh --device UDID   only this device (repeatable)
#   ship.sh --now           relaunch the Mac after 3s instead of 20s
#   ship.sh --list-devices  say which devices it would install on, and why it skips any;
#                           nothing is built or installed
#   ship.sh --build-only    build in this checkout (a worktree's copy builds the worktree),
#                           check the products are optimised, and stop: nothing is installed
#   ship.sh --check-host    say which copies of Agents macOS knows and whether the jobs
#                           run from the installed one; nothing is changed (#3451)
#   ship.sh --control-plane also deploy this checkout to the live control plane,
#                           control.agentloops.dev, with deploy/gcp/up.sh (#4712): the
#                           release's image on a release tag, else built here (--build)
#
# The jobs name their app by bundle id only, so launchd can start them from any copy that
# LaunchServices knows, such as an old Debug build in some checkout (#3451). launchd keeps
# the copy it found while that copy is on disk, also when LaunchServices forgets it (#3521).
# So the restart leaves LaunchServices only the installed copy, moves aside the copy the
# jobs run from, and restarts them. A job whose login item was registered from that copy
# does not start from another (#4130), so when they do not come up on the installed copy,
# that copy registers them again (`Agents Host --register-jobs`). The copy moved aside
# goes back only then, and the restart checks that they run from the installed one.
set -u
setopt pipefail

HOSTAPP_AT=$HOME/Applications/Agents.app
# Where Agents Host was installed before it became Agents (#4225).
OLD_HOSTAPP_AT=$HOME/Applications/"Agents Host.app"
ROOT="$HOME/Library/Application Support/Agents"
GUI=gui/$(id -u)
# Agents' two jobs.
HOST_JOBS=(com.alexecollins.agentshost.control com.alexecollins.agentshost.daemon)
STORE_ID=com.alexecollins.agents.store
HOST_ID=com.alexecollins.agents.host
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

loaded() { launchctl print $GUI/$1 >/dev/null 2>&1 }
job_pid() { launchctl print $GUI/$1 2>/dev/null | awk '/^\tpid = /{print $3; exit}' }
# "pid bundle" for each app running from a live copy with this bundle id.
live_apps() {
  local pid cmd bundle
  ps -axww -o pid=,command= | grep -E "^ *[0-9]+ $HOME/Applications/AgentsLive/[^/]+/Agents.app/Contents/MacOS/Agents$" |
    while read -r pid cmd; do
      bundle=${cmd%/Contents/MacOS/Agents}
      [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null) == $1 ]] && echo "$pid $bundle"
    done
}

# Every copy of Agents that LaunchServices has, also ones that are gone.
host_copies() {
  $LSREGISTER -dump Bundle 2>/dev/null | awk -v id=$HOST_ID '
    /^-----/ { path = "" }
    /^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
    /^identifier:/ && $2 == id && path != "" { print path }' | sort -u
}
# LaunchServices keeps only the installed copy, so launchd can start no other. A copy that
# is gone cannot be started, and lsregister cannot remove it.
only_installed_host() {
  local copy
  for copy in ${(f)"$(host_copies)"}; do
    [[ $copy == $HOSTAPP_AT || ! -d $copy ]] && continue
    if $LSREGISTER -u "$copy" 2>/dev/null; then echo "unregistered $copy"
    else echo "could not unregister $copy"; fi
  done
  $LSREGISTER -f "$HOSTAPP_AT"
}
# Says where each loaded job runs from; fails if one is not running from the installed copy.
host_jobs_installed() {
  local j pid prog ok=0
  for j in $HOST_JOBS; do
    loaded $j || continue
    pid=$(job_pid $j)
    prog=${pid:+$(ps -o comm= -p $pid)}
    if [[ -z $prog ]]; then echo "$j: not running"; ok=1
    elif [[ $prog != $HOSTAPP_AT/* ]]; then echo "$j: runs $prog, not the installed $HOSTAPP_AT"; ok=1
    else echo "$j: $pid $prog"; fi
  done
  return $ok
}
# The bundles the host jobs run from, other than the installed one.
running_copies() {
  local j pid prog
  for j in $HOST_JOBS; do
    pid=$(job_pid $j)
    prog=${pid:+$(ps -o comm= -p $pid)}
    [[ $prog == /*/Contents/* && $prog != $HOSTAPP_AT/* ]] && echo ${prog%%/Contents/*}
  done | sort -u
}
# launchd starts a job again from the copy it found, while that copy is on disk, even when
# LaunchServices no longer has it (#3521). The running processes keep their files. A copy
# that is not there can make launchd look again; when the login item was registered from
# it, the job does not start at all (78: EX_CONFIG) until it is registered again (#4130).
typeset -a ASIDE
move_aside_running_copies() {
  local copy
  for copy in ${(f)"$(running_copies)"}; do
    if mv "$copy" "$copy.aside-$$"; then ASIDE+=($copy); echo "moved aside $copy"
    else echo "could not move aside $copy"; fi
  done
}
# The copies moved aside go back, unregistered, once launchd has started the jobs again.
put_back_copies() {
  local copy
  for copy in $ASIDE; do
    if [[ -e $copy ]]; then echo "left $copy.aside-$$: a new $copy is there"; continue; fi
    if mv "$copy.aside-$$" "$copy"; then
      $LSREGISTER -u "$copy" 2>/dev/null
      echo "put back $copy"
    else echo "could not put back $copy (it is at $copy.aside-$$)"; fi
  done
  ASIDE=()
}
# Waits up to 30s for the jobs to run from the installed copy.
wait_host_jobs_installed() {
  local i
  for i in {1..15}; do host_jobs_installed >/dev/null && break; sleep "${WAIT_STEP:-2}"; done
  host_jobs_installed
}
# The installed copy registers its login items again, so launchd starts them from it (#4130).
register_jobs_from_installed() {
  echo "$(date) registering the jobs again from $HOSTAPP_AT"
  ${CLEAN[@]} "$HOSTAPP_AT/Contents/MacOS/Agents Host" --register-jobs
}
# With the other copies aside: restart the jobs, and when they do not come up on the
# installed copy, register them again from it. The copies go back after that, also when
# it failed: a job on the old copy is better than none.
restart_host_jobs() {
  local j ok=0
  move_aside_running_copies
  for j in $HOST_JOBS; do
    if loaded $j; then launchctl kickstart -k $GUI/$j && echo "restarted $j"; fi
  done
  if ! wait_host_jobs_installed; then
    register_jobs_from_installed
    wait_host_jobs_installed || ok=1
  fi
  put_back_copies
  return $ok
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

  # Agents: the new bundle in place of the old, then launchd starts each job again from it,
  # and the window opens on the new build. Agents Host's copy goes aside as an old one does.
  # By exact command line: a grep for the path would find the grep itself.
  ps -axww -o pid=,command= | while read -r pid cmd; do
    [[ $cmd == "$HOSTAPP_AT/Contents/MacOS/Agents Host" || $cmd == "$OLD_HOSTAPP_AT/Contents/MacOS/Agents Host" ]] || continue
    echo "quitting Agents $pid"; kill -TERM $pid
  done
  mkdir -p $HOME/Applications/AgentsLive
  local before
  for before in $HOSTAPP_AT $OLD_HOSTAPP_AT; do
    [[ -d $before ]] && mv "$before" "$HOME/Applications/AgentsLive/host-before-$SHA-$(date +%H%M%S)-${before:t:r:gs/ /-/}.app"
  done
  mv "$LIVE/Agents.app" "$HOSTAPP_AT"
  echo "$(date) Agents $SHA at $HOSTAPP_AT"
  only_installed_host
  restart_host_jobs

  # The App Store window, from before #4225: the one app is the window now.
  live_apps $STORE_ID | while read -r pid cmd; do
    echo "quitting the App Store window $pid"; kill -TERM $pid
    for i in {1..50}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
  done
  echo "$(date) opening Agents $SHA"
  $CLEAN open "$HOSTAPP_AT"

  sleep 8
  local wrong=0
  if ! wait_host_jobs_installed; then
    # Something registered another copy again while this ran: once more, then give up.
    echo "$(date) the jobs do not run from $HOSTAPP_AT; unregistering and moving aside the other copies again"
    only_installed_host
    restart_host_jobs || wrong=1
  fi
  for j in $HOST_JOBS; do
    pid=$(job_pid $j)
    [[ -n $pid ]] && echo "$j CLAUDE vars: $(ps eww -p $pid | tr ' ' '\n' | grep -c ^CLAUDE)"
  done
  echo "window: $(ps -axww -o pid=,command= | grep -F "$HOSTAPP_AT/Contents/MacOS/Agents Host" | grep -v -e --launch -e grep)"

  # Earlier copies nothing runs from any more. The daemon keeps its own copy of the
  # helper in the root, so no agent needs these.
  local old
  for old in $HOME/Applications/AgentsLive/*(N/); do
    [[ $old == $LIVE ]] && continue
    if ps -axww -o command= | grep -F -q "$old/"; then echo "keeping $old: still running"; continue; fi
    echo "removing $old"; rm -rf "$old"
  done
  if (( wrong )); then
    echo "$(date) FAILED: Agents' jobs do not run from $HOSTAPP_AT (#3451); see ship.sh --check-host"
    osascript -e 'display notification "Its jobs run from another copy. See /tmp/main-restart-all-'$SHA'.log" with title "Agents did not restart from the installed app"' 2>/dev/null
    exit 1
  fi
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
if [[ ${1:-} == --check-host ]]; then
  echo "copies of $HOST_ID that macOS knows:"
  host_copies | while read -r copy; do
    [[ $copy == $HOSTAPP_AT ]] && echo "  $copy (installed)" && continue
    [[ -d $copy ]] && echo "  $copy" || echo "  $copy (gone)"
  done
  host_jobs_installed
  exit
fi
if [[ ${1:-} == --install-device ]]; then
  shift
  install_device "$@"
  exit
fi

BUILD=1 DEVICES=1 MAC=1 DELAY=20 LINUX=1 BUILD_ONLY=0 LIST_DEVICES=0 CONTROL_PLANE=0
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
    --control-plane) CONTROL_PLANE=1 ;;
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
HOSTAPP=$REPO/build/DD-host/Build/Products/$CONFIG/Agents.app
IOSAPP=$REPO/build/DD-ios/Build/Products/$CONFIG-iphoneos/Agents.app
echo "$( (( BUILD_ONLY )) && echo "build only, $REPO" || echo "main, $REPO") $SHA  logs $LOGS"
if [[ -n $(git -C "$REPO" --no-optional-locks status --porcelain --untracked-files=no) ]]; then
  # The live control plane serves other people: only a commit, never edits on top of one.
  (( CONTROL_PLANE && ! BUILD_ONLY )) && { echo "$REPO has uncommitted changes; not deploying them to the control plane; stop" >&2; exit 1; }
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
    # The Linux hosts a server is given, which Agents carries and its control plane
    # serves: gitignored build outputs, so stale until rebuilt here.
    (( LINUX )) && run build-linux scripts/build-linux-agentsd.sh
    run build-host scripts/build-cache.sh xcodebuild -scheme AgentsHost -configuration $CONFIG -destination 'platform=macOS' -derivedDataPath build/DD-host $XFLAGS build
  fi
  if (( DEVICES )); then
    # Xcode makes the Remote's profiles (the app, RemoteShare and their App Group) with an
    # account. With no Apple ID in Xcode's Accounts, it falls back to the wildcard profile and
    # fails on the App Group; the App Store Connect key, as for scripts/release-secrets.sh,
    # lets it make them without one.
    ASC=()
    if [[ -r ~/.private_keys/asc.env ]]; then
      ASC_ENV=$(set -a; source ~/.private_keys/asc.env; print -r -- "$ASC_KEY_ID $ASC_ISSUER_ID")
      P8=( ~/.private_keys/AuthKey_${ASC_ENV%% *}.p8(N) )
      (( ${#P8} )) && ASC=(-authenticationKeyPath $P8[1] -authenticationKeyID ${ASC_ENV%% *} -authenticationKeyIssuerID ${ASC_ENV##* })
    fi
    run build-ios scripts/build-cache.sh xcodebuild -scheme Remote -configuration $CONFIG -destination 'generic/platform=iOS' -derivedDataPath build/DD-ios -allowProvisioningUpdates $ASC $XFLAGS build
  fi
fi

# A Debug build carries its code in a .debug.dylib (and a __preview.dylib) beside a stub;
# an optimised one has neither. Checked before anything is installed.
debug_parts() { # bundle...
  local b
  for b in "$@"; do [[ -d $b ]] && find "$b" \( -name '*.debug.dylib' -o -name '__preview.dylib' \) -print; done
}
typeset -a BUILT
(( MAC )) && BUILT+=("$HOSTAPP")
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

# The live control plane (#4712), before the Mac restart, which can end this session's turn.
# A failed deploy does not stop the Mac and the devices; the script exits 1 at the end.
CP_FAILED=0
if (( CONTROL_PLANE )); then
  CP_VERSION=$("$REPO/scripts/version.sh")
  typeset -a UP_FLAGS
  # Only a release's X.Y.Z has an image to pull; any other commit is built here.
  [[ $CP_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || UP_FLAGS=(--build)
  echo "$(date +%T) control-plane $CP_VERSION${UP_FLAGS:+ (image built here)}; log $LOGS/control-plane.log"
  if ( cd "$REPO" && deploy/gcp/up.sh $UP_FLAGS ) > $LOGS/control-plane.log 2>&1; then
    echo "$(date +%T) control plane serves: $(grep -E '^agents-control ' $LOGS/control-plane.log | tail -1)"
  else
    CP_FAILED=1
    echo "FAILED: control-plane (log $LOGS/control-plane.log)" >&2
    tail -5 $LOGS/control-plane.log >&2
  fi
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
  [[ -d $HOSTAPP ]] || { echo "no Mac build in $REPO/build/DD-host" >&2; exit 1; }
  if ps -axww -o command= | grep -E -q '[s]hip\.sh --restart|[m]ain-restart-all-.*\.sh'; then
    echo "another session's restart is already pending: $(ps -axww -o command= | grep -E '[s]hip\.sh --restart|[m]ain-restart-all-')" >&2
    echo "not queueing a second one" >&2; exit 1
  fi
  # A folder of its own each time, never written again: what is running is never
  # what a build or a later ship is writing. Agents moves on from here into place.
  LIVE=$HOME/Applications/AgentsLive/$SHA-$(date +%Y%m%d-%H%M%S)
  mkdir -p $LIVE.partial
  ditto $HOSTAPP $LIVE.partial/Agents.app \
    && codesign --verify --deep --strict $LIVE.partial/Agents.app 2>/dev/null \
    && ! codesign -dv "$LIVE.partial/Agents.app/Contents/Helpers/agentsd" 2>&1 | grep -q 'TeamIdentifier=not set' \
    || { echo "the Mac builds are not signed by the team (built with CODE_SIGNING_ALLOWED=NO?); rebuild without --no-build" >&2
         rm -rf $LIVE.partial; exit 1; }
  mv $LIVE.partial $LIVE
  echo "$(date +%T) staged $LIVE"
  nohup ${0:A} --restart "$LIVE" "$SHA" $DELAY >/dev/null 2>&1 &!
  echo "$(date +%T) Mac relaunch scheduled in ${DELAY}s; log /tmp/main-restart-all-$SHA.log"
else
  echo "leaving the Mac app where it is: no copy into Applications, no login-item restart"
fi
(( ! CP_FAILED ))
