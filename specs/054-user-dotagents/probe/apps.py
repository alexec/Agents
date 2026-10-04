#!/usr/bin/env python3
# The #186 MCP Apps probe: what a runtime tells its ACP client when the model calls an MCP tool
# whose definition carries _meta.ui.resourceUri (SEP-1865, 2026-01-26).
#
#   apps.py <runtime>
#
# Run by `run.sh apps <runtime>` with HOME already the scratch home. It starts the runtime's ACP
# adapter as the app does (RuntimeCatalog), opens a session with two copies of the probe server
# in --apps mode, kite-apps (http, served here) and heron-apps (stdio; left out for Copilot,
# which refuses stdio from a client), asks the model to call each one's weather tool, and keeps:
#
#   $P/log/<runtime>.acp.jsonl   every ACP line both ways, in full
#   $P/log/<runtime>.mcp.jsonl   every MCP message both ways, in full (PROBE_WIRE)
#   $P/log/<runtime>.json        the summary printed at the end
#
# The tool calls are read off the wire, not from the model.
import json, os, queue, subprocess, sys, threading, time

P = os.environ.get("PROBE_DIR", "/tmp/mcp-apps-probe")
H = os.environ["HOME"]
REAL = os.environ["PROBE_REAL_HOME"]
HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "mcp-server.py")
PORT = 8798
TOOLS = f"{REAL}/Library/Application Support/Agents/tools"

COMMANDS = {
    "claude": ["npx", "-y", "@agentclientprotocol/claude-agent-acp"],
    "copilot": ["/opt/homebrew/bin/copilot", "--acp"],
    "codex": [f"{TOOLS}/codex/current/bin/codex-acp"],
    "opencode": [f"{TOOLS}/opencode/current/bin/opencode", "acp"],
}

# What RuntimeLaunch adds for OpenCode (049): a TMPDIR of its own, no updates, no sharing.
ENV = {
    "opencode": {"TMPDIR": f"{P}/opencode-tmp", "OPENCODE_DISABLE_AUTOUPDATE": "1",
                 "OPENCODE_DISABLE_SHARE": "1"},
}

ASK = ("This is a test of MCP tools. Call the weather tool of the kite-apps MCP server for "
       "Paris{heron}. Call each tool exactly once and nothing else. Then answer in two lines.\n"
       "Line 1: TEXT: the text each tool returned, verbatim.\n"
       "Line 2: EXTRA: every other field you were shown in each result besides its text "
       "(for example structuredContent or _meta), with its values, or NONE.")
HERON = ", and the weather tool of the heron-apps MCP server for Oslo"


