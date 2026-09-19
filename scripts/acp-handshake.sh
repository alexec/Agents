#!/bin/zsh
# Ask every runtime what it can do, and say what this app does with each answer.
#
# This is how SC-002 is re-checked: every capability a runtime advertises has a
# matching action in the app. Worth running whenever a runtime updates, because the
# answer is a claim about somebody else's software rather than about ours.
#
#   ./scripts/acp-handshake.sh
set -u

python3 - "$@" <<'PY'
import json, os, queue, subprocess, sys, threading, time

RUNTIMES = {
    "claude": ["npx", "-y", "@agentclientprotocol/claude-agent-acp"],
    "grok": ["grok", "agent", "stdio"],
    "copilot": ["copilot", "--acp"],
    # Not "agent", which is what Cursor calls itself and what Grok installs.
    "cursor": ["cursor-agent", "acp"],
}

# What the app advertises today. Kept beside ACP.ClientCapabilities.app on purpose:
# if these drift, the report is about a client we are not shipping.
CLIENT = {
    "fs": {"readTextFile": True, "writeTextFile": True},
    "terminal": True,
    "session": {"configOptions": {"boolean": {}}, "compaction": {}},
    "plan": {},
    "auth": {"terminal": True},
    "elicitation": {"form": {}, "url": {}},
}

# Every capability an agent can advertise, against what the app does with it.
HANDLED = {
    "loadSession": "picking an agent back up",
    "promptCapabilities.image": "attaching a picture to a prompt",
    "promptCapabilities.audio": "NOT HANDLED (no runtime advertises it)",
    "promptCapabilities.embeddedContext": "attaching a file's contents",
    "sessionCapabilities.list": "finding conversations the app did not start",
    "sessionCapabilities.delete": "deleting a conversation, with a confirmation",
    "sessionCapabilities.fork": "branching an agent",
    "sessionCapabilities.resume": "picking an agent back up without a replay",
    "sessionCapabilities.close": "ending an agent without killing it",
    "sessionCapabilities.additionalDirectories": "giving an agent more folders",
    "sessionCapabilities.subagents": "OUT OF SCOPE (a vendor extension)",
    "auth.logout": "signing out from the app",
    "providers": "choosing who answers",
    "mcpCapabilities.http": "attaching an MCP server over http",
    "mcpCapabilities.sse": "attaching an MCP server over sse",
    "nes": "OUT OF SCOPE (an editor watching a buffer)",
    "positionEncoding": "OUT OF SCOPE (goes with nes)",
}

path = subprocess.run(["/bin/zsh", "-lc", 'printf %s "$PATH"'],
                      capture_output=True, text=True).stdout
env = dict(os.environ)
env["PATH"] = path

def handshake(name, command):
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
    except FileNotFoundError:
        return None
    out = queue.Queue()
    threading.Thread(target=lambda: [out.put(line) for line in process.stdout] or out.put(None),
                     daemon=True).start()
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": {"protocolVersion": 1,
                                               "clientCapabilities": CLIENT}}) + "\n")
    process.stdin.flush()
    deadline = time.time() + 60
    result = None
    while time.time() < deadline:
        try:
            line = out.get(timeout=max(0.1, deadline - time.time()))
        except queue.Empty:
            break
        if line is None:
            break
        try:
            message = json.loads(line.strip())
        except Exception:
            continue
        if message.get("id") == 1:
            result = message.get("result")
            break
    process.kill()
    return result

# The protocol says a capability is advertised by being present: most of them are an
# empty object, which is easy to read as "nothing here" and is the opposite.
CONTAINERS = ("promptCapabilities", "sessionCapabilities", "mcpCapabilities", "auth")

def flatten(value, prefix=""):
    found = {}
    for key, inner in (value or {}).items():
        name = f"{prefix}{key}"
        if key.startswith("_"):
            continue
        if isinstance(inner, dict):
            if name not in CONTAINERS:
                found[name] = True
            found.update(flatten(inner, f"{name}."))
        elif inner is True:
            found[name] = True
    return found

missing = 0
for name, command in RUNTIMES.items():
    print(f"\n== {name}")
    result = handshake(name, command)
    if result is None:
        print("   not installed, or would not answer")
        continue
    info = result.get("agentInfo") or {}
    print(f"   {info.get('name', name)} {info.get('version', '')}, protocol {result.get('protocolVersion')}")
    advertised = flatten(result.get("agentCapabilities"))
    for capability in sorted(advertised):
        if capability.startswith("_meta"):
            continue
        action = HANDLED.get(capability)
        if action is None:
            # Something new. This is the line worth acting on: either it gets an
            # action in the app or a reason in the spec's Out of Scope section.
            action = "NOT HANDLED, and not written down anywhere"
        if action.startswith("NOT HANDLED"):
            missing += 1
        print(f"   {capability:45} {action}")
    methods = result.get("authMethods") or []
    if methods:
        print(f"   authMethods: {', '.join(m.get('id', '?') for m in methods)}")

print(f"\n{missing} advertised capabilities with neither an action in the app nor a reason in the spec.")
sys.exit(1 if missing else 0)
PY
