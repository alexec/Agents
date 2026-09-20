#!/bin/zsh
# Ask every runtime what tools it has today, and say which of them the policy accounts for.
#
# `acp-handshake.sh` answers "does the app do something with everything a runtime
# advertises". This one answers "does ToolPolicyCatalog still cover everything a runtime
# offers". Both are claims about somebody else's software, so both are worth re-running
# whenever a runtime updates — a tool that did not exist last week exists this week, and
# the first sign of a policy that has stopped covering what it claims to is an agent doing
# something the app cannot see.
#
#   ./scripts/runtime-tools.sh              # every runtime
#   ./scripts/runtime-tools.sh grok         # one of them
#
# A report to read, not a gate to pass. ACP has no method that lists an agent's tools, so
# the inventory below is the agent's own prose about itself: good enough to notice that a
# removal stopped working, not good enough to trust for an exact id. A tool printed as NEW
# is a question for a person.
set -u

python3 - "$@" <<'PY'
import json, os, queue, re, subprocess, sys, tempfile, threading, time

# A copy of RuntimeCatalog.builtIn and ToolPolicyCatalog, deliberately.
#
# The Swift is kept honest by its own unit tests — they are what assert the table is total
# and that each lever produces the right wire shape. This script exists to catch a
# *runtime* that moved, not a table that did, and it has to be able to run without a build.
RUNTIMES = {
    "claude": ["npx", "-y", "@agentclientprotocol/claude-agent-acp"],
    "grok": ["grok", "agent", "stdio"],
    "copilot": ["copilot", "--acp"],
    # Not "agent", which is what Cursor calls itself and what Grok installs.
    "cursor": ["cursor-agent", "acp"],
}

CLIENT = {
    "fs": {"readTextFile": True, "writeTextFile": True},
    "terminal": True,
    "session": {"configOptions": {"boolean": {}}, "compaction": {}},
    "plan": {},
    "auth": {"terminal": True},
    "elicitation": {"form": {}, "url": {}},
}

GROK_KEEP = ["read_file", "list_dir", "grep", "search_replace", "write",
             "run_terminal_command", "todo_write", "ask_user_question",
             "web_search", "web_fetch", "open_page", "open_page_with_find"]

GROK_OVERLAY = """# Written by the Agents app. Do not edit: rebuilt on every launch.
[features]
image_gen = false
video_gen = false
"""

POLICIES = {
    "claude": {
        "removed": ["Workflow", "CronCreate", "CronList", "CronDelete", "ScheduleWakeup",
                    "Monitor", "RemoteTrigger", "PushNotification", "Agent", "ListAgents",
                    "SendMessage", "TaskOutput", "TaskStop", "ReportFindings", "DesignSync",
                    "mcp__claude_ai_Claude_Docs", "mcp__claude_ai_Google_Drive"],
        "kept": ["AskUserQuestion"],
        "residue": [],
        "meta": {"claudeCode": {"options": {"disallowedTools": None}}},  # filled from removed
        "args": [],
        "env": {},
    },
    "grok": {
        "removed": ["scheduler_create", "scheduler_delete", "scheduler_list", "send_feedback",
                    "spawn_subagent", "kill_command_or_subagent", "get_command_or_subagent_output"],
        "kept": GROK_KEEP,
        "residue": ["workflow", "monitor"],
        "meta": {"agentProfile": {"name": "agents-app",
                                  "description": "An agent hosted by the Agents app.",
                                  "tools": GROK_KEEP}},
        "args": [],
        "env": {"GROK_CONFIG_PATH": GROK_OVERLAY},  # written to a temp file below
    },
    "copilot": {
        "removed": ["task", "list_agents", "read_agent", "write_agent", "session_store_sql"],
        "kept": [],
        "residue": ["search_code_subagent"],
        "meta": None,
        "args": ["--disable-mcp-server", "software-factory", "--disable-builtin-mcps",
                 "--excluded-tools", "task", "list_agents", "read_agent", "write_agent",
                 "session_store_sql"],
        "env": {},
    },
    "cursor": {
        "removed": [],
        "kept": [],
        "residue": ["Task", "CreateGoal", "UpdateGoal"],
        "meta": None,
        "args": [],
        "env": {},
    },
}

POLICIES["claude"]["meta"]["claudeCode"]["options"]["disallowedTools"] = POLICIES["claude"]["removed"]

# What makes a tool name worth a person's attention. A tool that merely does something
# unrelated to this app's remit is left alone (FR-010), so the report would be useless if
# it listed every tool a runtime has. These are the words that mean "this duplicates
# something the app owns" — the same five categories the policy is written in.
SUSPECT = ["schedul", "cron", "wakeup", "wake_up", "timer", "monitor", "workflow", "goal",
           "escalat", "notify", "notification", "push", "feedback", "remind",
           "subagent", "spawn", "agent_", "_agent", "agents", "task",
           "doc", "drive", "sheet", "artifact", "artefact", "session_store", "findings",
           "suggest", "prompt_", "followup", "follow_up"]

ASKING = ("List the exact name of every tool you can call, one per line, with no other "
          "text and no commentary. Do not call any tool to answer; just list them.")

path = subprocess.run(["/bin/zsh", "-lc", 'printf %s "$PATH"'],
                      capture_output=True, text=True).stdout
BASE_ENV = dict(os.environ)
BASE_ENV["PATH"] = path


