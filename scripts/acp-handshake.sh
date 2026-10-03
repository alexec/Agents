#!/bin/zsh
# Ask every runtime what it can do, and say what this app does with each answer.
#
# This is how SC-002 is re-checked: every capability a runtime advertises has a
# matching action in the app. Worth running whenever a runtime updates, because the
# answer is a claim about somebody else's software rather than about ours.
#
# It also opens one conversation per runtime, in an empty folder of its own, and reads
# the options the runtime offers there (#41): every option and every choice other than
# a model is written down in OPTIONS below, and one that is not is reported as NEW, as a
# capability is. So is a `_meta` key the runtime starts sending. The conversation is
# deleted again where the runtime can delete one, and closed where it can close one.
# A runtime that will not open one signed out says so, and is not a failure.
#
#   ./scripts/acp-handshake.sh                  the runtimes as the person signed them in
#   ./scripts/acp-handshake.sh --scratch-home   each with an empty HOME of its own, so
#                                               nothing of the person's is read or written
#   ./scripts/acp-handshake.sh --no-sessions    capabilities only, no conversation opened
#   ./scripts/acp-handshake.sh claude codex     only the runtimes named
#
# With AGENTS_HANDSHAKE_SESSIONS=<folder>, each runtime's answer to session/new is written
# there as <runtime>.json, so the options it offers (its models, say) can be read after.
set -u

python3 - "$@" <<'PY'
import json, os, queue, subprocess, sys, tempfile, threading, time

SCRATCH_HOME = "--scratch-home" in sys.argv[1:]
SESSIONS = "--no-sessions" not in sys.argv[1:]
NAMED = [a for a in sys.argv[1:] if not a.startswith("--")]
SESSIONS_OUT = os.environ.get("AGENTS_HANDSHAKE_SESSIONS")

RUNTIMES = {
    # AGENTS_CLAUDE_VERSION names the adapter version to run (#39's nightly), since a bare
    # npx -y can run whichever copy npx has cached.
    "claude": ["npx", "-y", "@agentclientprotocol/claude-agent-acp"
               + (f"@{os.environ['AGENTS_CLAUDE_VERSION']}" if os.environ.get("AGENTS_CLAUDE_VERSION") else "")],
    "grok": ["grok", "agent", "stdio"],
    "copilot": ["copilot", "--acp"],
    # Not "agent", which is what Cursor calls itself and what Grok installs.
    "cursor": ["cursor-agent", "acp"],
    # Never the person's npx or codex-acp (047, R1): the app's own toolset's shim, named by
    # AGENTS_CODEX_SHIM, e.g. <root>/tools/codex/current/bin/codex-acp.
    "codex": [os.environ.get("AGENTS_CODEX_SHIM", "agents-codex-shim-not-set")],
    # Never a gemini on the PATH (046, D1): the app's own toolset's shim.
    "gemini": [os.environ.get("AGENTS_GEMINI_SHIM", "agents-gemini-shim-not-set"), "--acp", "--skip-trust"],
    # Google's ACP server, never the agy CLI (049, R1): the app's own copy's shim, named by
    # AGENTS_ANTIGRAVITY_SHIM, e.g. <root>/tools/antigravity/current/bin/agy_acp_server.
    "antigravity": [os.environ.get("AGENTS_ANTIGRAVITY_SHIM", "agents-antigravity-shim-not-set")],
    # Never an opencode on the PATH (049, D1: two programs have that name): the app's own
    # copy's shim, named by AGENTS_OPENCODE_SHIM, e.g. <root>/tools/opencode/current/bin/opencode.
    "opencode": [os.environ.get("AGENTS_OPENCODE_SHIM", "agents-opencode-shim-not-set"), "acp"],
}

