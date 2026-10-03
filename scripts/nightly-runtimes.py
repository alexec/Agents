#!/usr/bin/env python3
"""Update each agent runtime to its latest release and test it against the app (#39).

Run by the nightly-runtimes workflow (.agents/workflows/nightly-runtimes.md), one phase at a
time, so the agent running it can hold the "build" lease around the one phase that builds:

  nightly-runtimes.py plan   [--available claude,codex,…] [--runtimes …] [--force]
  nightly-runtimes.py build  [RUN]        xcodebuild Agents Host + the runtime tests  (lease "build")
  nightly-runtimes.py check  [RUN]        handshake, tools and one real turn, on a scratch root
  nightly-runtimes.py report [RUN] [--dry-run]

Each phase takes the run that `plan` made (the latest, without RUN). Every phase also takes
--home DIR, where the state between nights is kept (default ~/Library/Application Support/
Agents Nightly Runtimes, or $AGENTS_NIGHTLY_HOME).

plan     Fetches origin/main into a worktree of its own (<home>/tree, never the project's
         checkout) and asks each runtime's source for its latest release. A runtime is
         tested when that release is new: not the one pinned, and not the one tested on an
         earlier night. A runtime not in --available (the app's pool, #117) is skipped and
         said so. A pinned runtime is re-pinned in the tree with scripts/update-toolset.sh.
         Prints "Nothing changed." and nothing else when nothing is to be tested.
build    xcodegen + xcodebuild -scheme AgentsHost into <home>/tree/build/DD, then the
         AgentsKit runtime tests, all with every new pin in place.
check    Starts a scratch host on that build (the run-app skill's launch.sh --no-window),
         installs each app-copy runtime from its new pin, then per runtime:
         scripts/acp-handshake.sh, scripts/runtime-tools.sh (a NEW tool fails), and one real
         turn through agentsd on the cheapest model the runtime offers. Stops the host.
report   A pinned runtime that passed every step: one PR per runtime, on the branch
         nightly/runtime-<id>, opened or updated. A runtime that failed a step: one issue
         per runtime, opened or commented on, with the version, the step and its output.
         --dry-run prints what it would do and opens, pushes and records nothing.

Runtimes the person installs (Grok, Copilot, Cursor) are never updated here: the app runs
the person's own copy, so updating it would change the live app before it was tested. They
are tested when the version installed differs from the one tested last.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_HOME = os.environ.get("AGENTS_NIGHTLY_HOME") or os.path.expanduser(
    "~/Library/Application Support/Agents Nightly Runtimes")

# kind: npm (a toolset of Node + one npm package), archive (a vendor archive from the ACP
# registry), github (a vendor archive from GitHub releases), installed (the person's own).
RUNTIMES = {
    "claude": {"name": "Claude", "kind": "npm", "package": "@agentclientprotocol/claude-agent-acp",
               "platform": "claude-agent-sdk-"},
    "codex": {"name": "Codex", "kind": "npm", "package": "@agentclientprotocol/codex-acp",
              "platform": "codex-", "shim": "codex-acp"},
    "gemini": {"name": "Gemini", "kind": "npm", "package": "@google/gemini-cli", "shim": "gemini",
               "script": "update-gemini-toolset.sh"},
    "antigravity": {"name": "Antigravity", "kind": "archive", "registry": "antigravity-acp",
                    "shim": "agy_acp_server"},
    "opencode": {"name": "OpenCode", "kind": "github", "repo": "anomalyco/opencode", "shim": "opencode"},
    "grok": {"name": "Grok", "kind": "installed", "version": ["grok", "--version"]},
    "copilot": {"name": "Copilot", "kind": "installed", "version": ["copilot", "--version"]},
    "cursor": {"name": "Cursor", "kind": "installed", "version": ["cursor-agent", "--version"]},
}

# The cheapest model first: the first word any offered model contains wins, in this order.
CHEAP = ["haiku", "nano", "flash-lite", "lite", "mini", "flash", "small"]

# AgentsKit suites about runtimes, toolsets and the tool policy.
RUNTIME_TESTS = ("(Toolset|ArchiveToolset|ToolPolicy|MacToolsetInstaller|RuntimeInstaller|"
                 "RuntimeInstallDispatch|RuntimeDiscovery|AppToolsetDiscovery|RuntimeAvailabilityCoding|"
                 "OpenCodeRuntime|ToolsetInstall|ServerArchiveInstaller|RuntimeChoice|RuntimeEnvironment|"
                 "DefaultRuntime)Tests")

TURN_PROMPT = "Reply with the single word OK and nothing else. Do not use any tools."
OUTPUT_LIMIT = 6000


def sh(command, cwd=None, env=None, timeout=None, check=False):
    """Run a command; (exit status, stdout and stderr together)."""
    try:
        done = subprocess.run(command, cwd=cwd, env=env, timeout=timeout, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        return 124, out + f"\n(timed out after {timeout}s)"
    except FileNotFoundError as e:
        return 127, str(e)
    if check and done.returncode != 0:
        sys.exit(f"{' '.join(command)} failed:\n{done.stdout}")
    return done.returncode, done.stdout


def login_env():
    """This environment with the login shell's PATH, as the runtimes are found by the app."""
    path = subprocess.run(["/bin/zsh", "-lc", 'printf %s "$PATH"'], capture_output=True, text=True).stdout
    return {**os.environ, "PATH": path or os.environ.get("PATH", "")}


