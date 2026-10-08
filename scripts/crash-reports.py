#!/usr/bin/env python3
"""Lists the crashes of this project's apps on this Mac, one per distinct stack (#392).

Reads, and never changes:

  ~/Library/Logs/DiagnosticReports/, ~/Library/DiagnosticReports/
      macOS crash reports (.ips) of Agents, Agents Host, agentsd, agents-control and
      agents-relay, and of swiftpm-testing-helper and xctest, which only count when the
      same stack also hits an app
  ~/Library/Logs/CrashReporter/MobileDevice/
      the Remote's reports, when a sync or devicectl has already put them on this Mac
  Application Support/Agents/crashes/crash-*.txt
      the window's crash notes (#76, #178), in its container and outside it; a note
      written up to five minutes before a window report names that report's exception

Each report is marked live (its binary is the one installed in ~/Applications, or was
when an earlier run recorded it in --live-builds), scratch (run from /tmp, a walk or
spike bundle, or a Debug build after Live builds began on 2026-10-04), or unknown.
Reports with the same stack share a signature, `crashsig` and twelve hex digits, which
the issue filed for it carries in its body so the next run finds it.

  scripts/crash-reports.py [--since 2026-10-06T03:00:00Z | --notes DIR] [--days 14]
                           [--live-builds FILE] [--github] [--out DIR] [--json]

--notes takes the folder of daily notes (.agents/reviews/crashes) and starts after the
newest note's `read-through:`. --github looks each signature up in the repository's
issues, read-only, and says what to do with it: file a new issue, comment on an open
one, or skip it. --out writes an issue body (new-<sig>.md) or a comment
(comment-<sig>.md) per signature to file, and plan.md. Nothing is ever filed from here.

Strings from reports pass through redact() before they are printed or written: home
folders become ~, and anything shaped like a token, key or password becomes <redacted>.
"""

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
REPORT_FOLDERS = [f"{HOME}/Library/Logs/DiagnosticReports", f"{HOME}/Library/DiagnosticReports"]
DEVICE_FOLDER = f"{HOME}/Library/Logs/CrashReporter/MobileDevice"
NOTE_GLOBS = [
    f"{HOME}/Library/Application Support/Agents/crashes/crash-*.txt",
    f"{HOME}/Library/Containers/com.alexecollins.agents*/Data/Library/Application Support/Agents/crashes/crash-*.txt",
]
LIVE_GLOBS = [
    f"{HOME}/Applications/AgentsLive/*/Agents.app/Contents/MacOS/Agents",
    f"{HOME}/Applications/Agents Host.app/Contents/MacOS/Agents Host",
    f"{HOME}/Applications/Agents Host.app/Contents/Helpers/*",
]
# Process name → what the issue calls it. The Remote's process is also "Agents", told
# apart by its platform and bundle id.
APPS = {
    "Agents": "the window",
    "Agents Host": "Agents Host",
    "agentsd": "agentsd",
    "agents-control": "agents-control",
    "agents-relay": "agents-relay",
    "AgentsWidget": "the Remote's widget",
    "RemoteNotify": "the Remote's notification extension",
}
TESTS = {"swiftpm-testing-helper", "xctest"}
OUR_IMAGES = set(APPS) | {f"{name}.debug.dylib" for name in APPS}
# Live builds are the `Live` configuration from this day on (#220), with no debug dylib.
LIVE_CONFIG_SINCE = dt.datetime(2026, 10, 5, tzinfo=dt.timezone.utc)
NOTE_WINDOW = dt.timedelta(minutes=5)
FRAMES_IN_SIGNATURE = 5

# Frames every crash of a kind shares, which say nothing about where it came from.
NOISE_IMAGES = {"libsystem_kernel.dylib", "libsystem_pthread.dylib", "libsystem_c.dylib",
                "libc++abi.dylib", "libdyld.dylib", "dyld"}