# What a runtime needs in its environment to run at all, scoped or not (049): Antigravity
# keeps everything under GEMINI_HOME, which must never be the person's ~/.gemini here, and
# signs in only with a key it is told to use (AGENTS_ANTIGRAVITY_KEY, optional).
import tempfile as _tempfile
RUNTIME_ENV = {
    "antigravity": {"GEMINI_HOME": _tempfile.mkdtemp(prefix="agents-agy-home-"),
                    "AGY_ACP_DISABLE_WORKSPACE_TRUST": "1",
                    **({"GEMINI_API_KEY": os.environ["AGENTS_ANTIGRAVITY_KEY"]}
                       if os.environ.get("AGENTS_ANTIGRAVITY_KEY") else {})},
    # OpenCode reads and writes its own config and data under the XDG folders: a scratch
    # home for each run, so the person's ~/.config/opencode is never read or touched.
    "opencode": (lambda home: {"HOME": home, "XDG_CONFIG_HOME": f"{home}/.config",
                               "XDG_DATA_HOME": f"{home}/.local/share", "XDG_CACHE_HOME": f"{home}/.cache",
                               "XDG_STATE_HOME": f"{home}/.local/state"})(_tempfile.mkdtemp(prefix="agents-opencode-home-")),
}
# Signed in with before any session, when the key above is given.
RUNTIME_AUTH = {"antigravity": "gemini-api-key"} if os.environ.get("AGENTS_ANTIGRAVITY_KEY") else {}

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
    "promptCapabilities.audio": "not offered: the composer attaches pictures and files, not sound (Gemini 046 and Antigravity 049 advertise it)",
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

# Every option a runtime offers in a conversation, against what the app does with it
# (#41; docs/reference/runtimes.md, "Options beyond model and mode"). The app draws every
# option a runtime sends under the prompt, so a new one reaches people unannounced: this
# is where it gets noticed and written down. The choices are listed for every option but
# the model, whose list changes every week and means nothing new for the app.
UNDER_PROMPT = "under the prompt, per agent"
OPTIONS = {
    "claude": {
        "mode": (["default", "acceptEdits", "plan", "auto", "bypassPermissions"], UNDER_PROMPT),
        "model": (None, UNDER_PROMPT),
        "effort": (["default", "low", "medium", "high", "xhigh", "max"], UNDER_PROMPT),
        "fast": ("boolean", UNDER_PROMPT + "; needs extra usage on the Claude plan"),
    },
    "codex": {
        "mode": (["read-only", "agent", "agent-full-access"], UNDER_PROMPT + "; its sandbox too (064, #40)"),
        "collaboration_mode": (["default", "plan"], UNDER_PROMPT),
        "model": (None, UNDER_PROMPT),
        "reasoning_effort": (["low", "medium", "high", "xhigh", "max"], UNDER_PROMPT),
        "fast-mode": ("boolean", UNDER_PROMPT),
    },
    "copilot": {
        "mode": (["https://agentclientprotocol.com/protocol/session-modes#agent",
                  "https://agentclientprotocol.com/protocol/session-modes#plan",
                  "https://agentclientprotocol.com/protocol/session-modes#autopilot"], UNDER_PROMPT),
        "model": (None, UNDER_PROMPT),
        "reasoning_effort": (["low", "medium", "high", "xhigh", "max"], UNDER_PROMPT),
        "allow_all": (["on", "off"], UNDER_PROMPT),
    },
    "cursor": {
        "mode": (["agent", "plan", "ask"], UNDER_PROMPT),
        # Each model's value carries its own settings, e.g. [effort=high,fast=false].
        "model": (None, UNDER_PROMPT),
    },
    "grok": {
        "model": (None, UNDER_PROMPT),
        "reasoning_effort": (["xhigh", "high", "medium", "low"], UNDER_PROMPT),
    },
    # From the older `modes` and `models`: Gemini 0.61.0 sends no configOptions.
    "gemini": {
        "mode": (["default", "autoEdit", "yolo", "plan"], UNDER_PROMPT),
        "model": (None, UNDER_PROMPT),
    },
    "antigravity": {
        "mode": (["default", "auto_edit", "yolo"], UNDER_PROMPT),
        # Thinking level is part of the model's name, e.g. gemini-3.8-flash-high.
        "model": (None, UNDER_PROMPT),
    },
    "opencode": {
        "mode": (["build", "plan"], UNDER_PROMPT),
        "model": (None, UNDER_PROMPT),
    },
}