def tail(text, limit=OUTPUT_LIMIT):
    text = text.strip()
    return text if len(text) <= limit else "…\n" + text[-limit:]


# ---- state ------------------------------------------------------------------------------

def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def save(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(path + ".tmp", path)


def run_dir(home, given):
    if given:
        return os.path.abspath(given)
    latest = os.path.join(home, "runs", "latest")
    if not os.path.exists(latest):
        sys.exit("no run yet: start with `plan`")
    return os.path.realpath(latest)


# ---- versions ---------------------------------------------------------------------------

def pinned_version(tree, rid):
    manifest = load(os.path.join(tree, "App/Resources/toolsets", rid, "manifest.json"), {})
    return manifest.get("packageVersion") or manifest.get("version")


def latest_version(rid, env):
    spec = RUNTIMES[rid]
    kind = spec["kind"]
    if kind == "npm":
        status, out = sh(["npm", "view", spec["package"], "version"], env=env, timeout=60)
        return out.strip() if status == 0 else None
    if kind == "archive":
        url = f"https://raw.githubusercontent.com/agentclientprotocol/registry/main/{spec['registry']}/agent.json"
        with urllib.request.urlopen(url, timeout=60) as response:
            return json.load(response)["version"]
    if kind == "github":
        status, out = sh(["gh", "api", f"repos/{spec['repo']}/releases/latest", "--jq", ".tag_name"],
                         env=env, timeout=60)
        return out.strip().removeprefix("v") if status == 0 else None
    status, out = sh(spec["version"], env=env, timeout=60)
    return out.strip().splitlines()[0] if status == 0 and out.strip() else None


def repin(tree, rid, version, env):
    """Re-pin one runtime in the tree; (ok, output)."""
    spec = RUNTIMES[rid]
    manifest = load(os.path.join(tree, "App/Resources/toolsets", rid, "manifest.json"), {})
    min_free = str(manifest.get("minFreeBytes", ""))
    scripts = os.path.join(tree, "scripts")
    if spec["kind"] == "npm":
        node = manifest["node"]["version"]
        if spec.get("script"):
            command = [f"{scripts}/{spec['script']}", node, version]
        else:
            command = [f"{scripts}/update-toolset.sh", rid, node, spec["package"], version,
                       "--platform-package", spec["platform"], "--min-free-bytes", min_free]
            if manifest.get("forwardsArguments"):
                command.append("--forwards-arguments")
    elif spec["kind"] == "archive":
        command = [f"{scripts}/update-toolset.sh", "--archive", rid, spec["registry"], "--min-free-bytes", min_free]
    else:
        command = [f"{scripts}/update-toolset.sh", "--archive-github", rid, spec["repo"], f"v{version}",
                   "--min-free-bytes", min_free]
    status, out = sh(command, cwd=tree, env=env, timeout=1800)
    if status == 0 and pinned_version(tree, rid) != version:
        return False, out + f"\nthe manifest says {pinned_version(tree, rid)}, not {version}"
    return status == 0, out


# ---- plan -------------------------------------------------------------------------------

def prepare_tree(home, base):
    tree = os.path.join(home, "tree")
    sh(["git", "-C", REPO, "fetch", "-q", "origin", "main"], check=True, timeout=300)
    if not os.path.exists(os.path.join(tree, ".git")):
        sh(["git", "-C", REPO, "worktree", "add", "-q", "--detach", tree, base], check=True)
    else:
        # The tree is this script's own: put it back to the base, keeping build/ (ignored).
        sh(["git", "-C", tree, "checkout", "-q", "--detach", "-f", base], check=True)
        sh(["git", "-C", tree, "clean", "-qfd"], check=True)
    return tree


def plan(args):
    env = login_env()
    tree = prepare_tree(args.home, args.base)
    state = load(os.path.join(args.home, "state.json"), {})
    wanted = args.runtimes.split(",") if args.runtimes else list(RUNTIMES)
    available = set(args.available.split(",")) if args.available is not None else None
    stamp = datetime.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    run = os.path.join(args.home, "runs", stamp)
    os.makedirs(run)
    record = {"started": stamp, "tree": tree, "base": sh(["git", "-C", tree, "rev-parse", "HEAD"])[1].strip(),
              "runtimes": {}}
    for rid in wanted:
        if rid not in RUNTIMES:
            sys.exit(f"no runtime called {rid}; try {', '.join(RUNTIMES)}")
        spec = RUNTIMES[rid]
        entry = {"kind": spec["kind"], "steps": {}}
        record["runtimes"][rid] = entry
        if available is not None and rid not in available:
            entry["status"] = "skipped"
            entry["why"] = "not available to the app tonight (not installed, not signed in, or out of the pool)"
            continue
        try:
            latest = latest_version(rid, env)
        except Exception as e:  # a registry that would not answer
            latest, entry["why"] = None, str(e)
        if not latest:
            entry["status"] = "skipped"
            entry["why"] = entry.get("why") or "could not read its latest release"
            continue
        entry["to"] = latest
        entry["from"] = pinned_version(tree, rid) if spec["kind"] != "installed" else state.get(rid, {}).get("version")
        tested = state.get(rid, {}).get("version")
        if not args.force and (latest == entry["from"] and spec["kind"] != "installed" or latest == tested):
            entry["status"] = "unchanged"
            continue
        entry["status"] = "testing"
        if spec["kind"] != "installed":
            ok, out = repin(tree, rid, latest, env)
            entry["steps"]["update"] = {"ok": ok, "output": tail(out)}
            if not ok:
                entry["status"] = "failed"
    save(os.path.join(run, "run.json"), record)
    latest_link = os.path.join(args.home, "runs", "latest")
    if os.path.lexists(latest_link):
        os.remove(latest_link)
    os.symlink(stamp, latest_link)
    testing = [r for r, e in record["runtimes"].items() if e["status"] in ("testing", "failed")]
    if not testing:
        print("Nothing changed.")
    else:
        print(f"run {run}")
    for rid, entry in record["runtimes"].items():
        if entry["status"] == "testing":
            print(f"  {rid}: {entry.get('from') or 'untested'} → {entry['to']}, to test")
        elif entry["status"] == "failed":
            print(f"  {rid}: {entry.get('from')} → {entry['to']}, update FAILED")
        elif entry["status"] == "skipped":
            print(f"  {rid}: skipped, {entry['why']}")
        elif testing:
            print(f"  {rid}: {entry['to']}, unchanged")


def testing(record):
    return [rid for rid, e in record["runtimes"].items() if e["status"] == "testing"]


def fail_all(record, rids, step, ok, output):
    for rid in rids:
        e = record["runtimes"][rid]
        e["steps"][step] = {"ok": ok, "output": tail(output)}
        if not ok:
            e["status"] = "failed"


# ---- build ------------------------------------------------------------------------------

def build(args):
    run = run_dir(args.home, args.run)
    record = load(os.path.join(run, "run.json"), {})
    rids = testing(record)
    if not rids:
        print("nothing to build")
        return
    tree = record["tree"]
    together = f" (built and tested with {', '.join(rids)} re-pinned together)" if len(rids) > 1 else ""
    status, out = sh(["/bin/zsh", "-c",
                      "xcodegen generate >/dev/null && xcodebuild -scheme AgentsHost -destination 'platform=macOS' "
                      "-configuration Debug -derivedDataPath build/DD -skipPackagePluginValidation build"],
                     cwd=tree, timeout=3600)
    with open(os.path.join(run, "build.log"), "w") as f:
        f.write(out)
    fail_all(record, rids, "build", status == 0, out + together)
    print(f"build: {'ok' if status == 0 else 'FAILED'} ({run}/build.log)")
    if status == 0:
        status, out = sh(["swift", "test", "--package-path", "Packages/AgentsKit", "--filter", RUNTIME_TESTS],
                         cwd=tree, timeout=3600)
        with open(os.path.join(run, "tests.log"), "w") as f:
            f.write(out)
        summary = "\n".join(line for line in out.splitlines()
                            if re.search(r"✘|error:|failed|passed after|Executed", line))
        fail_all(record, rids, "tests", status == 0, (summary or out) + together)
        print(f"runtime tests: {'ok' if status == 0 else 'FAILED'} ({run}/tests.log)")
    save(os.path.join(run, "run.json"), record)


# ---- check ------------------------------------------------------------------------------

def rpc_client(tree):
    path = os.path.join(tree, ".agents/skills/run-app/scripts/rpc.py")
    spec = importlib.util.spec_from_file_location("nightly_rpc", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Client


def cheapest_model(session):
    """The model value to start with, or None for the runtime's own default."""
    choices = []
    for option in (session or {}).get("configOptions") or []:
        if option.get("id") != "model" and option.get("category") != "model":
            continue
        for choice in option.get("options") or []:
            if isinstance(choice, dict) and "group" in choice:
                choices += [c for c in choice.get("options") or [] if isinstance(c, dict)]
            elif isinstance(choice, dict):
                choices.append(choice)
    choices = [(c.get("value"), f"{c.get('value')} {c.get('name', '')}".lower()) for c in choices]
    if not choices:
        models = ((session or {}).get("models") or {}).get("availableModels") or []
        choices = [(m.get("modelId"), f"{m.get('modelId')} {m.get('name', '')}".lower()) for m in models]
    for word in CHEAP:
        for value, words in choices:
            if value and word in words:
                return value
    return None


def wait_installed(client, rid, timeout=900):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        for status in client.call("runtimes/list", {}) or []:
            if (status.get("runtime") or {}).get("id") == rid:
                last = status
                availability = status.get("availability") or {}
                if "available" in availability and not status.get("outdated"):
                    return True, json.dumps(availability)
                if "installFailed" in availability:
                    return False, json.dumps(availability)
        time.sleep(5)
    return False, f"not installed after {timeout}s: {json.dumps(last)}"


def real_turn(client, root, rid, model, timeout=300):
    """(ok, what happened)."""
    work = os.path.join(root, "work")
    os.makedirs(work, exist_ok=True)
    if not os.path.exists(os.path.join(work, ".git")):
        sh(["git", "-C", work, "init", "-q"])
        client.call("projects/add", {"folder": "file://" + work})
    params = {"runtimeID": rid, "cwd": "file://" + work, "prompt": TURN_PROMPT}
    if model:
        params["startOptions"] = {"values": {"model": model}}
    agent = client.call("agents/start", params, timeout=180)
    end = time.time() + timeout
    record = None
    while time.time() < end:
        time.sleep(3)
        for pending in client.call("permissions/pending", {}) or []:
            # The prompt asks for no tools; one asked for anyway is refused, not allowed.
            deny = next((o["optionID"] for o in pending["options"] if o["kind"].startswith("reject")), None)
            if deny:
                client.call("permissions/answer", {"permissionID": pending["id"], "optionID": deny})
        record = next((a for a in client.call("agents/list", {"includeArchived": False}) or []
                       if a.get("id") == agent), None)
        if record and record.get("state") in ("finished", "stopped", "failed"):
            break
    else:
        return False, f"no end to the turn after {timeout}s: {json.dumps(record)[:2000]}"
    # The agent's own words only: the transcript also holds the prompt, which says OK too.
    replies = []
    try:
        with open(os.path.join(root, "agents", agent, "transcript.jsonl")) as f:
            for line in f:
                message = (json.loads(line).get("kind") or {}).get("agentMessage")
                if message:
                    replies.append(message.get("text", ""))
    except (OSError, ValueError) as e:
        replies.append(f"(transcript not read: {e})")
    reply = "".join(replies)
    said_ok = "OK" in reply
    what = (f"agent {agent} on {model or 'the default model'}: {record.get('state')}"
            f"{'' if said_ok else ', and the reply had no OK in it'}")
    if record.get("state") != "finished" or not said_ok:
        return False, what + "\n" + json.dumps(record)[:2000] + "\nreplied: " + reply[-2000:]
    return True, what


def check(args):
    run = run_dir(args.home, args.run)
    record = load(os.path.join(run, "run.json"), {})
    rids = testing(record)
    if not rids:
        print("nothing to check")
        return
    tree = record["tree"]
    scripts = os.path.join(tree, ".agents/skills/run-app/scripts")
    slug = "n39-" + record["started"][-6:]
    status, out = sh([f"{scripts}/launch.sh", "--no-build", "--no-window", "--slug", slug], cwd=tree, timeout=300)
    if status != 0:
        fail_all(record, rids, "start", False, out)
        save(os.path.join(run, "run.json"), record)
        print("the scratch host would not start:\n" + out)
        return
    root = f"/tmp/run-{slug}"
    env = login_env()
    try:
        client = rpc_client(tree)(root)
        sessions = os.path.join(run, "sessions")
        for rid in rids:
            spec, entry = RUNTIMES[rid], record["runtimes"][rid]
            steps = entry["steps"]
            extra = {"AGENTS_HANDSHAKE_SESSIONS": sessions}
            if rid == "claude":
                extra["AGENTS_CLAUDE_VERSION"] = entry["to"]
            if spec.get("shim"):
                client.call("runtimes/install", {"runtimeID": rid})
                ok, out = wait_installed(client, rid)
                steps["install"] = {"ok": ok, "output": tail(out)}
                if not ok:
                    entry["status"] = "failed"
                    print(f"{rid}: install FAILED")
                    continue
                extra[f"AGENTS_{rid.upper()}_SHIM"] = os.path.join(root, "tools", rid, "current", "bin", spec["shim"])
            for step, script in (("handshake", "acp-handshake.sh"), ("tools", "runtime-tools.sh")):
                status, out = sh([os.path.join(tree, "scripts", script), rid], env={**env, **extra}, timeout=600)
                steps[step] = {"ok": status == 0, "output": tail(out)}
                if status != 0:
                    entry["status"] = "failed"
            model = cheapest_model(load(os.path.join(sessions, f"{rid}.json"), None))
            try:
                ok, out = real_turn(client, root, rid, model)
            except Exception as e:
                ok, out = False, f"{type(e).__name__}: {e}"
            steps["turn"] = {"ok": ok, "output": tail(out), "model": model}
            if not ok:
                entry["status"] = "failed"
            print(f"{rid}: " + ", ".join(f"{s} {'ok' if v['ok'] else 'FAILED'}" for s, v in steps.items()))
    finally:
        save(os.path.join(run, "run.json"), record)
        sh([f"{scripts}/stop.sh", root, "--keep"] if args.keep else [f"{scripts}/stop.sh", root], timeout=120)


# ---- report -----------------------------------------------------------------------------

STEP_ORDER = ["update", "build", "tests", "start", "install", "handshake", "tools", "turn"]


def steps_table(entry):
    lines = ["| Step | Result |", "| --- | --- |"]
    for step in STEP_ORDER:
        if step in entry["steps"]:
            result = entry["steps"][step]
            extra = f" ({result['model'] or 'default model'})" if step == "turn" else ""
            lines.append(f"| {step} | {'passed' if result['ok'] else '**failed**'}{extra} |")
    return "\n".join(lines)


def first_failure(entry):
    return next((s for s in STEP_ORDER if s in entry["steps"] and not entry["steps"][s]["ok"]), None)


def do(command, dry_run, cwd=None):
    """Run a command that changes GitHub or a branch, or only say it, with --dry-run."""
    if dry_run:
        print("  would run: " + " ".join(repr(c) if " " in c else c for c in command))
        return 0, ""
    status, out = sh(command, cwd=cwd, timeout=600)
    if status != 0:
        print(f"  {command[0]} failed: {out.strip()[-500:]}")
    return status, out


def open_pr(record, rid, entry, dry_run):
    spec = RUNTIMES[rid]
    branch = f"nightly/runtime-{rid}"
    title = f"Pin {spec['name']} to {entry['to']}"
    body = (f"The nightly runtime check (#39) re-pinned {spec['name']} from {entry['from']} to "
            f"{entry['to']} and every step passed, on origin/main {record['base'][:10]}.\n\n"
            f"{steps_table(entry)}\n\nRe-pinned with `scripts/update-toolset.sh`; only "
            f"`App/Resources/toolsets/{rid}/` changes. Notes in specs and comments that name the "
            f"old version are left as they were.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)")
    work = tempfile.mkdtemp(prefix=f"nightly-{rid}-")
    os.rmdir(work)
    sh(["git", "-C", REPO, "worktree", "add", "-q", "--detach", work, record["base"]], check=True)
    try:
        target = os.path.join(work, "App/Resources/toolsets", rid)
        shutil.rmtree(target, ignore_errors=True)
        shutil.copytree(os.path.join(record["tree"], "App/Resources/toolsets", rid), target)
        sh(["git", "-C", work, "add", "-A", target], check=True)
        message = (f"{title} (nightly runtime check, #39)\n\n"
                   f"{entry['from']} → {entry['to']}: update, build, runtime tests, handshake, tools and "
                   f"a real turn all passed.\n\nCo-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>")
        sh(["git", "-C", work, "commit", "-q", "-m", message], check=True)
        print("  " + sh(["git", "-C", work, "show", "--stat", "--format=%h %s", "HEAD"])[1].strip().replace("\n", "\n  "))
        status, _ = do(["git", "-C", work, "push", "-f", "-q", "origin", f"HEAD:refs/heads/{branch}"], dry_run)
        if status != 0:
            return False
        existing = sh(["gh", "pr", "list", "--head", branch, "--state", "open", "--json", "number", "--jq", ".[0].number"],
                      cwd=REPO)[1].strip()
        if existing:
            status, _ = do(["gh", "pr", "edit", existing, "--title", title, "--body", body], dry_run, cwd=REPO)
        else:
            status, _ = do(["gh", "pr", "create", "--base", "main", "--head", branch, "--title", title, "--body", body],
                           dry_run, cwd=REPO)
        return status == 0
    finally:
        sh(["git", "-C", REPO, "worktree", "remove", "--force", work])


def open_issue(record, rid, entry, dry_run):
    spec = RUNTIMES[rid]
    step = first_failure(entry)
    prefix = f"Nightly runtime check: {spec['name']}"
    title = f"{prefix} {entry.get('to', '?')} fails at {step}"
    outputs = "\n\n".join(f"### {s}\n\n```\n{entry['steps'][s]['output']}\n```"
                          for s in STEP_ORDER if s in entry["steps"] and not entry["steps"][s]["ok"])
    body = (f"{spec['name']} {entry.get('from') or '(untested)'} → {entry.get('to')}, on origin/main "
            f"{record['base'][:10]}, run {record['started']}.\n\n{steps_table(entry)}\n\n{outputs}\n\n"
            f"Found by the nightly runtime check (#39).")
    existing = sh(["gh", "issue", "list", "--state", "open", "--search", f'in:title "{prefix}"',
                   "--json", "number,title", "--jq", f'[.[] | select(.title | startswith("{prefix} "))][0].number'],
                  cwd=REPO)[1].strip()
    if existing:
        do(["gh", "issue", "edit", existing, "--title", title], dry_run, cwd=REPO)
        status, _ = do(["gh", "issue", "comment", existing, "--body", body], dry_run, cwd=REPO)
    else:
        status, _ = do(["gh", "issue", "create", "--title", title, "--body", body], dry_run, cwd=REPO)
    if dry_run:
        print("  ---- issue body ----\n  " + body[:3000].replace("\n", "\n  "))
    return status == 0


def report(args):
    run = run_dir(args.home, args.run)
    record = load(os.path.join(run, "run.json"), {})
    state_path = os.path.join(args.home, "state.json")
    state = load(state_path, {})
    lines = []
    for rid, entry in record["runtimes"].items():
        spec = RUNTIMES[rid]
        if entry["status"] == "skipped":
            lines.append(f"- {spec['name']}: skipped, {entry['why']}")
            continue
        if entry["status"] == "unchanged":
            continue
        if entry["status"] == "testing" and not entry["steps"].get("turn"):
            lines.append(f"- {spec['name']}: {entry['to']} not tested; build or check did not run")
            continue
        passed = entry["status"] == "testing"
        print(f"{spec['name']} {entry.get('from')} → {entry['to']}: {'passed' if passed else 'failed at ' + first_failure(entry)}")
        if passed and spec["kind"] != "installed":
            sent = open_pr(record, rid, entry, args.dry_run)
            lines.append(f"- {spec['name']} {entry['to']}: passed; PR {'would be ' if args.dry_run else ''}"
                         f"{'opened or updated' if sent else 'NOT opened (see above)'} on nightly/runtime-{rid}")
        elif passed:
            lines.append(f"- {spec['name']} {entry['to']} (installed by the person): passed")
        else:
            sent = open_issue(record, rid, entry, args.dry_run)
            lines.append(f"- {spec['name']} {entry['to']}: failed at {first_failure(entry)}; issue "
                         f"{'would be ' if args.dry_run else ''}{'opened or updated' if sent else 'NOT opened'}")
        if not args.dry_run:
            state[rid] = {"version": entry["to"], "result": "passed" if passed else "failed",
                          "run": record["started"]}
    if not args.dry_run:
        save(state_path, state)
    text = "\n".join(lines)
    with open(os.path.join(run, "report.md"), "w") as f:
        f.write(text + "\n")
    print("\n" + (text or "Nothing changed."))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("phase", choices=["plan", "build", "check", "report"])
    parser.add_argument("run", nargs="?")
    parser.add_argument("--home", default=DEFAULT_HOME)
    parser.add_argument("--runtimes", help="only these, comma-separated")
    parser.add_argument("--available", help="the runtimes the app can start tonight, comma-separated")
    parser.add_argument("--base", default="origin/main",
                        help="plan: what the tree and the PRs start from (default origin/main)")
    parser.add_argument("--force", action="store_true", help="test even what has not changed")
    parser.add_argument("--dry-run", action="store_true", help="report: open, push and record nothing")
    parser.add_argument("--keep", action="store_true", help="check: leave the scratch root on disk")
    args = parser.parse_args()
    args.home = os.path.abspath(os.path.expanduser(args.home))
    {"plan": plan, "build": build, "check": check, "report": report}[args.phase](args)


if __name__ == "__main__":
    main()
