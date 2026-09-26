#!/bin/zsh
# 047 option 2 trial: Codex on agents-bare signed in through this Mac's ChatGPT sign-in, which
# never leaves the Mac. The box gets only a stand-in (invalid signature, no refresh token).
# Writes /tmp/codex-relay/trial.log (paths, statuses, the reply text; no tokens).
set -eu
cd /Users/alexcollins/Agents/.agents/worktrees/speckit-specify-support-codex
T=.claude/skills/test-servers/scripts
SECRET=$(python3 -c "import secrets;print(secrets.token_hex(16))")
PORT=18765
exec > >(tee /tmp/codex-relay/trial.log) 2>&1
# 1. The box: the stand-in sign-in, and Codex's ChatGPT address pointed at the relay.
$T/bare.sh ssh 'cat > /tmp/codex-relay/home/auth.json && chmod 600 /tmp/codex-relay/home/auth.json' < /tmp/codex-relay/standin-auth.json
$T/bare.sh ssh "printf 'chatgpt_base_url = \"https://127.0.0.1:$PORT/$SECRET/backend-api/\"\n' > /tmp/codex-relay/home/config.toml"
$T/bare.sh ssh 'cat > /tmp/codex-relay/relay-ca.pem' < /tmp/codex-relay/relay-ca.pem
# 2. The relay on this Mac (127.0.0.1 only), stopped when this script ends.
: > /tmp/codex-relay/relay.log
python3 /tmp/codex-relay/relay.py $PORT $SECRET /tmp/codex-relay/relay-cert.pem /tmp/codex-relay/relay-key.pem & RELAY=$!
trap 'kill $RELAY 2>/dev/null' EXIT
sleep 1
# 3. A Codex turn on the box over ssh, with the relay reachable there through a reverse forward.
python3 - "$PORT" <<'PY'
import json, subprocess, sys, threading, queue, time
port=sys.argv[1]
cmd=["ssh","-o","BatchMode=yes","-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=/dev/null","-o","LogLevel=ERROR",
     "-o","ExitOnForwardFailure=yes","-R",f"{port}:127.0.0.1:{port}","-p","2223","agents@127.0.0.1",
     "cd /tmp/codex-relay && CODEX_HOME=/tmp/codex-relay/home CODEX_CA_CERTIFICATE=/tmp/codex-relay/relay-ca.pem NO_BROWSER=1 exec ./node/bin/node lib/node_modules/@agentclientprotocol/codex-acp/dist/index.js"]
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
q=queue.Queue(); threading.Thread(target=lambda:[q.put(l) for l in p.stdout],daemon=True).start()
def send(m): p.stdin.write(json.dumps(m)+"\n"); p.stdin.flush()
def wait(i,t=180):
    end=time.time()+t
    while time.time()<end:
        try: l=q.get(timeout=1)
        except queue.Empty: continue
        try: m=json.loads(l)
        except: continue
        if m.get("method")=="session/request_permission":
            send({"jsonrpc":"2.0","id":m["id"],"result":{"outcome":{"outcome":"selected","optionId":m["params"]["options"][0]["optionId"]}}})
        elif m.get("method")=="session/update":
            u=m["params"]["update"]
            if u.get("sessionUpdate")=="agent_message_chunk": sys.stdout.write(u["content"].get("text",""))
            elif u.get("sessionUpdate")=="tool_call": print("\n  tool:",u.get("title"))
        elif m.get("id")==i and ("result" in m or "error" in m): return m
    return {"timeout":True}
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":True,"writeTextFile":True},"terminal":False}}})
r=wait(1); print("authMethods:",[a["id"] for a in r.get("result",{}).get("authMethods",[])])
send({"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}})
r=wait(2); print("session/new:", "ok" if "result" in r else json.dumps(r)[:300])
if "result" in r:
    send({"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":r["result"]["sessionId"],"prompt":[{"type":"text","text":"Run uname -a and tell me its output in one line."}]}})
    r=wait(3); print("\nprompt:", json.dumps(r)[:400])
p.terminate()
PY
echo "--- relay log"; cat /tmp/codex-relay/relay.log
# 4. What the box holds afterwards: the stand-in only; nothing of the real sign-in.
$T/bare.sh ssh 'ls /tmp/codex-relay/home; grep -c relay-standin /tmp/codex-relay/home/auth.json'
