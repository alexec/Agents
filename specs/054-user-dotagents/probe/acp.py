#!/usr/bin/env python3
# The 054 ACP probe (research R9): what each runtime does with MCP servers and personal plugins
# when started the way the app starts it, over ACP, rather than as a CLI.
#
#   acp.py <runtime> [--init-only]
#
# Run by run.sh with HOME already the scratch home. It starts the runtime's ACP adapter,
# records the initialize reply's mcpCapabilities, opens a session carrying three servers in
# mcpServers — heron-mcp (stdio), egret-mcp (http, served here) and shared (stdio, a name the
# runtime's own config also uses, see run.sh setup-mcp) — plus the plugin handover the app
# would use for that runtime, asks one question with no tools, and prints the answer beside
# the servers' own log, which is the evidence: a server that never logged `tools/list` was
# never offered to the model, whatever the model says.
import json, os, queue, subprocess, sys, threading, time

P = "/tmp/dotagents-probe"
H = os.environ["HOME"]
REAL = os.environ["PROBE_REAL_HOME"]
HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "mcp-server.py")
LOG = f"{P}/log/mcp.log"
PORT = 8799
PLUGIN = f"{H}/.agents/plugins/heron-plugin"
TOOLS = f"{REAL}/Library/Application Support/Agents/tools"

COMMANDS = {
    "claude": ["npx", "-y", "@agentclientprotocol/claude-agent-acp"],
    "grok": [f"{REAL}/.local/bin/grok", "agent", "stdio"],
    "copilot": ["/opt/homebrew/bin/copilot", "--acp"],
    "cursor": [f"{REAL}/.local/bin/cursor-agent", "acp"],
    "codex": [f"{TOOLS}/codex/current/bin/codex-acp"],
    "gemini": [f"{TOOLS}/gemini/current/bin/gemini", "--acp", "--skip-trust"],
}

# The app's own handover of project plugins (DotAgents.swift), pointed at the personal folder.
META = {
    "claude": {"claudeCode": {"options": {"plugins": [{"type": "local", "path": PLUGIN}]}}},
    "grok": {"pluginDirs": [PLUGIN]},
}

ASK = ("Do not use any tools. Answer in exactly three lines.\n"
       "Line 1: MCP: the name of every MCP tool available to you, comma-separated (or NONE).\n"
       "Line 2: SKILLS: the names of every Agent Skill available to you, comma-separated (or NONE).\n"
       "Line 3: COMMANDS: every slash command that came from a plugin, comma-separated (or NONE).")


def stdio(name, tag):
    server = {"name": name, "command": "python3", "args": [SERVER, tag],
              "env": [{"name": "PROBE_LOG", "value": LOG}]}
    # PROBE_STDIO_TYPE=1 adds the `type` ACP leaves out for stdio, to see if a runtime needs it.
    if os.environ.get("PROBE_STDIO_TYPE"):
        server["type"] = "stdio"
    return server


def main():
    runtime, init_only = sys.argv[1], "--init-only" in sys.argv
    os.makedirs(f"{P}/log", exist_ok=True)
    open(LOG, "w").close()
    http = subprocess.Popen(["python3", SERVER, "egret-mcp", "--http", str(PORT)],
                            env={**os.environ, "PROBE_LOG": LOG})
    proc = subprocess.Popen(COMMANDS[runtime], cwd=f"{P}/proj", stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=open(f"{P}/log/{runtime}.stderr", "w"),
                            env={**os.environ, "PROBE_LOG": LOG}, text=True, bufsize=1)
    inbox, pending, said = queue.Queue(), {}, []
    next_id = [0]

    def reader():
        for line in proc.stdout:
            try:
                inbox.put(json.loads(line))
            except ValueError:
                pass
        inbox.put(None)

    threading.Thread(target=reader, daemon=True).start()

    def send(obj):
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
            if "method" in msg and "id" in msg:  # a request to the client: refuse politely
                if msg["method"] == "session/request_permission":
                    send({"jsonrpc": "2.0", "id": msg["id"],
                          "result": {"outcome": {"outcome": "cancelled"}}})
                else:
                    send({"jsonrpc": "2.0", "id": msg["id"],
                          "error": {"code": -32601, "message": "not in the probe"}})
            elif msg.get("method") == "session/update":
                update = msg["params"].get("update", {})
                if update.get("sessionUpdate") == "agent_message_chunk":
                    said.append(update.get("content", {}).get("text", ""))
        return {"error": f"no reply to {method} in {timeout}s"}

    result = {"runtime": runtime}
    try:
        init = call("initialize", {"protocolVersion": 1, "clientCapabilities": {
            "fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}}, 120)
        caps = init.get("result", {}).get("agentCapabilities", {})
        result["mcpCapabilities"] = caps.get("mcpCapabilities", "absent")
        result["authMethods"] = [m.get("id") for m in init.get("result", {}).get("authMethods", [])]
        if "error" in init:
            result["initialize"] = init["error"]
        if init_only or "error" in init:
            return result
        params = {"cwd": f"{P}/proj", "mcpServers": [
            stdio("heron-mcp", "heron-mcp"),
            {"type": "http", "name": "egret-mcp", "url": f"http://127.0.0.1:{PORT}/mcp", "headers": []},
            stdio("shared", "shared-from-request"),
        ]}
        if runtime in META:
            params["_meta"] = META[runtime]
        new = call("session/new", params, 180)
        if "error" in new:
            result["session/new"] = new["error"]
            return result
        sid = new["result"]["sessionId"]
        time.sleep(5)  # let servers the runtime starts lazily get going before the turn
        turn = call("session/prompt", {"sessionId": sid,
                                       "prompt": [{"type": "text", "text": ASK}]}, 240)
        result["stopReason"] = turn.get("result", {}).get("stopReason", turn.get("error"))
        result["answer"] = "".join(said).strip()
        return result
    finally:
        proc.terminate()
        http.terminate()
        time.sleep(1)
        with open(LOG) as f:
            seen = {}
            for line in f:
                _, tag, _, method = line.split(maxsplit=3)
                seen.setdefault(tag, []).append(method.strip())
        result["servers"] = {tag: sorted(set(methods)) for tag, methods in seen.items()}
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
