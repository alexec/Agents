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

plan     Checks out --base (default main, this Mac's own: origin/main can be days behind it)
         into a worktree of its own (<home>/tree, never the project's checkout) and asks each runtime's source for its latest release. A runtime is
         tested when that release is new: not the one pinned, and not the one tested on an
         earlier night. A runtime not in --available (the app's pool, #117) is skipped and
         said so. A pinned runtime is re-pinned in the tree with scripts/update-toolset.sh,
         and each new pin is kept in the run, so later phases can test pins one at a time.
         Prints "Nothing changed." and nothing else when nothing is to be tested.
build    xcodegen + xcodebuild -scheme AgentsHost into <home>/tree/build/DD, then the
         AgentsKit runtime tests, all with every new pin in place. Both run on the base as it
         was too: what already fails there is "already failing on main", and no runtime's
         fault. A test that fails only with the new pins is put down to the pin that fails it
         alone; one no single pin fails is put down to all of them together. A new failure
         that a second run does not repeat is called flaky, and is no runtime's fault either.
check    Starts a scratch host on that build (the run-app skill's launch.sh --no-window),
         installs each app-copy runtime from its new pin, then per runtime:
         scripts/acp-handshake.sh, scripts/runtime-tools.sh (a NEW tool fails), and one real
         turn through agentsd on the cheapest model the runtime offers. Stops the host.
report   A pinned runtime that passed every step: one PR per runtime, on the branch
         nightly/runtime-<id> off origin/main (only its toolset folder changes), opened or
         updated. A runtime that failed a step: one issue per runtime, opened or commented
         on, with the version, the step and its output; runtimes that failed the same step for
         the same cause share one issue. What already fails on main is listed, never filed.
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
    if status != 0 or not out.strip():
        return None
    # "GitHub Copilot CLI 1.0.89-5." is version 1.0.89-5.
    line = out.strip().splitlines()[0]
    found = re.search(r"\d+(?:\.\d+)+(?:-[\w.]*\w)?", line)
    return found.group(0) if found else line


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
              "base_ref": args.base, "runtimes": {}}
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
            else:
                shutil.copytree(os.path.join(tree, TOOLSETS, rid), os.path.join(run, "pins", rid))
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


TOOLSETS = "App/Resources/toolsets"


def use_pins(tree, run, rids):
    """Put the tree's toolsets back to the base, then lay in the new pins of these runtimes."""
    sh(["git", "-C", tree, "checkout", "-q", "HEAD", "--", TOOLSETS], check=True)
    sh(["git", "-C", tree, "clean", "-qfd", "--", TOOLSETS], check=True)
    for rid in rids:
        pin = os.path.join(run, "pins", rid)
        if os.path.isdir(pin):
            target = os.path.join(tree, TOOLSETS, rid)
            shutil.rmtree(target, ignore_errors=True)
            shutil.copytree(pin, target)


def pinned(run, rids):
    return [rid for rid in rids if os.path.isdir(os.path.join(run, "pins", rid))]


def testing(record):
    return [rid for rid, e in record["runtimes"].items() if e["status"] == "testing"]


def fail_all(record, rids, step, ok, output):
    for rid in rids:
        e = record["runtimes"][rid]
        e["steps"][step] = {"ok": ok, "output": tail(output)}
        if not ok:
            e["status"] = "failed"


# ---- build ------------------------------------------------------------------------------

def xcodebuild(tree):
    return sh(["/bin/zsh", "-c",
               "xcodegen generate >/dev/null && xcodebuild -scheme AgentsHost -destination 'platform=macOS' "
               "-configuration Debug -derivedDataPath build/DD -skipPackagePluginValidation build"],
              cwd=tree, timeout=3600)


NOT_RUN = "(the runtime tests did not build or run)"


def runtime_tests(tree):
    """(exit status, output, the names of the tests that failed)."""
    status, out = sh(["swift", "test", "--package-path", "Packages/AgentsKit", "--filter", RUNTIME_TESTS],
                     cwd=tree, timeout=3600)
    failed = set(re.findall(r"✘ Test (\S+?)\(.*?\) failed", out))
    failed |= set(re.findall(r"Test Case '-\[\S+ (\S+)\]' failed", out))
    if status != 0 and not failed:
        failed = {NOT_RUN}
    return status, out, failed


def failure_lines(out, names):
    """What the output says about these failed tests, and nothing about the rest."""
    lines, ours = [], False
    for line in out.splitlines():
        if line.startswith("↳"):
            if ours:
                lines.append(line)
            continue
        ours = any(name in line for name in names) and bool(re.search(r"✘|error:|failed", line))
        if ours:
            lines.append(line)
    return "\n".join(lines[:120]) if lines else tail(out)


def build(args):
    run = run_dir(args.home, args.run)
    record = load(os.path.join(run, "run.json"), {})
    rids = testing(record)
    if not rids:
        print("nothing to build")
        return
    tree = record["tree"]
    pins = pinned(run, rids)
    baseline = record.setdefault("baseline", {})
    use_pins(tree, run, pins)
    status, out = xcodebuild(tree)
    with open(os.path.join(run, "build.log"), "w") as f:
        f.write(out)
    if status != 0 and pins:
        # Is it the pins, or does the base not build either?
        use_pins(tree, run, [])
        base_status, base_out = xcodebuild(tree)
        with open(os.path.join(run, "build-baseline.log"), "w") as f:
            f.write(base_out)
        if base_status != 0:
            baseline["build"] = tail(base_out)
            for rid in rids:
                record["runtimes"][rid]["status"] = "blocked"
            save(os.path.join(run, "run.json"), record)
            print(f"build: FAILED on the base too, already failing on main ({run}/build-baseline.log)")
            return
        use_pins(tree, run, pins)
    together = f" (built with {', '.join(pins)} re-pinned together)" if len(pins) > 1 else ""
    for rid in rids:
        record["runtimes"][rid]["steps"]["build"] = {
            "ok": status == 0, "output": tail(out + together), "cause": "build" if status else None}
        if status != 0:
            record["runtimes"][rid]["status"] = "failed"
    print(f"build: {'ok' if status == 0 else 'FAILED'} ({run}/build.log)")
    if status == 0:
        test_all(run, record, tree, rids, pins)
    save(os.path.join(run, "run.json"), record)


def test_all(run, record, tree, rids, pins):
    """The runtime tests on the base, with every new pin, and with each pin alone when that
    is needed to say which pin a new failure comes from."""
    use_pins(tree, run, [])
    _, base_out, base_failed = runtime_tests(tree)
    with open(os.path.join(run, "tests-baseline.log"), "w") as f:
        f.write(base_out)
    record["baseline"]["tests"] = sorted(base_failed)
    record["baseline"]["tests_output"] = failure_lines(base_out, base_failed) if base_failed else ""
    if pins:
        use_pins(tree, run, pins)
        _, out, failed = runtime_tests(tree)
    else:
        out, failed = base_out, base_failed
    with open(os.path.join(run, "tests.log"), "w") as f:
        f.write(out)
    new = failed - base_failed
    if new:
        # The suite is flaky under load: a new failure counts only if a second run fails it too.
        _, again_out, again = runtime_tests(tree)
        with open(os.path.join(run, "tests-again.log"), "w") as f:
            f.write(again_out)
        record["flaky"] = sorted(new - again)
        new &= again
        if record["flaky"]:
            print(f"runtime tests: flaky, failed once and passed again: {', '.join(record['flaky'])}")
    own = {rid: set() for rid in rids}
    outputs = {}
    if new and len(pins) == 1:
        own[pins[0]], outputs[pins[0]] = new, out
    elif new:
        for rid in pins:
            use_pins(tree, run, [rid])
            _, alone_out, alone_failed = runtime_tests(tree)
            with open(os.path.join(run, f"tests-{rid}.log"), "w") as f:
                f.write(alone_out)
            own[rid], outputs[rid] = (alone_failed - base_failed) & new, alone_out
        use_pins(tree, run, pins)
    shared = new - set().union(*own.values())
    already = f"\n\nAlready failing on main, and not counted: {', '.join(sorted(base_failed))}" if base_failed else ""
    for rid in rids:
        entry = record["runtimes"][rid]
        if own[rid]:
            entry["steps"]["tests"] = {"ok": False, "cause": "tests: " + ", ".join(sorted(own[rid])),
                                       "output": tail(failure_lines(outputs[rid], own[rid]) + f"\n\n(with only the "
                                                      f"{RUNTIMES[rid]['name']} pin new){already}")}
        elif shared and rid in pins:
            entry["steps"]["tests"] = {"ok": False, "cause": "tests together: " + ", ".join(sorted(shared)),
                                       "output": tail(failure_lines(out, shared) + f"\n\n(only with {', '.join(pins)} "
                                                      f"re-pinned together; no one pin fails it alone){already}")}
        else:
            entry["steps"]["tests"] = {"ok": True, "output": "passed" + already}
        if not entry["steps"]["tests"]["ok"]:
            entry["status"] = "failed"
    print(f"runtime tests: {'ok' if not new else 'FAILED: ' + ', '.join(sorted(new))} ({run}/tests.log)"
          + (f"; already failing on main: {', '.join(sorted(base_failed))}" if base_failed else ""))


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
        for rid in rids:
            record["runtimes"][rid]["steps"]["start"]["cause"] = "start"
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
                if not ok and model:
                    # The cheapest model can be a free one whose provider is down; the runtime
                    # is not at fault if its own default model answers.
                    ok, again = real_turn(client, root, rid, None)
                    out = (f"{again}, after {out}" if ok else f"{out}\n\nthen on the default model: {again}")
                    out = out.splitlines()[0] if ok else out
                    model = model if not ok else f"default; {model} failed"
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


def open_pr(run, record, rid, entry, dry_run):
    spec = RUNTIMES[rid]
    branch = f"nightly/runtime-{rid}"
    title = f"Pin {spec['name']} to {entry['to']}"
    body = (f"The nightly runtime check (#39) re-pinned {spec['name']} from {entry['from']} to "
            f"{entry['to']} and every step passed, tested on {base_name(record)}.\n\n"
            f"{steps_table(entry)}\n\nRe-pinned with `scripts/update-toolset.sh`; only "
            f"`App/Resources/toolsets/{rid}/` changes. Notes in specs and comments that name the "
            f"old version are left as they were.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)")
    work = tempfile.mkdtemp(prefix=f"nightly-{rid}-")
    os.rmdir(work)
    # The branch starts from origin/main whatever was tested, so it never carries unpushed work:
    # only the toolset folder changes, and it lays on either.
    sh(["git", "-C", REPO, "worktree", "add", "-q", "--detach", work, "origin/main"], check=True)
    try:
        target = os.path.join(work, "App/Resources/toolsets", rid)
        shutil.rmtree(target, ignore_errors=True)
        shutil.copytree(os.path.join(run, "pins", rid), target)
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


def base_name(record):
    return f"{record.get('base_ref', 'origin/main')} {record['base'][:10]}"


def cause(entry):
    step = first_failure(entry)
    result = entry["steps"][step]
    return step, result.get("cause") or result["output"]


def file_issue(prefix, title, body, dry_run):
    existing = sh(["gh", "issue", "list", "--state", "open", "--search", f'in:title "{prefix}"',
                   "--json", "number,title", "--jq", f'[.[] | select(.title | startswith("{prefix} "))][0].number'],
                  cwd=REPO)[1].strip()
    if existing:
        do(["gh", "issue", "edit", existing, "--title", title], dry_run, cwd=REPO)
        status, _ = do(["gh", "issue", "comment", existing, "--body", body], dry_run, cwd=REPO)
    else:
        status, _ = do(["gh", "issue", "create", "--title", title, "--body", body], dry_run, cwd=REPO)
    if dry_run:
        print(f"  ---- issue: {title} ----\n  " + body[:3000].replace("\n", "\n  "))
    return status == 0


def outputs_of(entry):
    return "\n\n".join(f"### {s}\n\n```\n{entry['steps'][s]['output']}\n```"
                        for s in STEP_ORDER if s in entry["steps"] and not entry["steps"][s]["ok"])


def open_issue(record, rid, entry, dry_run):
    spec = RUNTIMES[rid]
    prefix = f"Nightly runtime check: {spec['name']}"
    title = f"{prefix} {entry.get('to', '?')} fails at {first_failure(entry)}"
    body = (f"{spec['name']} {entry.get('from') or '(untested)'} → {entry.get('to')}, on {base_name(record)}, "
            f"run {record['started']}.\n\n{steps_table(entry)}\n\n{outputs_of(entry)}\n\n"
            f"Found by the nightly runtime check (#39).")
    return file_issue(prefix, title, body, dry_run)


def open_shared_issue(record, rids, dry_run):
    """Runtimes that failed the same step for the same cause: one issue for all of them."""
    names = ", ".join(RUNTIMES[rid]["name"] for rid in rids)
    first = record["runtimes"][rids[0]]
    prefix = "Nightly runtime check: one cause"
    title = f"{prefix} fails {names} at {first_failure(first)}"
    each = "\n\n".join(f"**{RUNTIMES[rid]['name']}** {record['runtimes'][rid].get('from') or '(untested)'} → "
                        f"{record['runtimes'][rid].get('to')}\n\n{steps_table(record['runtimes'][rid])}" for rid in rids)
    body = (f"{names} failed at {first_failure(first)} for one cause, on {base_name(record)}, run "
            f"{record['started']}.\n\n{each}\n\n{outputs_of(first)}\n\nFound by the nightly runtime check (#39).")
    return file_issue(prefix, title, body, dry_run)


def report(args):
    run = run_dir(args.home, args.run)
    record = load(os.path.join(run, "run.json"), {})
    state_path = os.path.join(args.home, "state.json")
    state = load(state_path, {})
    lines = []
    baseline = record.get("baseline") or {}
    if baseline.get("build") or baseline.get("tests"):
        what = "Agents Host does not build" if baseline.get("build") else ", ".join(baseline["tests"])
        lines.append(f"- Already failing on main ({base_name(record)}), filed for no runtime: {what}")
        print(f"Already failing on main ({base_name(record)}): {what}\n  "
              + (baseline.get("build") or baseline.get("tests_output") or "")[-2000:].replace("\n", "\n  "))
    if record.get("flaky"):
        lines.append(f"- Flaky, failed once and passed on a second run, filed for no runtime: "
                     f"{', '.join(record['flaky'])}")
    failed = {}
    for rid, entry in record["runtimes"].items():
        spec = RUNTIMES[rid]
        if entry["status"] == "skipped":
            lines.append(f"- {spec['name']}: skipped, {entry['why']}")
            continue
        if entry["status"] == "unchanged":
            continue
        if entry["status"] == "blocked":
            lines.append(f"- {spec['name']}: {entry['to']} not tested; main does not build")
            continue
        if entry["status"] == "testing" and not entry["steps"].get("turn"):
            lines.append(f"- {spec['name']}: {entry['to']} not tested; build or check did not run")
            continue
        passed = entry["status"] == "testing"
        print(f"{spec['name']} {entry.get('from')} → {entry['to']}: {'passed' if passed else 'failed at ' + first_failure(entry)}")
        if passed and spec["kind"] != "installed":
            sent = open_pr(run, record, rid, entry, args.dry_run)
            lines.append(f"- {spec['name']} {entry['to']}: passed; PR {'would be ' if args.dry_run else ''}"
                         f"{'opened or updated' if sent else 'NOT opened (see above)'} on nightly/runtime-{rid}")
        elif passed:
            lines.append(f"- {spec['name']} {entry['to']} (installed by the person): passed")
        else:
            failed.setdefault(cause(entry), []).append(rid)
        if not args.dry_run:
            state[rid] = {"version": entry["to"], "result": "passed" if passed else "failed",
                          "run": record["started"]}
    for (step, _), rids in failed.items():
        shared = len(rids) > 1
        sent = (open_shared_issue if shared else lambda r, ids, d: open_issue(r, ids[0], r["runtimes"][ids[0]], d))(
            record, rids, args.dry_run)
        names = ", ".join(f"{RUNTIMES[rid]['name']} {record['runtimes'][rid]['to']}" for rid in rids)
        lines.append(f"- {names}: failed at {step}; {'one issue for all, ' if shared else 'issue '}"
                     f"{'would be ' if args.dry_run else ''}{'opened or updated' if sent else 'NOT opened'}")
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
    parser.add_argument("--base", default="main",
                        help="plan: what the tree is tested on (default main, this Mac's own; PR branches "
                             "always start from origin/main)")
    parser.add_argument("--force", action="store_true", help="test even what has not changed")
    parser.add_argument("--dry-run", action="store_true", help="report: open, push and record nothing")
    parser.add_argument("--keep", action="store_true", help="check: leave the scratch root on disk")
    args = parser.parse_args()
    args.home = os.path.abspath(os.path.expanduser(args.home))
    {"plan": plan, "build": build, "check": check, "report": report}[args.phase](args)


if __name__ == "__main__":
    main()
