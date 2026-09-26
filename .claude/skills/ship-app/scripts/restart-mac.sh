#!/bin/zsh
# Detached by ship.sh: quit the real window and daemon, open main's build with a
# clean environment, then restart the phone bridge. Args: repo sha window bridge delay
REPO=$1 SHA=$2 W=$3 B=$4 DELAY=${5:-20}
exec >> /tmp/main-restart-all-$SHA.log 2>&1
echo "$(date) start"
sleep $DELAY
ROOT="$HOME/Library/Application Support/Agents"
LOCK="$ROOT/daemon.lock"
MACAPP=$REPO/build/DD/Build/Products/Debug/Agents.app
BRIDGEAPP=$REPO/build/DD/Build/Products/Debug/agents-bridge.app
CLEAN=(env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh TMPDIR="$TMPDIR"
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin LANG=en_US.UTF-8)

D=$(cat "$LOCK" 2>/dev/null)
[[ -n $D ]] && case "$(ps -o command= -p $D)" in
  */Contents/Helpers/agentsd) ;;
  *) echo "lock pid $D is not a running agentsd; not signalling it"; D= ;;
esac
if [[ $W != 0 ]]; then
  case "$(ps -o command= -p $W)" in
    "$MACAPP/Contents/MacOS/Agents") ;;
    *) echo "window $W is no longer the real window; stop"; exit 1 ;;
  esac
  echo "quitting window $W"
  kill -TERM $W
  for i in {1..50}; do kill -0 $W 2>/dev/null || break; sleep 0.2; done
fi
if [[ -n $D ]]; then
  echo "quitting daemon $D ($(ps -o command= -p $D))"
  kill -TERM $D 2>/dev/null
  for i in {1..75}; do kill -0 $D 2>/dev/null || break; sleep 0.2; done
  kill -0 $D 2>/dev/null && { echo "KILL $D"; kill -KILL $D; sleep 1; }
fi

echo "$(date) opening main build $SHA"
$CLEAN open "$MACAPP"
for i in {1..100}; do [ -S "$ROOT/daemon.sock" ] && [ "$(cat "$LOCK" 2>/dev/null)" != "$D" ] && break; sleep 0.2; done
N=$(cat "$LOCK"); echo "new daemon $N: $(ps -o command= -p $N)"
echo "CLAUDE vars: $(ps eww -p $N | tr ' ' '\n' | grep -c ^CLAUDE)"
echo "window: $(ps -axww -o pid=,command= | grep -E "^ *[0-9]+ $MACAPP/Contents/MacOS/Agents$")"

if [[ $B != 0 ]]; then
  case "$(ps -o command= -p $B)" in
    "$BRIDGEAPP/Contents/MacOS/agents-bridge")
      kill -TERM $B; for i in {1..25}; do kill -0 $B 2>/dev/null || break; sleep 0.2; done ;;
    *) echo "bridge $B is not main's build; leaving it and not starting another"; echo "$(date) done"; exit 0 ;;
  esac
fi
$CLEAN AGENTS_ROOT="$ROOT" open -n -g --stderr /tmp/bridge-$SHA.log --stdout /tmp/bridge-$SHA.log "$BRIDGEAPP"
sleep 8; echo "bridge: $(ps -axww -o pid=,command= | grep '[a]gents-bridge.app/Contents/MacOS/agents-bridge')"
echo "$(date) done"