# `_meta` keys a runtime sends back, by where, against what the app does with them. A
# vendor extension arrives here first, before any option does: Claude's goal and Grok's
# hooks were both offered here before either had a control anywhere.
READ_FOR_NOTHING = "read for nothing: "
META = {
    "initialize": {
        # Claude and Codex's adapters
        "steering": "Send now: a prompt sent into the running turn",
        "jetbrains": "sessionFailure read, for a failed turn's reason; the rest read for nothing",
        "goal": READ_FOR_NOTHING + "_session/goal, a standing objective (Claude, Codex), is not offered",
        # Grok: what it says about itself and its host, and its model list again.
        **{key: READ_FOR_NOTHING + "Grok describing itself" for key in [
            "agentId", "agentInstanceId", "agentVersion", "hostname", "currentWorkingDirectory",
            "defaultAuthMethodId", "metadata", "grokShell", "x.ai/mcp/sdk", "x.ai/pluginDirs"]},
        "modelState": READ_FOR_NOTHING + "the model option says the same, per model effort included",
        "availableCommands": READ_FOR_NOTHING + "the same commands arrive once the conversation opens",
        "mcpServers": READ_FOR_NOTHING + "Grok's own MCP servers; the app sends its own",
        "mcpApps": READ_FOR_NOTHING + "Grok's MCP apps",
        "cancelRewind": READ_FOR_NOTHING + "Grok's rewind on cancel",
        "feedbackTraceOffer": READ_FOR_NOTHING + "send_feedback is taken away (015)",
        "sessionRecap": READ_FOR_NOTHING + "Grok's recap of a picked-up conversation",
        "voiceMode": READ_FOR_NOTHING + "the composer sends no sound",
    },
    "agentCapabilities": {
        "claudeCode": READ_FOR_NOTHING + "promptQueueing; Send now goes by steering",
        "authStatus": "which account is signed in (RuntimeAccount)",
        "x.ai/fs_notify": READ_FOR_NOTHING + "Grok watching files the app writes",
        "x.ai/hooks": READ_FOR_NOTHING + "Grok's client hooks (pre_tool_use, stop): the app has none to offer",
        "x.ai/capabilities": READ_FOR_NOTHING + "Grok's X search tools, which the tool allowlist leaves out",
    },
    "session/new": {},
}

path = subprocess.run(["/bin/zsh", "-lc", 'printf %s "$PATH"'],
                      capture_output=True, text=True).stdout
env = dict(os.environ)
env["PATH"] = path

def scratch_home(name):
    """An empty home for one runtime, with the XDG folders inside it, for --scratch-home."""
    home = tempfile.mkdtemp(prefix=f"agents-handshake-{name}-")
    # Codex will not start with a CODEX_HOME that is not there.
    for folder in (".codex", ".copilot"):
        os.makedirs(f"{home}/{folder}")
    return {"HOME": home, "XDG_CONFIG_HOME": f"{home}/.config", "XDG_DATA_HOME": f"{home}/.local/share",
            "XDG_CACHE_HOME": f"{home}/.cache", "XDG_STATE_HOME": f"{home}/.local/state",
            "CODEX_HOME": f"{home}/.codex", "COPILOT_HOME": f"{home}/.copilot",
            # npx's cache is npm's, not the runtime's: kept, so Claude's adapter is not fetched again.
            "npm_config_cache": os.path.expanduser("~/.npm")}

class Conversation:
    """One runtime process, spoken to one request at a time."""

    def __init__(self, name, command):
        extra = {**(scratch_home(name) if SCRATCH_HOME else {}), **RUNTIME_ENV.get(name, {})}
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1,
                                        env={**env, **extra})
        self.out = queue.Queue()
        self.next_id = 0
        threading.Thread(target=lambda: [self.out.put(line) for line in self.process.stdout] or self.out.put(None),
                         daemon=True).start()

    def request(self, method, params, timeout=60):
        """The result, or {"error": …} for an error, or None for no answer in time."""
        self.next_id += 1
        ask = self.next_id
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": ask, "method": method,
                                             "params": params}) + "\n")
        self.process.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                line = self.out.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                return None
            if line is None:
                return None
            try:
                message = json.loads(line.strip())
            except Exception:
                continue
            if message.get("id") != ask or "method" in message:
                # A notification, or a request of the runtime's own: the app would answer
                # it, this script has nothing to say.
                if "method" in message and "id" in message:
                    self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": message["id"],
                                                         "error": {"code": -32601, "message": "not here"}}) + "\n")
                    self.process.stdin.flush()
                continue
            if "error" in message:
                return {"error": message["error"]}
            return message.get("result") or {}
        return None

    def end(self):
        self.process.kill()

def handshake(name, command):
    try:
        conversation = Conversation(name, command)
    except FileNotFoundError:
        return None, None
    result = conversation.request("initialize", {"protocolVersion": 1, "clientCapabilities": CLIENT})
    if result is None or "error" in result:
        conversation.end()
        return None, None
    return conversation, result

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

