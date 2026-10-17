#!/bin/bash
# The ssh options of contracts/ssh.md § Options from the person's config (#610), each tried
# against the devbox (test-servers: devbox.sh up) with the arguments the control plane
# passes. Nothing of the person's ~/.ssh is read or written: every config is written here.
set -u
D=$(mktemp -d /tmp/ssh-options.XXXX); trap 'rm -rf "$D"' EXIT; cd "$D" || exit
K="$D/known_hosts"
devbox=~/.cache/agents-devbox/known_hosts
{ cat "$devbox"; sed 's/^\[127\.0\.0\.1\]:2222 /127.0.0.1 /' "$devbox" | grep '^127'; sed 's/^\[127\.0\.0\.1\]:2222 /localhost /' "$devbox" | grep '^localhost'; } > "$K"
B="-o BatchMode=yes -o ConnectTimeout=10"; Q="-o RemoteCommand=none -o RequestTTY=no -o ClearAllForwardings=yes"; O="-o ControlMaster=no -o ControlPath=none"; S="-o StrictHostKeyChecking=yes"
base(){ printf 'Host %s\n  HostName 127.0.0.1\n  Port 2222\n  User agents\n  IdentityFile ~/.ssh/id_ed25519\n  IdentitiesOnly yes\n  UserKnownHostsFile %s\n' "$1" "${2:-$K}"; }
run(){ name=$1; shift; out=$(ssh $B "$@" 2>&1 </dev/null); echo "[$name] status=$? :: $(echo "$out" | tr '\n' '|' | cut -c1-170)"; }
base box > c1; run "HostName/User/Port, an alias" -F c1 $S $Q $O -- box 'whoami'
run "ssh://user@host:port" -F c1 $S $Q $O -o UserKnownHostsFile=$K -i ~/.ssh/id_ed25519 -- ssh://agents@127.0.0.1:2222 'whoami'
run "user@host (Port from a Match-less default)" -F c1 $S $Q $O -o UserKnownHostsFile=$K -i ~/.ssh/id_ed25519 -p 2222 -- agents@127.0.0.1 'whoami'
printf 'Host ag\n  HostName 127.0.0.1\n  Port 2222\n  User agents\n  IdentityAgent %s\n  UserKnownHostsFile %s\n' "$SSH_AUTH_SOCK" $K > c3
# Only meaningful when the agent holds a key that logs in there; never added here.
echo "agent: $(ssh-add -l 2>&1 | head -1 | cut -c1-60)"
printf 'Host ag\n  HostName 127.0.0.1\n  Port 2222\n  User agents\n  IdentityAgent %s\n  IdentityFile none\n  UserKnownHostsFile %s\n' "$SSH_AUTH_SOCK" $K > c3; run "IdentityAgent (agent only)" -F c3 $S $Q $O -- ag 'whoami'
# A hop is its own ssh: it reads only the config, so the defaults are under Host *.
printf 'Host hop1\n  HostName 127.0.0.1\n  Port 2222\nHost chained\n  HostName localhost\n  Port 22\n  ProxyJump hop1,agents@127.0.0.1:22\nHost *\n  User agents\n  IdentityFile ~/.ssh/id_ed25519\n  UserKnownHostsFile %s\n' $K > c4
run "ProxyJump chain (two hops)" -F c4 $S $Q $O -- chained 'whoami'
{ base pc0; printf 'Host pc\n  HostName 127.0.0.1\n  Port 22\n  User agents\n  ProxyCommand ssh -F %s -W %%h:%%p pc0\n  IdentityFile ~/.ssh/id_ed25519\n  UserKnownHostsFile %s\n' "$PWD/c5" $K; } > c5
run "ProxyCommand" -F c5 $S $Q $O -- pc 'whoami'
base inc > inc.conf; printf 'Include %s/inc.conf\nMatch host matched\n  HostName 127.0.0.1\n  Port 2222\n  User agents\n  IdentityFile ~/.ssh/id_ed25519\n  UserKnownHostsFile %s\n' "$PWD" $K > c6
run "Include" -F c6 $S $Q $O -- inc 'whoami'; run "Match host" -F c6 $S $Q $O -- matched 'whoami'
printf 'Match exec "true"\n  HostName 127.0.0.1\n  Port 2222\n  User agents\n  IdentityFile ~/.ssh/id_ed25519\n  UserKnownHostsFile %s\n' $K > c7; run "Match exec" -F c7 $S $Q $O -- anything 'whoami'
base dn /dev/null > c9; printf '  StrictHostKeyChecking no\n' >> c9
run "UserKnownHostsFile /dev/null, as given" -F c9 $S $Q $O -- dn 'whoami'
run "UserKnownHostsFile /dev/null, ours (#514)" -F c9 $S -o "UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts2" $Q $O -- dn 'whoami'
: > empty; base sk "$PWD/empty" > c10; printf '  StrictHostKeyChecking accept-new\n' >> c10
run "StrictHostKeyChecking accept-new in config, key unknown" -F c10 $S $Q $O -- sk 'whoami'; echo "  that known_hosts is still empty: $( [ -s empty ] && echo NO || echo yes)"
base sn "$PWD/empty" > c10b; printf '  StrictHostKeyChecking no\n' >> c10b
run "StrictHostKeyChecking no in config, key unknown" -F c10b $S $Q $O -- sn 'whoami'
cp $K hashed; ssh-keygen -H -f hashed >/dev/null 2>&1; rm -f hashed.old; base hk "$PWD/hashed" > c11; printf '  HashKnownHosts yes\n' >> c11
run "HashKnownHosts (hashed file)" -F c11 $S $Q $O -- hk 'whoami'
base cm > c12; printf '  ControlMaster auto\n  ControlPath %s/cm-%%C\n  ControlPersist 600\n' "$PWD" >> c12
run "ControlMaster auto + ControlPersist 600" -F c12 $S $Q $O -- cm 'whoami'; echo "  their ControlPath sockets left: $(ls cm-* 2>/dev/null | wc -l | tr -d ' ')"
base ct > c14; printf '  ConnectTimeout 1\n  ServerAliveInterval 5\n' >> c14; run "ConnectTimeout/ServerAliveInterval in config" -F c14 $S $Q $O -- ct 'whoami'
base se > c16; printf '  SetEnv FOO=bar\n  SendEnv LANG LC_*\n' >> c16; run "SetEnv/SendEnv" -F c16 $S $Q $O -- se 'whoami'
base rt > c17; printf '  RequestTTY force\n  RemoteCommand echo theirs\n' >> c17
run "RequestTTY force + RemoteCommand, ours" -F c17 $S $Q $O -- rt 'whoami'
echo "  bytes back: $(ssh $B -F c17 $S $Q $O -- rt 'echo hi' 2>/dev/null </dev/null | od -c | head -1)"
run "RequestTTY force + RemoteCommand, without ours" -F c17 $S -- rt 'whoami'
base fw > c15; printf '  RemoteForward 127.0.0.1:22 127.0.0.1:9\n  LocalForward 127.0.0.1:18777 127.0.0.1:22\n  DynamicForward 127.0.0.1:18778\n  ExitOnForwardFailure yes\n' >> c15
run "Local/Remote/DynamicForward + ExitOnForwardFailure, ours" -F c15 $S $Q $O -- fw 'whoami'
run "Local/Remote/DynamicForward + ExitOnForwardFailure, without ours" -F c15 $S -- fw 'whoami'
base cf > c8; printf '  CertificateFile ~/.ssh/id_ed25519-cert.pub\n' >> c8; echo "[CertificateFile] ssh -G says: $(ssh -F c8 -G cf | grep -i certificatefile)"; run "CertificateFile (none on disk)" -F c8 $S $Q $O -- cf 'whoami'
