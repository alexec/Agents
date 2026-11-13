#!/usr/bin/env python3
"""Where recent sessions spent their time (the dev-speed skill).

Reads the app's own session records (agent.json and transcript.jsonl under
~/Library/Application Support/Agents/agents), for the sessions of one folder
that were active in the last N days, and prints:

- the totals: running time, split into tool time and model time (thinking and
  writing), and the time between turns, split by what woke the session. Waits
  do not count as running: the in-call part of a wait (the daemon holds a
  wait_for_event call for up to 45 s) is a line of its own;
- waits, call to wake: each wait from its call to what woke the session, by
  event, and the share answered inside the call; with --forge, the lost waits
  (a wait on pr.merged or pr.closed that timed out after its PR merged or closed);
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


# Tools that start a wait. The call is only the first part of it: the daemon
# holds it for up to 45 s, then the wait goes on with the turn ended. A wait is
# not running time.
WAITS = {"wait_for_event", "ask_question", "hand_to_person"}


def is_wait(c: dict) -> bool:
    return category(c["title"], c["kind"]).startswith("wait: ")


def in_call_answer(c: dict) -> str | None:
    """What answered a wait inside its call, or None when the wait went on."""
    text = c.get("text", "")
    m = re.search(r"(?:^|\s)([\w.]+) happened at \d", text)
    if m:
        r = re.search(r"\bresource=([^,\s]+)", text)
        return f"event: {m.group(1)}" + (f" ({r.group(1).rstrip('.')})" if r else "")
    if text.startswith("Not waiting:"):
        return "event: agent.ended (already ended)"
    if text.startswith(("They answered", "They skipped")) or c["title"] == "Asking for your input":
        return "question answered"
    if text.startswith(("The person did", "The person could not do")):
        return "person's step done"
    if "cancelled your wait" in text or "ended your wait" in text or "with no match" in text:
        return "wait cancelled"
    return None


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
        name = title.split("__", 2)[-1]
        return ("wait: " if name in WAITS else "tool: ") + name
    if title == "Asking for your input":
        return "wait: question to the person"
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
    if first.startswith("The time you asked for has come"):
        return "time reached"
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
        elif k == "userMessage":
            messages.append((at, wake_reason(v.get("_0", ""))))
            if stopped_at is not None:
                gaps.append((messages[-1][1], (at - stopped_at).total_seconds()))
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
            if isinstance(u.get("rawInput"), dict) and u["rawInput"]:
                c["input"] = u["rawInput"]
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
                c["text"] = "".join((x.get("content") or {}).get("text", "") for x in u.get("content", [])
                                    if isinstance(x, dict))
    if run_start is not None:
        running.append((run_start, events[-1][0]))
    done = sorted((c for c in calls.values() if c["end"] is not None), key=lambda c: c["start"])

    # Each wait, from its call to what ended it: an answer inside the call, or
    # the first message after the call (the wake). A wait that a later wait
    # call replaced before any wake, or that is still open, is left out.
    waits = []
    started = [c for c in done if is_wait(c) and c["status"] == "completed"]
    for i, c in enumerate(started):
        answer = in_call_answer(c)
        if answer:
            waits.append({"woken_by": answer, "s": (c["end"] - c["start"]).total_seconds(),
                          "in_call": True, "input": c["input"], "start": c["start"], "woke": c["end"]})
            continue
        wake = next(((at, r) for at, r in messages if at >= c["end"]), None)
        if wake is None:
            continue
        if i + 1 < len(started) and started[i + 1]["start"] < wake[0]:
            continue
        waits.append({"woken_by": wake[1], "s": (wake[0] - c["start"]).total_seconds(),
                      "in_call": False, "input": c["input"], "start": c["start"], "woke": wake[0]})

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
        "waits": waits,
        "tokens": tokens,
        "cost": (agent.get("costToDate") or {}).get("USD", 0.0),
    }


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


def subtract(spans, holes):
    """Parts of spans that fall outside the holes."""
    out = []
    holes = sorted(holes)
    for s, e in spans:
        cur = s
        for hs, he in holes:
            if he <= cur or hs >= e:
                continue
            if hs > cur:
                out.append((cur, hs))
            cur = max(cur, he)
        if cur < e:
            out.append((cur, e))
    return out


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


def lost_waits(all_waits, folder: str) -> dict:
    """Waits on pr.merged or pr.closed that timed out though the PR had already merged or closed."""
    cache: dict[tuple[str, int], dict] = {}
    out = {"checked": 0, "count": 0, "total_s": 0.0, "examples": []}
    for w, title in all_waits:
        events = w["input"].get("events") or []
        where = w["input"].get("where") or {}
        if w["woken_by"] != "wait timed out" or not {"pr.merged", "pr.closed"} & set(events):
            continue
        prs = where.get("pr")
        prs = prs if isinstance(prs, list) else [prs]
        repo = where.get("repo") or ""
        for pr in prs:
            if not isinstance(pr, int):
                continue
            out["checked"] += 1
            key = (repo, pr)
            if key not in cache:
                cmd = ["gh", "pr", "view", str(pr), "--json", "mergedAt,closedAt"] + (["--repo", repo] if repo else [])
                try:
                    r = subprocess.run(cmd, cwd=folder, capture_output=True, text=True, timeout=30)
                    cache[key] = json.loads(r.stdout) if r.returncode == 0 else {}
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    cache[key] = {}
            info = cache[key]
            for how in ("mergedAt", "closedAt"):
                at = info.get(how)
                if at and parse_at(at) < w["woke"]:
                    out["count"] += 1
                    out["total_s"] += w["s"]
                    out["examples"].append({"pr": pr, "how": how.removesuffix("At"), "at": at,
                                            "woke": w["woke"].isoformat(timespec="seconds"),
                                            "s": w["s"], "session": title})
                    break
            break
    out["examples"].sort(key=lambda x: -x["s"])
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--folder", default=None, help="folder whose sessions to read (default: this repo's main checkout)")
    ap.add_argument("--store", default=STORE)
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--json", action="store_true", help="print the numbers as JSON")
    ap.add_argument("--forge", action="store_true",
                    help="ask the forge (gh) when each PR a timed-out wait named merged or closed, to count lost waits")
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
    in_call_count = 0
    whole: dict[str, list[tuple[float, bool]]] = defaultdict(list)
    all_waits = []
    by_cat: dict[str, list[float]] = defaultdict(list)
    failed: dict[str, int] = defaultdict(int)
    by_wake: dict[str, list[float]] = defaultdict(list)
    slowest = []
    repeats = []
    per_session = []
    for s in sessions:
        wait_spans = [(c["start"], c["end"]) for c in s["calls"] if is_wait(c)]
        in_call = clip(wait_spans, s["running"])
        active = subtract(s["running"], in_call)
        run = sum((e - b).total_seconds() for b, e in active)
        spans = [(c["start"], c["end"]) for c in s["calls"] if not is_wait(c)]
        tools = union_seconds(clip(spans, active))
        run_total += run
        tool_total += tools
        in_call_total += union_seconds(in_call)
        in_call_count += len(wait_spans)
        for w in s["waits"]:
            whole[w["woken_by"]].append((w["s"], w["in_call"]))
            all_waits.append((w, s["title"][:50]))
        seen: dict[str, list[float]] = defaultdict(list)
        for c in s["calls"]:
            if is_wait(c):
                continue
            dur = (c["end"] - c["start"]).total_seconds()
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
    wait_rows = sorted(whole.items(), key=lambda kv: -sum(d for d, _ in kv[1]))
    wait_s = [w["s"] for w, _ in all_waits]
    answered = sum(1 for w, _ in all_waits if w["in_call"])
    lost = lost_waits(all_waits, folder) if args.forge else None
    cats = sorted(by_cat.items(), key=lambda kv: -sum(kv[1]))
    wakes = sorted(by_wake.items(), key=lambda kv: -sum(kv[1]))
    slowest.sort(reverse=True)
    repeats.sort(reverse=True)
    per_session.sort(reverse=True)

    if args.json:
        json.dump({
            "folder": folder, "days": args.days, "sessions": len(sessions),
            "running_s": run_total, "tool_s": tool_total, "model_s": model_total,
            "wait_calls": in_call_count, "waits_in_call_s": in_call_total,
            "waits": [{"woken_by": k, "count": len(v), "total_s": sum(d for d, _ in v),
                       "median_s": statistics.median([d for d, _ in v]), "p90_s": pct([d for d, _ in v], 0.9),
                       "answered_in_call": sum(1 for _, i in v if i)} for k, v in wait_rows],
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
    print(f"In-call part of waits {fmt(in_call_total)} ({in_call_count} calls): not running, not tools. "
          "The daemon holds a wait call for up to 45 s, then the wait goes on with the turn ended.")
    if wait_s:
        print(f"Waits, call to wake: {len(wait_s)}, median {fmt(statistics.median(wait_s))}, "
              f"p90 {fmt(pct(wait_s, 0.9))}, total {fmt(sum(wait_s))}; "
              f"{answered / len(wait_s):.0%} answered inside the call.")
    print(f"Between turns {fmt(sum(sum(v) for v in by_wake.values()))} (wall time a session sat waiting).\n")

    print("## Tool time by category\n")
    print("| Category | Calls | Total | Share of running | Median | p90 | Failed |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for k, v in cats[: args.top * 2]:
        print(f"| {k} | {len(v)} | {fmt(sum(v))} | {sum(v) / max(run_total, 1):.1%} | "
              f"{fmt(statistics.median(v))} | {fmt(pct(v, 0.9))} | {failed.get(k, 0)} |")

    print("\n## Waits, call to wake\n")
    print("From the wait call (`wait_for_event`, `ask_question`, `hand_to_person`, "
          "a question to the person) to what woke the session.\n")
    print("| Woken by | Waits | Median | p90 | Total | Answered in the call |")
    print("|---|---:|---:|---:|---:|---:|")
    for k, v in wait_rows:
        d = [x for x, _ in v]
        print(f"| {k} | {len(v)} | {fmt(statistics.median(d))} | {fmt(pct(d, 0.9))} | {fmt(sum(d))} | "
              f"{sum(1 for _, i in v if i) / len(v):.0%} |")
    if lost is None:
        print("\nLost waits: not counted (run with `--forge`).")
    else:
        print(f"\nLost waits: {lost['count']} of {lost['checked']} timed-out waits on `pr.merged` or `pr.closed` "
              f"named a PR that had merged or closed before the time-out ({fmt(lost['total_s'])} waited).")
        for x in lost["examples"][: args.top]:
            print(f"- PR {x['pr']} {x['how']} {x['at']}, wait timed out {x['woke']} "
                  f"after {fmt(x['s'])}: {x['session']}")

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