def main():
    runtime = sys.argv[1]
    logs = f"{P}/log"
    os.makedirs(logs, exist_ok=True)
    os.makedirs(f"{P}/opencode-tmp", exist_ok=True)
    acp_log, mcp_log = f"{logs}/{runtime}.acp.jsonl", f"{logs}/{runtime}.mcp.jsonl"
    for f in (acp_log, mcp_log, f"{logs}/{runtime}.mcp.log"):
        open(f, "w").close()
    env = {**os.environ, **ENV.get(runtime, {}),
           "PROBE_LOG": f"{logs}/{runtime}.mcp.log", "PROBE_WIRE": mcp_log}
    http = subprocess.Popen(["python3", SERVER, "kite-apps", "--http", str(PORT), "--apps"], env=env)
    proc = subprocess.Popen(COMMANDS[runtime], cwd=f"{P}/proj", stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=open(f"{logs}/{runtime}.stderr", "w"),
                            env=env, text=True, bufsize=1)
    inbox, said, calls = queue.Queue(), [], []
    next_id = [0]
    wire = open(acp_log, "a")

    def record(direction, obj):
        wire.write(json.dumps({"t": time.strftime("%H:%M:%S"), "dir": direction, "msg": obj}) + "\n")
        wire.flush()

    def reader():
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                record("<-raw", line.rstrip("\n"))
                continue
            record("<-", msg)
            inbox.put(msg)
        inbox.put(None)

    threading.Thread(target=reader, daemon=True).start()

    def send(obj):
        record("->", obj)
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    def call(method, params, timeout):
        next_id[0] += 1
        id = next_id[0]
        send({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
        end = time.time() + timeout
        while time.time() < end:
            try:
                msg = inbox.get(timeout=1)
            except queue.Empty:
                continue
            if msg is None:
                return {"error": "the runtime exited"}
            if msg.get("id") == id and "method" not in msg:
                return msg
            if "method" in msg and "id" in msg:
                if msg["method"] == "session/request_permission":
                    # Allow the probe's own tools once; the probe never runs anything else.
                    options = msg["params"].get("options", [])
                    allow = next((o for o in options if o.get("kind") == "allow_once"),
                                 next((o for o in options if o.get("kind", "").startswith("allow")), None))
                    outcome = ({"outcome": "selected", "optionId": allow["optionId"]} if allow
                               else {"outcome": "cancelled"})
                    send({"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": outcome}})
                else:
                    send({"jsonrpc": "2.0", "id": msg["id"],
                          "error": {"code": -32601, "message": "not in the probe"}})
            elif msg.get("method") == "session/update":
                update = msg["params"].get("update", {})
                kind = update.get("sessionUpdate")
                if kind == "agent_message_chunk":
                    said.append(update.get("content", {}).get("text", ""))
                elif kind in ("tool_call", "tool_call_update"):
                    calls.append(update)
        return {"error": f"no reply to {method} in {timeout}s"}

    result = {"runtime": runtime}
    try:
        init = call("initialize", {"protocolVersion": 1, "clientCapabilities": {
            "fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
            "clientInfo": {"name": "mcp-apps-probe", "version": "1"}}, 180)
        r = init.get("result", {})
        result["agentInfo"] = r.get("agentInfo")
        result["mcpCapabilities"] = r.get("agentCapabilities", {}).get("mcpCapabilities", "absent")
        if "error" in init:
            result["initialize"] = init["error"]
            return result
        servers = [{"type": "http", "name": "kite-apps", "url": f"http://127.0.0.1:{PORT}/mcp",
                    "headers": []}]
        if runtime != "copilot":
            servers.append({"name": "heron-apps", "command": "python3",
                            "args": [SERVER, "heron-apps", "--apps"],
                            "env": [{"name": "PROBE_LOG", "value": env["PROBE_LOG"]},
                                    {"name": "PROBE_WIRE", "value": mcp_log}]})
        new = call("session/new", {"cwd": f"{P}/proj", "mcpServers": servers}, 180)
        if "error" in new:
            result["session/new"] = new["error"]
            return result
        sid = new["result"]["sessionId"]
        result["models"] = new["result"].get("models", {}).get("currentModelId")
        time.sleep(5)  # let servers the runtime starts lazily get going before the turn
        ask = ASK.format(heron="" if runtime == "copilot" else HERON)
        turn = call("session/prompt", {"sessionId": sid,
                                       "prompt": [{"type": "text", "text": ask}]}, 300)
        result["stopReason"] = turn.get("result", {}).get("stopReason", turn.get("error"))
        result["answer"] = "".join(said).strip()
        result["toolCalls"] = calls
        return result
    finally:
        proc.terminate()
        http.terminate()
        time.sleep(1)
        with open(mcp_log) as f:
            msgs = [json.loads(line) for line in f if line.strip()]
        result["mcpInitialize"] = {m["server"]: m["msg"].get("params")
                                   for m in msgs if m["dir"] == "in" and m["msg"].get("method") == "initialize"}
        result["mcpMethods"] = {}
        for m in msgs:
            if m["dir"] == "in" and m["msg"].get("method"):
                result["mcpMethods"].setdefault(m["server"], [])
                if m["msg"]["method"] not in result["mcpMethods"][m["server"]]:
                    result["mcpMethods"][m["server"]].append(m["msg"]["method"])
        out = json.dumps(result, indent=2)
        open(f"{logs}/{runtime}.json", "w").write(out)
        print(out)


if __name__ == "__main__":
    main()