NOISE_SYMBOLS = re.compile(
    r"^(__exceptionPreprocess|objc_exception_throw|objc_exception_rethrow|_objc_terminate|"
    r"std::__terminate|abort|__pthread_kill|pthread_kill|"
    r".*_assertionFailure\(|.*_fatalErrorMessage\(|.*fatalError\(|swift_unexpectedError|"
    r"\+\[NSApplication _crashOnException:\]|-\[NSApplication _crashOnException:\]|"
    r"partial apply for |TaskLocal\.|.*thunk for |swift::runJobInEstablishedExecutorContext|"
    r"swift_job_run|_dispatch_)")

SECRET_PATTERNS = [
    (re.compile(r"(?i)\b(bearer|token|secret|password|passwd|api[_-]?key|authorization|cookie)"
                r"(\s*[:=]\s*|\s+)[\"']?[^\s\"',;]{6,}"), r"\1\2<redacted>"),
    (re.compile(r"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}"), "<redacted>"),
    (re.compile(r"\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{16,}"), "<redacted>"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), "<redacted>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+"), "<redacted>"),
    (re.compile(r"\b[0-9a-fA-F]{32,}\b"), "<redacted>"),
    # A long run of letters and digits mixed is a key; a long symbol has no digits.
    (re.compile(r"(?=[A-Za-z0-9+/_=-]*\d[A-Za-z0-9+/_=-]*\d[A-Za-z0-9+/_=-]*\d)"
                r"(?=[A-Za-z0-9+/_=-]*[a-z])(?=[A-Za-z0-9+/_=-]*[A-Z])[A-Za-z0-9+/_=-]{32,}"), "<redacted>"),
]


def redact(text):
    text = str(text).replace(HOME, "~")
    text = re.sub(r"/Users/(?!USER/)[^/\s]+", "/Users/USER", text)
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def parse_time(text):
    text = text.strip()
    for fmt in ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z", "%Y-%m-%dT%H:%M:%S%z",
                "%Y-%m-%dT%H:%M:%SZ", "%Y%m%dT%H%M%SZ"):
        try:
            when = dt.datetime.strptime(text.replace("Z", "+0000") if "%z" in fmt else text, fmt)
            return when if when.tzinfo else when.replace(tzinfo=dt.timezone.utc)
        except ValueError:
            continue
    raise ValueError(f"not a time: {text}")


def iso(when):
    return when.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local(when):
    return when.astimezone().strftime("%Y-%m-%d %H:%M %Z")