def meta_keys(value):
    meta = value.get("_meta") if isinstance(value, dict) else None
    return sorted(meta) if isinstance(meta, dict) else []

def check_meta(where, value):
    """New `_meta` keys at `where`, printed; how many there were."""
    new = 0
    for key in meta_keys(value):
        action = META.get(where, {}).get(key)
        if action is None:
            action = "NEW, and not written down anywhere"
            new += 1
        print(f"   _meta.{key:39} {action} ({where})")
    return new

def check_options(name, session):
    """Every option and choice the conversation offers, against OPTIONS; how many are new."""
    known = OPTIONS.get(name, {})
    offered = session.get("configOptions") or []
    if not offered:
        # Gemini sends no configOptions, only the older `modes` and `models`, which the
        # app turns into the same two options. Read as those.
        modes = (session.get("modes") or {}).get("availableModes") or []
        models = (session.get("models") or {}).get("availableModels") or []
        if modes:
            offered.append({"id": "mode", "category": "mode", "type": "select",
                            "options": [{"value": m.get("id")} for m in modes]})
        if models:
            offered.append({"id": "model", "category": "model", "type": "select", "options": []})
    new = 0
    for option in offered:
        oid = option.get("id", "?")
        kind = option.get("type", "select")
        choices = [c["value"] for c in option.get("options") or [] if isinstance(c, dict) and "value" in c]
        # A grouped select nests its choices one level down.
        for group in option.get("options") or []:
            if isinstance(group, dict) and "group" in group:
                choices += [c.get("value") for c in group.get("options") or []]
        label = f"option {oid} ({option.get('category') or 'no category'}, {kind})"
        if oid not in known:
            new += 1
            print(f"   {label:45} NEW, and not written down anywhere")
            continue
        values, action = known[oid]
        print(f"   {label:45} {action}")
        if values == "boolean":
            if kind != "boolean":
                new += 1
                print(f"      now a {kind}, not a boolean: NEW")
        elif values is not None:
            for choice in choices:
                if choice not in values:
                    new += 1
                    print(f"      choice {choice}: NEW, and not written down anywhere")
    for oid in sorted(set(known) - {o.get("id") for o in offered}):
        print(f"   option {oid:38} no longer offered")
    return new

unknown = [name for name in NAMED if name not in RUNTIMES]
if unknown:
    print(f"no runtime called {', '.join(unknown)}; try {', '.join(RUNTIMES)}")
    sys.exit(2)
missing = 0
unread = []
for name, command in RUNTIMES.items():
    if NAMED and name not in NAMED:
        continue
    print(f"\n== {name}")
    conversation, result = handshake(name, command)
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
    missing += check_meta("initialize", result)
    missing += check_meta("agentCapabilities", result.get("agentCapabilities"))

    if SESSIONS:
        folder = tempfile.mkdtemp(prefix=f"agents-handshake-{name}-cwd-")
        if name in RUNTIME_AUTH:
            conversation.request("authenticate", {"methodId": RUNTIME_AUTH[name]})
        session = conversation.request("session/new", {"cwd": folder, "mcpServers": []}, timeout=90)
        if session is None or "error" in session:
            why = (session or {}).get("error", {}).get("message") or "no answer in 90 seconds"
            print(f"   options not read: {why}")
            unread.append(name)
        else:
            if SESSIONS_OUT:
                os.makedirs(SESSIONS_OUT, exist_ok=True)
                with open(f"{SESSIONS_OUT}/{name}.json", "w") as f:
                    json.dump(session, f, indent=2)
            missing += check_options(name, session)
            missing += check_meta("session/new", session)
            capabilities = result.get("agentCapabilities") or {}
            sessions = capabilities.get("sessionCapabilities") or {}
            if "delete" in sessions:
                conversation.request("session/delete", {"sessionId": session.get("sessionId")}, timeout=20)
            elif "close" in sessions:
                conversation.request("session/close", {"sessionId": session.get("sessionId")}, timeout=20)
    conversation.end()

print(f"\n{missing} advertised capabilities, options or _meta keys with neither an action in the app nor a reason in the spec.")
if unread:
    print(f"Options not read for {', '.join(unread)}: sign in, or run without --scratch-home, to check them.")
sys.exit(1 if missing else 0)
PY