def ask(name, command, policy, scoped):
    """Start a runtime, make a session, and hand back what it says about its own tools."""
    arguments = list(command) + (policy["args"] if scoped else [])
    environment = dict(BASE_ENV)
    if scoped:
        for variable, contents in policy["env"].items():
            handle = tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False)
            handle.write(contents)
            handle.close()
            environment[variable] = handle.name
    work = tempfile.mkdtemp(prefix="agents-tools-")
    try:
        process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True, bufsize=1,
                                   cwd=work, env=environment)
    except FileNotFoundError:
        return None

    incoming = queue.Queue()
    threading.Thread(target=lambda: [incoming.put(line) for line in process.stdout] or incoming.put(None),
                     daemon=True).start()
    lock = threading.Lock()

    def send(message):
        with lock:
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

    def call(identifier, method, params, deadline):
        send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
        said = []
        while time.time() < deadline:
            try:
                line = incoming.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                break
            if line is None:
                break
            try:
                message = json.loads(line.strip())
            except Exception:
                continue
            # A request from the agent. Refuse the permission ones — this is a question
            # about tools, and nothing here should be allowed to change anything — and
            # tell it plainly that we do not know the rest.
            if "method" in message and "id" in message:
                if message["method"] == "session/request_permission":
                    options = (message.get("params") or {}).get("options") or []
                    refusal = next((o for o in options if "reject" in (o.get("kind") or "")), None)
                    outcome = ({"outcome": "selected", "optionId": refusal["optionId"]}
                               if refusal else {"outcome": "cancelled"})
                    send({"jsonrpc": "2.0", "id": message["id"], "result": {"outcome": outcome}})
                else:
                    send({"jsonrpc": "2.0", "id": message["id"],
                          "error": {"code": -32601, "message": "not supported here"}})
                continue
            if message.get("method") == "session/update":
                update = (message.get("params") or {}).get("update") or {}
                if update.get("sessionUpdate") == "agent_message_chunk":
                    text = ((update.get("content") or {}).get("text")) or ""
                    # Not everything said in a session is the agent speaking. Copilot
                    # confirms its own scoping as agent message text rather than on
                    # stderr — "Info: Disabled tools: list_agents, read_agent, ..." —
                    # which is the wrinkle R5 wrote down. Left in, the inventory would
                    # contain, verbatim, the names that were just taken away, and this
                    # report would say THE LEVER DID NOT TAKE IT at the exact moment it
                    # did. Measured: that is precisely what it said before this line.
                    if not text.strip().startswith("Info:"):
                        said.append(text)
                continue
            if message.get("id") == identifier:
                return message.get("result"), "".join(said)
        return None, "".join(said)

    try:
        result, _ = call(1, "initialize",
                         {"protocolVersion": 1, "clientCapabilities": CLIENT},
                         time.time() + 60)
        if result is None:
            return None
        params = {"cwd": work, "mcpServers": []}
        if scoped and policy["meta"] is not None:
            params["_meta"] = policy["meta"]
        result, _ = call(2, "session/new", params, time.time() + 90)
        if result is None:
            return None
        session = result.get("sessionId")
        _, said = call(3, "session/prompt",
                       {"sessionId": session, "prompt": [{"type": "text", "text": ASKING}]},
                       time.time() + 240)
        return said
    finally:
        process.kill()


WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")


def names(said):
    return {word for word in WORD.findall(said or "")}


def report(name):
    command, policy = RUNTIMES[name], POLICIES[name]
    print(f"\n== {name}")
    scoped = ask(name, command, policy, scoped=True)
    if scoped is None:
        print("   not installed, or would not answer")
        return 0
    if not scoped.strip():
        print("   started, but said nothing about its tools")
        return 0

    if not policy["removed"] and not policy["args"] and policy["meta"] is None:
        print("   no lever on this runtime; everything conflicting is residue")
    else:
        # Substring rather than word match: a name may be a whole server
        # (`mcp__claude_ai_Google_Drive`) that the runtime spells out per tool.
        gone = [tool for tool in policy["removed"] if tool not in scoped]
        print(f"   removed ({len(gone)} of {len(policy['removed'])})")
        for tool in policy["removed"]:
            if tool in scoped:
                print(f"   STILL THERE {tool:38} THE LEVER DID NOT TAKE IT")

    present = [tool for tool in policy["kept"] if tool in scoped]
    if policy["kept"]:
        missing = [tool for tool in policy["kept"] if tool not in scoped]
        print(f"   kept    {', '.join(present) or '—'}")
        for tool in missing:
            # The one failure that matters more than anything this feature fixes.
            print(f"   GONE    {tool:38} KEPT ON PURPOSE AND NOT THERE")

    if policy["residue"]:
        still = [tool for tool in policy["residue"] if tool in scoped]
        print(f"   residue {', '.join(still) or '—':38} covered by the briefing")
        for tool in policy["residue"]:
            if tool not in still:
                print(f"   FREED   {tool:38} removable now? move it out of residue")

    accounted = set(policy["removed"]) | set(policy["kept"]) | set(policy["residue"])
    unaccounted = sorted(
        word for word in names(scoped)
        if any(hint in word.lower() for hint in SUSPECT)
        and not any(word in known or known in word for known in accounted))
    print(f"   NEW     {', '.join(unaccounted) if unaccounted else '—':38}"
          f"{' NOT IN THE POLICY' if unaccounted else ''}")
    return len(unaccounted)


wanted = sys.argv[1:] or list(RUNTIMES)
unknown = [name for name in wanted if name not in RUNTIMES]
if unknown:
    print(f"no runtime called {', '.join(unknown)}; try {', '.join(RUNTIMES)}")
    sys.exit(2)

total = sum(report(name) for name in wanted)
print(f"\n{total} tools offered by a runtime that the policy neither removes, keeps, nor explains.")
print("A NEW tool is a question for a person, not a failure: either it gets a line in")
print("ToolPolicyCatalog or it is one of the many that duplicate nothing of ours.")
sys.exit(total)
PY