def binary_uuid(path):
    try:
        out = subprocess.run(["dwarfdump", "--uuid", path], capture_output=True, text=True,
                             timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [m.group(1).lower() for m in re.finditer(r"UUID: ([0-9A-Fa-f-]{36})", out)]


def live_builds(record):
    """UUID → what it is, for the binaries installed now and those recorded before."""
    builds = {}
    if record and os.path.exists(record):
        for line in open(record):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and not line.startswith("#"):
                builds[parts[0]] = parts[1]
    found = {}
    for pattern in LIVE_GLOBS:
        for path in glob.glob(pattern):
            if not os.access(path, os.X_OK) or os.path.isdir(path):
                continue
            sha = re.search(r"AgentsLive/([0-9a-f]{7,})-", path)
            what = os.path.basename(path) + (f" {sha.group(1)}" if sha else "")
            for uuid in binary_uuid(path):
                found[uuid] = what
    builds.update(found)
    return builds, found


def read_report(path):
    with open(path, errors="replace") as handle:
        text = handle.read()
    first, _, rest = text.partition("\n")
    header = json.loads(first)
    try:
        body = json.loads(rest)
    except json.JSONDecodeError:
        body = {}
    return header, body


def image_of(body, frame):
    images = body.get("usedImages") or []
    index = frame.get("imageIndex")
    return images[index] if isinstance(index, int) and index < len(images) else {}


def frames_of(body):
    """The frames that threw: the exception's backtrace, else the crashed thread's."""
    frames = body.get("lastExceptionBacktrace")
    if frames:
        return frames, "exception backtrace"
    threads = body.get("threads") or []
    for thread in threads:
        if thread.get("triggered"):
            return thread.get("frames") or [], "crashed thread"
    index = body.get("faultingThread")
    if isinstance(index, int) and index < len(threads):
        return threads[index].get("frames") or [], "crashed thread"
    return [], "no stack"


def describe(body, frame):
    image = image_of(body, frame).get("name") or "?"
    ours = image in OUR_IMAGES or "PackageTests" in image or image.startswith("Agents")
    symbol = frame.get("symbol") or f"+0x{frame.get('imageOffset', 0):x}"
    if len(symbol) > 160:
        symbol = symbol[:157] + "…"
    source = frame.get("sourceFile")
    line = frame.get("sourceLine")
    where = f" ({source}:{line})" if source and not source.startswith("/<") and line else ""
    return {"image": "app" if ours else image, "symbol": symbol, "where": where, "ours": ours,
            "noise": image in NOISE_IMAGES or bool(NOISE_SYMBOLS.match(symbol))
            or (source or "").startswith("/<compiler-generated>")}


def normalise_symbol(symbol):
    symbol = re.sub(r"^(specialized |merged |outlined |reabstraction )+", "", symbol)
    symbol = re.sub(r"\+0x[0-9a-f]+", "+?", symbol)
    return symbol


def normalise_reason(reason):
    reason = re.sub(r"0x[0-9a-fA-F]+", "0x?", reason)
    reason = re.sub(r"\d+", "N", reason)
    return reason[:200]


def read_note(path):
    note = {"path": path, "name": None, "reason": None, "thrown": None, "stale": False}
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return None
    note["stale"] = text.startswith("This exception was thrown more than")
    for line in text.splitlines():
        if line.startswith("Name: "):
            note["name"] = line[6:].strip()
        elif line.startswith("Reason: "):
            note["reason"] = line[8:].strip()
        elif line.startswith("Thrown: "):
            try:
                note["thrown"] = parse_time(line[8:].split(" on ")[0])
            except ValueError:
                pass
    if note["thrown"] is None:
        stamp = re.search(r"crash-(\d{4}-\d{2}-\d{2}T\d{6})", path)
        if stamp:
            note["thrown"] = dt.datetime.strptime(stamp.group(1), "%Y-%m-%dT%H%M%S").replace(
                tzinfo=dt.timezone.utc)
    note["container"] = (re.search(r"Containers/([^/]+)/", path) or [None, "none"])[1]
    return note


def place_of(header, body, process, live, when):
    proc_path = body.get("procPath") or ""
    bundle = (body.get("bundleInfo") or {}).get("CFBundleIdentifier") or header.get("bundleID") or ""
    uuid = (header.get("slice_uuid") or "").lower()
    if process in TESTS:
        return "test", "a test process"
    if re.match(r"^(/private)?/tmp/", proc_path):
        return "scratch", "run from /tmp"
    if re.search(r"\.(walk|spike)", bundle):
        return "scratch", f"bundle {bundle}"
    if uuid and uuid in live:
        return "live", f"the installed {live[uuid]}"
    if header.get("platform") == 2 or bundle.startswith("com.alexecollins.agents.remote"):
        return "live", "on a device"
    debug = any((image.get("name") or "").endswith(".debug.dylib")
                for image in body.get("usedImages") or [])
    if debug and when >= LIVE_CONFIG_SINCE:
        return "scratch", "a Debug build, and live builds are Live since #220"
    return "unknown", "not an installed live build: an earlier live build, or a copy from a worktree"


def collect(since):
    reports = []
    paths = []
    for folder in REPORT_FOLDERS:
        paths += glob.glob(os.path.join(folder, "*.ips"))
    device_reports = glob.glob(os.path.join(DEVICE_FOLDER, "**", "*.ips"), recursive=True)
    paths += device_reports
    for path in sorted(set(paths)):
        name = os.path.basename(path)
        if not any(name.startswith(p) for p in list(APPS) + list(TESTS)):
            continue
        if since and dt.datetime.fromtimestamp(os.path.getmtime(path), dt.timezone.utc) <= since:
            continue
        try:
            header, body = read_report(path)
        except (OSError, ValueError):
            reports.append({"path": path, "unreadable": True})
            continue
        if str(header.get("bug_type")) not in ("309", "109"):
            continue
        process = header.get("app_name") or header.get("name") or body.get("procName") or ""
        bundle = (body.get("bundleInfo") or {}).get("CFBundleIdentifier") or header.get("bundleID") or ""
        if process not in APPS and process not in TESTS:
            continue
        if bundle and not bundle.startswith("com.alexecollins.agents") and process not in TESTS:
            continue
        reports.append({"path": path, "header": header, "body": body, "process": process,
                        "bundle": bundle})
    return reports, device_reports


def signature_of(report, notes):
    header, body = report["header"], report["body"]
    when = parse_time(header.get("timestamp") or body.get("captureTime"))
    frames, source = frames_of(body)
    described = [describe(body, frame) for frame in frames]
    kept = [d for d in described if not d["noise"]] or described
    exception = body.get("exception") or {}
    kind = exception.get("type") or "?"
    asi = body.get("asi") or {}
    messages = [m for lines in asi.values() for m in (lines if isinstance(lines, list) else [lines])
                if m and m != "abort() called"]
    note = None
    if report["process"] == "Agents" and header.get("platform") != 2:
        near = [n for n in notes if n["thrown"] and timedelta_ok(n["thrown"], when)]
        note = max(near, key=lambda n: n["thrown"]) if near else None
    parts = [kind] + [f"{d['image']}`{normalise_symbol(d['symbol'])}" for d in kept[:FRAMES_IN_SIGNATURE]]
    if note and note["name"]:
        parts += [note["name"], normalise_reason(note["reason"] or "")]
    signature = "crashsig" + hashlib.sha1("\n".join(parts).encode()).hexdigest()[:12]
    # The nearest of our frames to the throw; `main` at the bottom of every stack is not it.
    first_ours = next((d for d in kept[:15] if d["ours"]
                       and not re.search(r"entry_point|^(static )?\w*\.?\$main\(\)", d["symbol"])), None)
    return {
        "signature": signature, "when": when, "kind": kind,
        "signal": exception.get("signal"), "source": source,
        "frames": [f"{d['image']} {d['symbol']}{d['where']}" for d in kept[:8]],
        "ours": f"{first_ours['symbol']}{first_ours['where']}" if first_ours else None,
        "messages": messages, "note": note,
    }


def timedelta_ok(thrown, crashed):
    return dt.timedelta(seconds=-5) <= crashed - thrown <= NOTE_WINDOW


def gh_issues(query):
    try:
        out = subprocess.run(
            ["gh", "issue", "list", "--state", "all", "--limit", "10", "--search", query,
             "--json", "number,title,state,closedAt,url"],
            capture_output=True, text=True, timeout=60, check=True).stdout
        return json.loads(out)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return {"error": str(error)}


def decide(group):
    """What the run does with a signature, from the issues that carry it."""
    if all(r["place"] == "test" for r in group["reports"]):
        return "skip", "tests only (out of scope unless the same stack hits an app)"
    issues = gh_issues(f"{group['signature']} in:body")
    group["issues"] = issues
    if isinstance(issues, dict):
        return "check", f"GitHub search failed: {issues['error']}"
    for issue in issues:
        if issue["state"] == "OPEN":
            return "comment", f"#{issue['number']} is open"
    last = group["last"]
    for issue in sorted(issues, key=lambda i: i.get("closedAt") or "", reverse=True):
        closed = issue.get("closedAt")
        if closed and parse_time(closed) > last:
            return "skip", f"#{issue['number']} was closed after it last happened"
        if closed:
            return "new", f"came back after #{issue['number']} was closed"
    hint = group["search"]
    group["candidates"] = gh_issues(hint) if hint else []
    return "new", "no issue carries this signature"


def search_hint(group):
    note = group.get("note")
    if note and note.get("name"):
        return f"\"{note['name']}\" in:body,title"
    if group.get("ours"):
        name = re.sub(r"\(.*$", "", group["ours"]).split(" in ")[-1].strip()
        return f"\"{name}\" in:body,title" if name else None
    return None


def body_for(group, since):
    note = group.get("note")
    lines = [
        f"{group['label']} crashed {group['count']} time{'s' if group['count'] != 1 else ''}"
        f" ({', '.join(sorted(group['places']))}), first {local(group['first'])},"
        f" last {local(group['last'])}.",
        "",
        "## What threw",
        "",
        f"- **Exception:** {group['kind']}" + (f" ({group['signal']})" if group["signal"] else ""),
    ]
    if note and note.get("name"):
        lines.append(f"- **Crash note:** {note['name']}: {redact(note['reason'] or '')}"
                     + (" (written more than 5 s before the window died)" if note["stale"] else ""))
    for message in group["messages"][:3]:
        lines.append(f"- **Message:** {redact(message)[:300]}")
    if group.get("ours"):
        lines.append(f"- **Our code:** `{redact(group['ours'])}`")
    lines += ["", f"The {group['source']}, without the frames every crash shares:", "", "```"]
    lines += [redact(f) for f in group["frames"]]
    lines += ["```", "", "## Reports", ""]
    for report in group["reports"][:10]:
        lines.append(f"- {local(report['when'])} · {report['process']} · {report['place']}"
                     f" ({redact(report['why'])}) · `{os.path.basename(report['path'])}`")
    if len(group["reports"]) > 10:
        lines.append(f"- and {len(group['reports']) - 10} more")
    lines += ["", f"Crash signature: {group['signature']} (from `scripts/crash-reports.py`; the "
              "daily crash workflow looks this up before filing again)."]
    return "\n".join(lines) + "\n"


def comment_for(group):
    return (f"Crashed again: {group['count']} more time{'s' if group['count'] != 1 else ''}"
            f" ({', '.join(sorted(group['places']))}), last {local(group['last'])}"
            f" (`{os.path.basename(group['reports'][-1]['path'])}`).\n\n"
            f"Crash signature: {group['signature']}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--since", help="only reports written after this time (ISO 8601)")
    parser.add_argument("--notes", help="folder of daily notes; start after the newest read-through")
    parser.add_argument("--days", type=int, default=14, help="with no start, look this far back")
    parser.add_argument("--live-builds", help="file of live binary UUIDs; read, and added to")
    parser.add_argument("--github", action="store_true", help="look signatures up in issues (read-only)")
    parser.add_argument("--out", help="write plan.md and an issue or comment draft per signature")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    started = dt.datetime.now(dt.timezone.utc)
    since = parse_time(args.since) if args.since else None
    if not since and args.notes:
        newest = sorted(glob.glob(os.path.join(args.notes, "????-??-??.md")))
        for path in reversed(newest):
            found = re.search(r"^read-through:\s*(\S+)", open(path).read(), re.M)
            if found:
                since = parse_time(found.group(1))
                break
    if not since:
        since = started - dt.timedelta(days=args.days)

    live, installed = live_builds(args.live_builds)
    if args.live_builds:
        known = set()
        if os.path.exists(args.live_builds):
            known = {l.split("\t")[0] for l in open(args.live_builds) if not l.startswith("#")}
        with open(args.live_builds, "a") as handle:
            for uuid, what in installed.items():
                if uuid not in known:
                    handle.write(f"{uuid}\t{what}\t{iso(started)}\n")

    notes = [n for n in (read_note(p) for g in NOTE_GLOBS for p in glob.glob(g)) if n]
    reports, device_reports = collect(since)
    groups = {}
    unreadable = []
    for report in reports:
        if report.get("unreadable"):
            unreadable.append(report["path"])
            continue
        try:
            sig = signature_of(report, notes)
        except (ValueError, TypeError, KeyError):
            unreadable.append(report["path"])
            continue
        place, why = place_of(report["header"], report["body"], report["process"], live, sig["when"])
        platform = report["header"].get("platform")
        label = ("the Remote" if report["process"] == "Agents" and platform == 2
                 else APPS.get(report["process"], report["process"]))
        group = groups.setdefault(sig["signature"], {
            **{k: sig[k] for k in ("signature", "kind", "signal", "source", "frames", "ours",
                                   "messages", "note")},
            "label": label, "reports": [], "places": set(), "first": sig["when"], "last": sig["when"]})
        if group["label"] != label and label not in group["label"]:
            group["label"] += f", {label}"
        group["note"] = group["note"] or sig["note"]
        group["reports"].append({"path": report["path"], "when": sig["when"], "place": place,
                                 "why": why, "process": report["process"]})
        group["places"].add(place)
        group["first"] = min(group["first"], sig["when"])
        group["last"] = max(group["last"], sig["when"])

    used_notes = {g["note"]["path"] for g in groups.values() if g["note"]}
    new_notes = [n for n in notes if n["thrown"] and n["thrown"] > since and n["path"] not in used_notes]

    ordered = sorted(groups.values(), key=lambda g: g["last"], reverse=True)
    for group in ordered:
        group["reports"].sort(key=lambda r: r["when"])
        group["count"] = len(group["reports"])
        group["search"] = search_hint(group)
        if args.github:
            group["action"], group["because"] = decide(group)
        else:
            tests_only = all(r["place"] == "test" for r in group["reports"])
            group["action"], group["because"] = (("skip", "tests only") if tests_only
                                                 else ("look up", "run with --github"))

    plan = [f"read-through: {iso(started)}",
            f"since: {iso(since)}",
            f"reports: {len(reports) - len(unreadable)} of our processes, {len(groups)} signatures",
            f"remote: {len(device_reports)} device reports on this Mac"
            + ("" if device_reports else f" (none in {DEVICE_FOLDER.replace(HOME, '~')})"),
            f"live builds known: {len(live)} ({len(installed)} installed now)",
            ""]
    for group in ordered:
        plan.append(f"{group['action'].upper():8} {group['signature']}  {group['label']} · "
                    f"{group['count']}× · {', '.join(sorted(group['places']))} · last {local(group['last'])}"
                    f" — {group['because']}")
        top = group["note"]["name"] + ": " + redact(group["note"]["reason"] or "") if group["note"] \
            else (group["messages"][0] if group["messages"] else group["ours"] or (group["frames"] or ["?"])[0])
        plan.append(f"         {redact(top)[:160]}")
        for issue in group.get("candidates") or []:
            if isinstance(issue, dict) and "number" in issue:
                plan.append(f"         maybe #{issue['number']} ({issue['state'].lower()}): {issue['title']}")
    for note in new_notes:
        plan.append(f"NOTE     {os.path.basename(note['path'])} ({note['container']}) with no report:"
                    f" {note['name']}: {redact(note['reason'] or '')[:120]}")
    for path in unreadable:
        plan.append(f"UNREAD   {redact(path)}")
    if not groups and not new_notes:
        plan.append("none: no crash of ours since the last run")

    if args.out:
        os.makedirs(args.out, exist_ok=True)
        for group in ordered:
            if group["action"] in ("new", "look up", "check"):
                open(os.path.join(args.out, f"new-{group['signature']}.md"), "w").write(body_for(group, since))
            if group["action"] == "comment":
                open(os.path.join(args.out, f"comment-{group['signature']}.md"), "w").write(comment_for(group))
        open(os.path.join(args.out, "plan.md"), "w").write("\n".join(plan) + "\n")

    if args.json:
        def plain(value):
            if isinstance(value, dt.datetime):
                return iso(value)
            if isinstance(value, set):
                return sorted(value)
            raise TypeError(type(value))
        out = {"read-through": iso(started), "since": iso(since),
               "device_reports": len(device_reports), "groups": ordered,
               "notes_without_report": new_notes, "unreadable": unreadable}
        print(redact(json.dumps(out, default=plain, indent=1)))
    else:
        print("\n".join(plan))


if __name__ == "__main__":
    sys.exit(main())
