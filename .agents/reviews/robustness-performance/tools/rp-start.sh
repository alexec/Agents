#!/bin/bash
# Start (or restart) the scratch host on /tmp/run-rp2 and time the socket's first answer.
# Save the scratch host's command line first: ps -o command= -p $(head -1 $ROOT/daemon.lock) > $ROOT/daemon.cmd
ROOT=/tmp/run-rp2
P=$(head -1 $ROOT/daemon.lock 2>/dev/null)
if [ -n "$P" ] && kill -0 $P 2>/dev/null && ps -o command= -p $P | grep -q agentsd; then kill $P; while kill -0 $P 2>/dev/null; do sleep 0.1; done; fi
LINE=$(cat $ROOT/daemon.cmd)
CMD=${LINE% --control-code *}; CODE=${LINE##* --control-code }
[ "$1" = noindex ] && mv $ROOT/archive.json $ROOT/archive.json.aside 2>/dev/null
T0=$(python3 -c 'import time;print(time.time())')
env -u CLAUDECODE $(env | grep -oE '^CLAUDE_[A-Z_]+' | sed 's/^/-u /') AGENTS_TEST_RUNTIME=echo AGENTS_ROOT=$ROOT nohup "$CMD" --control-code "$CODE" >>$ROOT/host.out 2>&1 &
python3 - "$T0" <<'PY'
import socket, sys, time
t0=float(sys.argv[1])
while True:
    try:
        s=socket.socket(socket.AF_UNIX); s.connect('/tmp/run-rp2/daemon.sock')
        s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"daemon/ping"}\n'); s.settimeout(60); d=s.recv(100)
        if d: break
    except Exception: time.sleep(0.02)
print(f"socket answers {1000*(time.time()-t0):.0f} ms after exec")
s.sendall(b'{"jsonrpc":"2.0","id":2,"method":"agents/list","params":{"lean":true,"includeArchived":false}}\n')
buf=b''
while b'\n' not in buf: buf+=s.recv(1<<20)
print(f"first lean list {1000*(time.time()-t0):.0f} ms after exec")
PY
sleep 1; grep "uplink: connected" $ROOT/daemon.log | tail -1
ls -la $ROOT/archive.json 2>/dev/null | awk '{print "archive.json", $5}'
