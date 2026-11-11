#!/usr/bin/env python3
"""Where recent sessions spent their time (the dev-speed skill).

Reads the app's own session records (agent.json and transcript.jsonl under
~/Library/Application Support/Agents/agents), for the sessions of one folder
that were active in the last N days, and prints:

- the totals: running time, split into tool time and model time (thinking and
  writing), and the time between turns, split by what woke the session. A wait
  is not running: the in-call part of a wait (the daemon holds a wait_for_event
  call for up to 45 s before the turn can end) is left out of the running and
  tool totals and shown on a line of its own;
- the waits, from the wait call to the wake, by what ended them, with the share
  answered inside the call; with --forge, the lost waits (a wait on pr.merged or
  pr.closed that timed out though the pull request had merged or closed);
- tool time by category (xcodebuild, swift test, go-changed, lint, gh, git,
  run-app, lease_resource, ...), with count, median, p90 and failures;
- the slowest single calls, the commands run again and again in one session,
  and the sessions that ran longest.

Read only. Standard library only, so it runs with `python3 -I`.
Usage: time-spent.py [--days 7] [--folder PATH] [--store PATH] [--json] [--top 15] [--forge]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

STORE = os.path.expanduser("~/Library/Application Support/Agents/agents")


def parse_at(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def default_folder() -> str:
    """The main checkout of the repo this script is in (not a worktree)."""
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        common = subprocess.run(
            ["git", "-C", here, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        return os.path.dirname(common)
    except (OSError, subprocess.CalledProcessError):
        return os.getcwd()


def path_of(url: str | None) -> str:
    if not url:
        return ""
    return url.removeprefix("file://").rstrip("/")


# --- Classify a tool call --------------------------------------------------

LEAD = re.compile(r"^\s*(?:cd\s+\S+\s*(?:&&|;)\s*|[A-Z_][A-Z0-9_]*=\S*\s+)+")


def command_of(title: str) -> str:
    """The command without its leading `cd x &&` and `VAR=value`."""
    first = title.strip().splitlines()[0] if title.strip() else ""
    return LEAD.sub("", first).strip()


RULES: list[tuple[str, str]] = [
    (r"xcodebuild\b.*\btest\b", "build: xcodebuild test"),
    (r"xcodebuild", "build: xcodebuild"),
    (r"swift\s+test", "test: swift test"),
    (r"swift\s+build", "build: swift build"),
    (r"go-changed\.sh", "test: go-changed.sh"),
    (r"\bgo\s+(test|vet)\b|go\.sh\s+(test|vet)", "test: go test/vet"),
    (r"\bgo\s+build\b|go\.sh\s+build", "build: go build"),
    (r"lint\.sh", "lint: lint.sh"),
    (r"web\.sh\s+(build|dist)", "build: web.sh"),
    (r"web\.sh\s+test|vitest|npm\s+(run\s+)?test", "test: web"),
    (r"wire\.sh", "gen: wire.sh"),
    (r"merge-wave\.sh", "merge-wave"),
    (r"pr-shots\.sh", "walk: pr-shots.sh"),
    (r"run-app/scripts/(\w[\w.-]*)", "walk: run-app {0}"),
    (r"\$S/(\w[\w.-]*)", "walk: run-app {0}"),
    (r"ship\.sh", "ship: ship.sh"),
    (r"walk\.py", "walk: walk.py"),
    (r"rearm-automerge\.sh", "gh: rearm-automerge.sh"),
    (r"gh\s+(pr\s+checks|run\s+(watch|view|list))", "ci: gh checks/runs"),
    (r"gh\s+(\w+)(?:\s+(\w+))?", "gh: {0} {1}"),
    (r"git\s+(push|fetch|pull|rebase|commit|merge|clone)", "git: {0}"),
    (r"git\s+\w+", "git: other"),
    (r"^sleep\b|;\s*sleep\b|&&\s*sleep\b", "sleep"),
    (r"^(cat|sed|head|tail|grep|rg|ls|find|wc|awk)\b", "shell: read/search"),
    (r"^python3?\b", "shell: python"),
]


# Tools that start a wait. A wait is not running time: the call holds the turn
# for a short time (the daemon's hold, up to 45 s), and then the wait goes on
# with the turn ended, until its event, its answer or its time-out.
WAITS = {"wait_for_event", "ask_question", "hand_to_person", "check_again"}

# What a wait call's result says.
HAPPENED = re.compile(r"(\S+) happened at \d")
RESOURCE = re.compile(r"\bresource=([^,.\s]+)")
ANSWERED = ("They answered", "The person did", "The person could not")
PENDING = ("Still waiting", "Recorded.", "Your place is kept", "has not finished yet",
           "You will be resumed")


def wait_name(title: str) -> str | None:
    if title.startswith("mcp__"):
        name = title.split("__", 2)[-1]
        return name if name in WAITS else None
    if title == "Asking for your input":
        return "ask_question"
    return None


def wait_outcome(tool: str, text: str) -> tuple[str, str | None]:
    """('answered', what) when the call itself got the event or the answer,
    ('pending', None) when the wait goes on after the call, ('none', None) when
    the call started no wait (an error, or 'Not waiting')."""
    m = HAPPENED.search(text)
    if m:
        r = RESOURCE.search(text)
        return "answered", f"event: {m.group(1)}" + (f" ({r.group(1)})" if r else "")
    if text.lstrip().startswith(ANSWERED):
        return "answered", "person or agent message"
    if any(p in text for p in PENDING):
        return "pending", None
    return "none", None


SETUP = re.compile(
    r"^(?:\s*(?:cd\s+\S+|(?:source|\.)\s+\S+|set\s+[-+]a|export\s+\S+|[A-Z_][A-Z0-9_]*=(?:\"[^\"]*\"|\S*))\s*(?:&&|;)?)+\s*"
)


def repeat_key(title: str) -> str:
    """A key for 'the same command again': a heredoc keeps its body."""
    text = " ".join(title.split())
    text = SETUP.sub("", text)
    return text[:160]


def category(title: str, kind: str | None) -> str:
    if title.startswith("mcp__"):
        return "tool: " + title.split("__", 2)[-1]
    if kind in ("read", "edit", "fetch", "think") or title in ("Read File", "Edit", "Write"):
        return f"file: {kind or title.lower()}"
    if title in ("ToolSearch", "Load skill", "Fetch"):
        return "tool: " + title
    cmd = command_of(title)
    for text in (cmd, " ".join(title.split())[:600]):
        for pattern, label in RULES:
            m = re.search(pattern, text)
            if m:
                groups = [g or "" for g in m.groups()]
                return label.format(*groups).strip() if groups else label
    word = cmd.split()[0] if cmd.split() else "?"
    return "shell: " + os.path.basename(word)[:30]


# --- Classify what woke a session ------------------------------------------

def wake_reason(text: str) -> str:
    first = text.strip().splitlines()[0] if text.strip() else ""
    if first.startswith("The event you were waiting for happened"):
        m = re.search(r"^event:\s*(\S+)", text, re.M) or re.search(r"^([\w.]+) at \d", text, re.M)
        name = m.group(1) if m else "?"
        r = re.search(r"^resource:\s*(\S+)", text, re.M)
        return f"event: {name}" + (f" ({r.group(1)})" if r else "")
    if first.startswith("Your wait for"):
        return "wait timed out"
    if first.startswith("The time you asked to check again"):
        return "check_again timer"
    if first.startswith("The wait you reported has cleared"):
        return "other sessions ended"
    if first.startswith(("You have moved", "You moved")):
        return "move_worktree restart"
    if first.startswith("(The app restarted"):
        return "app restarted"
    return "person or agent message"


# --- Read one session -------------------------------------------------------

def read_session(d: str, since: datetime) -> dict | None:
    try:
        with open(os.path.join(d, "agent.json")) as f:
            agent = json.load(f)
    except (OSError, ValueError):
        return None
    events = []
    try:
        with open(os.path.join(d, "transcript.jsonl")) as f:
            for line in f:
                try:
                    o = json.loads(line)
                    k = next(iter(o["kind"]))
                    events.append((parse_at(o["at"]), k, o["kind"][k]))
                except (ValueError, KeyError, StopIteration):
                    continue
    except OSError:
        return None
    events.sort(key=lambda e: e[0])
    events = [e for e in events if e[0] >= since]
    if not events:
        return None

    running: list[tuple[datetime, datetime]] = []
    gaps: list[tuple[str, float]] = []
    calls: dict[str, dict] = {}
    run_start: datetime | None = None
    stopped_at: datetime | None = None
    tokens = 0
    messages: list[tuple[datetime, str]] = []
    for at, k, v in events:
        if k == "stateChanged":
            state = v.get("_0")
            if state == "running":
                if run_start is None:
                    run_start = at
            elif run_start is not None:
                running.append((run_start, at))
                run_start, stopped_at = None, at
        if k == "userMessage":
            messages.append((at, v.get("_0", "")))
        if k == "userMessage" and stopped_at is not None:
            gaps.append((wake_reason(v.get("_0", "")), (at - stopped_at).total_seconds()))
            stopped_at = None
        elif k == "usageRecorded":
            tokens += v.get("_0", {}).get("totalTokens", 0)
        elif k in ("toolCall", "toolCallUpdate"):
            u = v.get("_0", {})
            cid = u.get("toolCallID") or u.get("raw", {}).get("toolCallId")
            if not cid:
                continue
            c = calls.setdefault(cid, {"start": at, "end": None, "title": "", "kind": None, "status": None,
                                       "input": {}, "text": ""})
            raw_input = u.get("rawInput")
            if isinstance(raw_input, dict) and len(raw_input) >= len(c["input"]):
                c["input"] = raw_input
            if k == "toolCall":
                c["start"] = min(c["start"], at)
                c["kind"] = u.get("kind")
            title = u.get("title") or ""
            if title and title not in ("Tool call", "Terminal", "Preparing file…"):
                if not c["title"] or c["title"].startswith("cd ") or len(title) > len(c["title"]):
                    c["title"] = title
            elif title and not c["title"]:
                c["title"] = title
            if u.get("status") in ("completed", "failed"):
                c["end"] = at
                c["status"] = u["status"]
                c["text"] = "".join((x.get("content") or {}).get("text", "")
                                    for x in u.get("content") or [] if isinstance(x, dict))
    if run_start is not None:
        running.append((run_start, events[-1][0]))
    done = sorted((c for c in calls.values() if c["end"] is not None), key=lambda c: c["start"])

    return {
        "id": agent.get("id"),
        "title": agent.get("title") or agent.get("runtimeTitle") or "",
        "runtime": agent.get("runtimeID"),
        "labels": [lb if isinstance(lb, str) else lb.get("name", "") for lb in agent.get("labels", [])],
        "cwd": path_of(agent.get("cwd")),
        "folder": path_of((agent.get("worktree") or {}).get("folder")),
        "running": running,
        "gaps": gaps,
        "calls": done,
        "waits": whole_waits(done, messages),
        "tokens": tokens,
        "cost": (agent.get("costToDate") or {}).get("USD", 0.0),
    }


def whole_waits(calls: list[dict], messages: list[tuple[datetime, str]]) -> list[dict]:
    """Each wait from its call to its wake. A wait answered in the call ends
    with the call; one that goes on ends at the next message that starts the
    session again (its event, its time-out, an answer, or a person); one that a
    later wait call replaces before that is left out."""
    started = [(c, wait_name(c["title"])) for c in calls]
    started = [(c, n) for c, n in started if n]
    out = []
    for i, (c, tool) in enumerate(started):
        state, ended_by = wait_outcome(tool, c["text"])
        if state == "none":
            continue
        w = {"tool": tool, "start": c["start"], "in_call": state == "answered", "input": c["input"]}
        if state == "answered":
            w["end"], w["ended_by"] = c["end"], ended_by
        else:
            wake = next(((at, t) for at, t in messages if at >= c["end"]), None)
            if wake is None:
                continue  # still waiting at the end of the window
            later = started[i + 1][0]["start"] if i + 1 < len(started) else None
            if later is not None and later < wake[0]:
                continue  # replaced by the next wait call
            w["end"], w["ended_by"] = wake[0], wake_reason(wake[1])
        out.append(w)
    return out


def union_seconds(spans: list[tuple[datetime, datetime]]) -> float:
    total, end = 0.0, None
    for s, e in sorted(spans):
        if end is None or s > end:
            total += (e - s).total_seconds()
            end = e
        elif e > end:
            total += (e - end).total_seconds()
            end = e
    return total


def clip(spans, bounds):
    """Parts of spans that fall inside the running intervals."""
    out = []
    for s, e in spans:
        for bs, be in bounds:
            lo, hi = max(s, bs), min(e, be)
            if hi > lo:
                out.append((lo, hi))
    return out


# --- Report -------------------------------------------------------------

def fmt(sec: float) -> str:
    sec = int(round(sec))
    if sec >= 3600:
        return f"{sec // 3600}h{sec % 3600 // 60:02d}m"
    if sec >= 60:
        return f"{sec // 60}m{sec % 60:02d}s"
    return f"{sec}s"


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))]


def lost_waits(waits: list[dict], folder: str) -> dict:
    """Waits on pr.merged or pr.closed that timed out though the pull request
    had merged or closed before the time-out (asks `gh pr view`, once per PR)."""
    seen: dict[int, datetime | None] = {}
    checked, examples = 0, []
    for w in waits:
        if w["tool"] != "wait_for_event" or w["ended_by"] != "wait timed out":
            continue
        events = w["input"].get("events") or [w["input"].get("event")]
        pr = (w["input"].get("where") or {}).get("pr")
        if not {"pr.merged", "pr.closed"} & set(events) or not isinstance(pr, int):
            continue
        checked += 1
        if pr not in seen:
            try:
                out = subprocess.run(["gh", "pr", "view", str(pr), "--json", "mergedAt,closedAt"],
                                     cwd=folder, capture_output=True, text=True, check=True, timeout=30).stdout
                o = json.loads(out)
                at = o.get("mergedAt") or o.get("closedAt")
                seen[pr] = parse_at(at) if at else None
            except (OSError, subprocess.SubprocessError, ValueError):
                seen[pr] = None
        done = seen[pr]
        if done is not None and done < w["end"]:
            examples.append({"pr": pr, "late_s": (w["end"] - max(done, w["start"])).total_seconds(),
                             "session": w.get("session", "")})
    examples.sort(key=lambda x: -x["late_s"])
    return {"count": len(examples), "checked": checked,
            "total_s": sum(x["late_s"] for x in examples), "examples": examples}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--folder", default=None, help="folder whose sessions to read (default: this repo's main checkout)")
    ap.add_argument("--store", default=STORE)
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--json", action="store_true", help="print the numbers as JSON")
    ap.add_argument("--forge", action="store_true",
                    help="count lost waits with `gh pr view` (needs the network; slower)")
    args = ap.parse_args()

    folder = os.path.abspath(args.folder or default_folder())
    since = datetime.now(timezone.utc) - timedelta(days=args.days)
    sessions = []
    for name in os.listdir(args.store):
        d = os.path.join(args.store, name)
        try:
            if datetime.fromtimestamp(os.path.getmtime(d), timezone.utc) < since:
                continue
        except OSError:
            continue
        s = read_session(d, since)
        if not s:
            continue
        where = s["folder"] or s["cwd"]
        if where != folder and not where.startswith(folder + "/"):
            continue
        sessions.append(s)

    run_total = tool_total = in_call_total = 0.0
    in_call_by_tool: dict[str, list[float]] = defaultdict(list)
    by_end: dict[str, list[tuple[float, bool]]] = defaultdict(list)
    all_waits = []
    by_cat: dict[str, list[float]] = defaultdict(list)
    failed: dict[str, int] = defaultdict(int)
    by_wake: dict[str, list[float]] = defaultdict(list)
    slowest = []
    repeats = []
    per_session = []
    for s in sessions:
        # A wait is not running: its in-call part comes off the running time.
        wait_spans = [(c["start"], c["end"]) for c in s["calls"] if wait_name(c["title"])]
        spans = [(c["start"], c["end"]) for c in s["calls"]]
        in_call = union_seconds(clip(wait_spans, s["running"]))
        run = sum((e - b).total_seconds() for b, e in s["running"]) - in_call
        tools = union_seconds(clip(spans, s["running"])) - in_call
        run_total += run
        tool_total += tools
        in_call_total += in_call
        for w in s["waits"]:
            by_end[w["ended_by"]].append(((w["end"] - w["start"]).total_seconds(), w["in_call"]))
            all_waits.append({**w, "session": s["title"][:50]})
        seen: dict[str, list[float]] = defaultdict(list)
        for c in s["calls"]:
            dur = (c["end"] - c["start"]).total_seconds()
            tool = wait_name(c["title"])
            if tool:
                in_call_by_tool[tool].append(dur)
                continue
            cat = category(c["title"], c["kind"])
            by_cat[cat].append(dur)
            if c["status"] == "failed":
                failed[cat] += 1
            slowest.append((dur, cat, command_of(c["title"])[:100], s["title"][:50]))
            if not c["title"].startswith("mcp__") and c["kind"] == "execute":
                seen[repeat_key(c["title"])].append(dur)
        for cmd, durs in seen.items():
            if len(durs) >= 3 and sum(durs) >= 60:
                repeats.append((sum(durs), len(durs), cmd, s["title"][:50]))
        for reason, sec in s["gaps"]:
            by_wake[reason].append(sec)
        per_session.append((run, tools, s["title"][:60], s["id"], s["tokens"], s["cost"]))

    model_total = max(0.0, run_total - tool_total)
    lost = lost_waits(all_waits, folder) if args.forge else None
    ends = sorted(by_end.items(), key=lambda kv: -sum(d for d, _ in kv[1]))
    cats = sorted(by_cat.items(), key=lambda kv: -sum(kv[1]))
    wakes = sorted(by_wake.items(), key=lambda kv: -sum(kv[1]))
    slowest.sort(reverse=True)
    repeats.sort(reverse=True)
    per_session.sort(reverse=True)

    if args.json:
        json.dump({
            "folder": folder, "days": args.days, "sessions": len(sessions),
            "running_s": run_total, "tool_s": tool_total, "model_s": model_total,
            "in_call_waits_s": in_call_total,
            "in_call_waits": [{"tool": k, "count": len(v), "total_s": sum(v), "median_s": statistics.median(v)}
                              for k, v in sorted(in_call_by_tool.items(), key=lambda kv: -sum(kv[1]))],
            "waits": [{"ended_by": k, "count": len(v), "median_s": statistics.median([d for d, _ in v]),
                       "p90_s": pct([d for d, _ in v], 0.9), "total_s": sum(d for d, _ in v),
                       "answered_in_call": sum(1 for _, a in v if a) / len(v)} for k, v in ends],
            "lost_waits": lost,
            "categories": [{"category": k, "count": len(v), "total_s": sum(v),
                            "median_s": statistics.median(v), "p90_s": pct(v, 0.9),
                            "failed": failed.get(k, 0)} for k, v in cats],
            "between_turns": [{"woken_by": k, "count": len(v), "total_s": sum(v),
                               "median_s": statistics.median(v)} for k, v in wakes],
            "slowest_calls": [{"s": d, "category": c, "command": cmd, "session": t} for d, c, cmd, t in slowest[:args.top]],
            "repeated_commands": [{"total_s": t, "times": n, "command": c, "session": s} for t, n, c, s in repeats[:args.top]],
            "sessions_longest": [{"running_s": r, "tool_s": t, "title": ti, "id": i, "tokens": tok, "usd": usd}
                                 for r, t, ti, i, tok, usd in per_session[:args.top]],
        }, sys.stdout, indent=1, default=str)
        print()
        return 0

    print(f"# Time spent: {len(sessions)} sessions in {folder}, last {args.days:g} days\n")
    if not sessions:
        print("No sessions found.")
        return 0
    print(f"Running {fmt(run_total)}: tools {fmt(tool_total)} ({tool_total / max(run_total, 1):.0%}), "
          f"model {fmt(model_total)} ({model_total / max(run_total, 1):.0%}).")
    n_waits = sum(len(v) for v in in_call_by_tool.values())
    print(f"Not in those: the in-call part of waits, {fmt(in_call_total)} in {n_waits} calls "
          f"(a wait call holds the turn for up to 45 s, then the wait goes on with the turn ended).")
    print(f"Between turns {fmt(sum(sum(v) for v in by_wake.values()))} (wall time a session sat waiting).\n")

    print("## Tool time by category\n")
    print("| Category | Calls | Total | Share of running | Median | p90 | Failed |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for k, v in cats[: args.top * 2]:
        print(f"| {k} | {len(v)} | {fmt(sum(v))} | {sum(v) / max(run_total, 1):.1%} | "
              f"{fmt(statistics.median(v))} | {fmt(pct(v, 0.9))} | {failed.get(k, 0)} |")

    print("\n## Waits, call to wake\n")
    print("From the wait call (wait_for_event, check_again, ask_question, hand_to_person) to the event,")
    print("answer or time-out that ended it. A wait is not running time.\n")
    print("| Ended by | Waits | Median | p90 | Total | Answered in the call |")
    print("|---|---:|---:|---:|---:|---:|")
    for k, v in ends:
        d = [x for x, _ in v]
        print(f"| {k} | {len(v)} | {fmt(statistics.median(d))} | {fmt(pct(d, 0.9))} | {fmt(sum(d))} | "
              f"{sum(1 for _, a in v if a) / len(v):.0%} |")
    every = [x for v in by_end.values() for x in v]
    if every:
        d = [x for x, _ in every]
        print(f"| **All waits** | {len(every)} | {fmt(statistics.median(d))} | {fmt(pct(d, 0.9))} | "
              f"{fmt(sum(d))} | {sum(1 for _, a in every if a) / len(every):.0%} |")
    if lost is None:
        print("\nLost waits: not counted (run with --forge).")
    else:
        print(f"\nLost waits: {lost['count']} of {lost['checked']} timed-out waits on pr.merged or pr.closed "
              f"timed out though the pull request had merged or closed, {fmt(lost['total_s'])} in all.")
        for x in lost["examples"][: args.top]:
            print(f"- PR #{x['pr']}: done {fmt(x['late_s'])} before the time-out ({x['session']})")

    print("\n## Between turns, by what woke the session\n")
    print("| Woken by | Times | Total | Median |")
    print("|---|---:|---:|---:|")
    for k, v in wakes:
        print(f"| {k} | {len(v)} | {fmt(sum(v))} | {fmt(statistics.median(v))} |")

    print(f"\n## The {args.top} slowest calls\n")
    print("| Time | Category | Command | Session |")
    print("|---:|---|---|---|")
    for d, c, cmd, t in slowest[: args.top]:
        print(f"| {fmt(d)} | {c} | `{cmd.replace('|', '¦')}` | {t} |")

    print("\n## Commands run 3 or more times in one session\n")
    print("| Total | Times | Command | Session |")
    print("|---:|---:|---|---|")
    for tot, n, cmd, t in repeats[: args.top]:
        print(f"| {fmt(tot)} | {n} | `{cmd[:100].replace('|', '¦')}` | {t} |")

    print(f"\n## The {args.top} longest-running sessions\n")
    print("| Running | Tools | Tokens | USD | Session | Id |")
    print("|---:|---:|---:|---:|---|---|")
    for r, t, ti, i, tok, usd in per_session[: args.top]:
        print(f"| {fmt(r)} | {fmt(t)} | {tok:,} | {usd:.2f} | {ti} | {i} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
