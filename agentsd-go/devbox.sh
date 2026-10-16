#!/bin/sh
# Builds the Go host for the devbox, copies it there and restarts it on its own root
# (~/.agents-go/root), by the pid in that root's daemon.lock: never a pattern kill.
#   ./devbox.sh                 build, copy, restart (the root's membership is kept)
#   ./devbox.sh join '<code>'   the same, enrolling afresh with a host code
#   ./devbox.sh log             the host's daemon.log
#   ./devbox.sh tools           install the pinned Claude and Codex toolsets in ~/.agents-go/tools
#                               (nothing installs them on a control-plane host today, #1125 report)
#   ./devbox.sh stop            stop the Go host: its supervisor, then the host, by their lock pids
#   ./devbox.sh panic <where>   force a panic (handler|goroutine|timer|bare); needs DEBUG_PANIC=1 at deploy
# The detached host runs under `agentsd supervise`, which starts it again after a crash (#1125).
set -e
here=$(cd "$(dirname "$0")" && pwd)
ssh_() { ssh -p 2222 -o UserKnownHostsFile="$HOME/.cache/agents-devbox/known_hosts" -i "$HOME/.ssh/id_ed25519" agents@127.0.0.1 "$@"; }
scp_() { scp -q -P 2222 -o UserKnownHostsFile="$HOME/.cache/agents-devbox/known_hosts" -i "$HOME/.ssh/id_ed25519" "$@"; }
case "$1" in
log) ssh_ 'tail -n 80 ~/.agents-go/root/daemon.log'; exit ;;
stop) ssh_ 'R=$HOME/.agents-go/root; for l in supervise daemon; do [ -f $R/$l.lock ] && kill $(cat $R/$l.lock) 2>/dev/null; done; echo stopped'; exit ;;
panic) ssh_ "perl - \$HOME/.agents-go/root/daemon.sock ${2:-handler}" <<'PERL'
use IO::Socket::UNIX; my $s = IO::Socket::UNIX->new(Peer => $ARGV[0]) or die "no socket: $!";
my $m = $ARGV[1] eq "count" ? "debug/panics" : "debug/panic";
print $s qq({"jsonrpc":"2.0","id":1,"method":"$m","params":{"where":"$ARGV[1]"}}\n); print scalar <$s>;
PERL
  exit ;;
tools)
  t="$here/../App/Resources/toolsets"
  scp_ "$t/claude/package.json" agents@127.0.0.1:/tmp/claude-package.json
  scp_ "$t/claude/package-lock.json" agents@127.0.0.1:/tmp/claude-package-lock.json
  scp_ "$t/codex/package.json" agents@127.0.0.1:/tmp/codex-package.json
  scp_ "$t/codex/package-lock.json" agents@127.0.0.1:/tmp/codex-package-lock.json
  ssh_ 'set -e; T=$HOME/.agents-go/tools; N=$T/node-v24.21.0
    if [ ! -x $N/bin/node ]; then mkdir -p $N; cd $T
      curl -fsSL -o node.tar.gz https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-arm64.tar.gz
      curl -fsSL https://nodejs.org/dist/v24.21.0/SHASUMS256.txt | grep " node-v24.21.0-linux-arm64.tar.gz$" | sed "s/node-v24.21.0-linux-arm64.tar.gz/node.tar.gz/" | sha256sum -c -
      tar -xzf node.tar.gz -C $N --strip-components=1; rm node.tar.gz; fi
    for rt in claude codex; do
      case $rt in claude) pkg=claude-agent-acp exe=npx;; codex) pkg=codex-acp exe=codex-acp;; esac
      P=$T/$rt/pin; [ -f $P/ok ] && { echo "$rt: there"; continue; }
      mkdir -p $P/lib $P/bin; cp /tmp/$rt-package.json $P/lib/package.json; cp /tmp/$rt-package-lock.json $P/lib/package-lock.json
      ln -sfn $N $P/node
      PATH=$N/bin:$PATH npm ci --ignore-scripts --omit=dev --no-audit --no-fund --prefix $P/lib --cache $P/.npm >/dev/null
      printf "%s\n" "#!/bin/sh" "d=\$(cd \"\$(dirname \"\$0\")/..\" && pwd -P)" "PATH=\"\$d/node/bin:\$PATH\" exec \"\$d/node/bin/node\" \"\$d/lib/node_modules/@agentclientprotocol/$pkg/dist/index.js\" \"\$@\"" > $P/bin/$exe
      chmod 700 $P/bin/$exe; : > $P/ok; [ -e $T/$rt/current/ok ] || ln -sfn pin $T/$rt/current; echo "$rt: installed"
    done'
  exit ;;
esac
"$here/go.sh" build -trimpath -ldflags "-s -w" -o out/agentsd-linux-arm64 ./cmd/agentsd
scp -q -P 2222 -o UserKnownHostsFile="$HOME/.cache/agents-devbox/known_hosts" -i "$HOME/.ssh/id_ed25519" \
  "$here/out/agentsd-linux-arm64" agents@127.0.0.1:/home/agents/agentsd-go.new
join=""
if [ "$1" = join ]; then join="--control '$2'"; fi
ssh_ "set -e; R=\$HOME/.agents-go/root; for l in supervise daemon; do if [ -f \$R/\$l.lock ]; then kill \$(cat \$R/\$l.lock) 2>/dev/null || true; fi; done; sleep 1
  mv ~/agentsd-go.new ~/agentsd-go; chmod 700 ~/agentsd-go
  [ -n \"$join\" ] && rm -f \$R/control-host.json
  AGENTS_DEBUG_PANIC=${DEBUG_PANIC:-0} AGENTS_SANDBOX=${SANDBOX:-0} AGENTS_MACHINE_ID=go-devbox ~/agentsd-go --root \$R --serve --detach --control-network $join --host-name 'devbox (Go)'
  sleep 2; tail -n 5 \$R/daemon.log"
