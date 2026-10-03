#!/bin/bash
# Restart the scratch host on /tmp/run-rp and time the socket's first answer.
ROOT=/tmp/run-rp
P=$(head -1 $ROOT/daemon.lock)
CMD=$(ps -o command= -p $P | sed 's/ --control-code .*//')
CODE=$(ps -o command= -p $P | sed 's/.* --control-code //')
kill $P; while kill -0 $P 2>/dev/null; do sleep 0.1; done
[ "$1" = noindex ] && mv $ROOT/archive.json $ROOT/archive.json.aside
T0=$(python3 -c 'import time;print(time.time())')
env -u CLAUDECODE $(env | grep -oE '^CLAUDE_[A-Z_]+' | sed 's/^/-u /') AGENTS_ROOT=$ROOT nohup "$CMD" --control-code "$CODE" >>$ROOT/host.out 2>&1 &
python3 - "$T0" <<'PY'
import socket, sys, time, json
t0=float(sys.argv[1])
while True:
    try:
        s=socket.socket(socket.AF_UNIX); s.connect('/tmp/run-rp/daemon.sock')
        s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"daemon/ping"}\n'); s.settimeout(30); d=s.recv(100)
        if d: break
    except Exception: time.sleep(0.02)
t1=time.time(); print(f"socket answers {1000*(t1-t0):.0f} ms after exec")
s.sendall(b'{"jsonrpc":"2.0","id":2,"method":"agents/list","params":{"lean":true,"includeArchived":false}}\n')
buf=b''
while b'\n' not in buf: buf+=s.recv(1<<20)
print(f"first lean list {1000*(time.time()-t0):.0f} ms after exec")
PY
sleep 1; grep "uplink: connected" $ROOT/daemon.log | tail -1
ls -la $ROOT/archive.json | awk '{print "archive.json", $5, $8}'
