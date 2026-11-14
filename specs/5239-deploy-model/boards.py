#!/usr/bin/env python3
"""Draws the boards of spec 5239, Deploys, as SVG, from data.json (fetch.py).

Paper palette, light mode, as specs/5166-build-deploy-trends/boards.py. The figures are real:
agentloops-dev/Agents' GitHub Deployments of the last 30 days (release, app-store) and 7 days
(github-pages), its version tags and the PRs in each. What is scratch is said on its board: the
page around a panel, and the general cases on board 3 that this repo does not have (a canary
share, a region label, a rollback, a cancelled deploy). The orange numbers are the notes in
spec.md, "The boards".

How this repo's deployments map to targets (spec, "The simple case stays simple"; the names come
from the deploy notice of #5242):
  release / job mac         → Mac app       @ github-releases (production)
  release / job testflight  → Remote        @ testflight      (testing)
  app-store / job submit    → Remote        @ app-store       (production)
  github-pages              → Docs          @ github-pages    (production)

python3 fetch.py && python3 boards.py
"""
import datetime
import json
import re
import statistics
import subprocess
import zoneinfo
from pathlib import Path

HERE = Path(__file__).parent
TZ = zoneinfo.ZoneInfo("America/Los_Angeles")
INK, SEC, TER = "#1C1D20", "#5B616B", "#8A9099"
GROUND, RAISED, RULE, FILL = "#F7F8F9", "#FFFFFF", "#DDE1E6", "#EEF0F3"
ACCENT, NOTE, FAIL, GREEN = "#0A6CDB", "#B35900", "#B42318", "#1A7F37"
FONT = "-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"
DEFS = ('<defs><filter id="shadow" x="-5%" y="-5%" width="110%" height="115%">'
        '<feDropShadow dx="0" dy="6" stdDeviation="10" flood-color="#000" flood-opacity="0.18"/></filter></defs>')
# State chips: (words colour, ground).
CHIP = {"live": (GREEN, "#E3F4E8"), "waiting": (NOTE, "#FBEBD9"), "running": (ACCENT, "#E6F0FC"),
        "failed": (FAIL, "#FBE4E2"), "cancelled": (SEC, FILL), "replaced": (TER, FILL), "rollback": (NOTE, "#FBEBD9")}
TIER = {"production": ("#5B3FA0", "#EEE8F8"), "testing": (SEC, FILL), "staging": (SEC, FILL)}

DATA = json.loads((HERE / "data.json").read_text())
FETCHED = datetime.datetime.fromisoformat(DATA["fetched"])


def t(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def local(s):
    return (t(s) if isinstance(s, str) else s).astimezone(TZ)


def dur(sec):
    if sec < 90:
        return f"{sec:.0f} s"
    if sec < 3600:
        return f"{sec / 60:.0f} min"
    if sec < 86400 * 2:
        h, m = int(sec // 3600), int(sec % 3600 // 60)
        return f"{h} h {m} min" if m else f"{h} h"
    return f"{sec / 86400:.1f} days"


def when(s):
    return f"{local(s):%-d %b, %H:%M}"


def wrap(s, n):
    out, cur = [], ""
    for word in s.split():
        if cur and len(cur) + 1 + len(word) > n:
            out.append(cur)
            cur = word
        else:
            cur = (cur + " " + word).strip()
    return out + ([cur] if cur else [])


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# --- the model, from the deployments ------------------------------------------------------------
TARGETS = {("release", "mac"): ("Mac app", "github-releases", "production"),
           ("release", "testflight"): ("Remote", "testflight", "testing"),
           ("app-store", "submit"): ("Remote", "app-store", "production"),
           ("github-pages", ""): ("Docs", "github-pages", "production")}


def deploy(d):
    """A deployment in the model: target, version, state and times (spec, "Deploy states")."""
    comp, env, tier = TARGETS[(d["environment"], d["job"])]
    st = [s for s in d["statuses"] if s["state"] != "inactive"]
    last = st[-1]["state"]
    state = {"success": "live", "failure": "failed", "error": "failed", "waiting": "waiting",
             "queued": "running", "in_progress": "running"}[last]
    first_wait = next((s["at"] for s in st if s["state"] == "waiting"), d["created"])
    first_run = next((s["at"] for s in st if s["state"] == "in_progress"), None)
    end = st[-1]["at"] if last in ("success", "failure", "error") else None
    return {"id": d["id"], "comp": comp, "env": env, "tier": tier, "ref": d["ref"], "sha": d["sha"][:7],
            "state": state, "created": d["created"], "wait": first_wait, "run": first_run, "end": end,
            }


DEPLOYS = [deploy(d) for d in DATA["deploys"]]
# Replaced: a newer live deploy to the same target (spec: computed, not GitHub's inactive).
for d in DEPLOYS:
    if d["state"] == "live" and any(e["comp"] == d["comp"] and e["env"] == d["env"] and e["state"] == "live"
                                    and t(e["end"]) > t(d["end"]) for e in DEPLOYS):
        d["state"] = "replaced"


def of(comp, env):
    return sorted((d for d in DEPLOYS if d["comp"] == comp and d["env"] == env), key=lambda d: d["created"])


def tagged(ref, comp, env):
    rows = [d for d in of(comp, env) if d["ref"] == ref]
    return rows[-1] if rows else None


def gate(d):
    return (t(d["run"]) - t(d["wait"])).total_seconds() if d["run"] else 0


def going(d):
    return (t(d["end"]) - t(d["run"])).total_seconds() if d["run"] and d["end"] else 0


TAGS = {g["name"]: g for g in DATA["tags"]}
LATEST = "v0.18.0"
PRS = DATA["prs"][LATEST]


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True, cwd=HERE).stdout.strip()


# --- drawing ------------------------------------------------------------------------------------
class Board:
    def __init__(self, w, h, title, sub):
        self.w, self.h = w, h
        self.parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">',
                      DEFS, f'<rect width="{w}" height="{h}" fill="#E7EAEE"/>']
        self.text(24, 34, title, 15, INK, weight=600)
        for i, ln in enumerate(sub.split("\n")):
            self.text(24, 54 + i * 16, ln, 12, SEC)

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size, color=INK, weight=None, anchor=None, italic=False, strike=False):
        a = []
        if weight: a.append(f'font-weight="{weight}"')
        if anchor: a.append(f'text-anchor="{anchor}"')
        if italic: a.append('font-style="italic"')
        if strike: a.append('text-decoration="line-through"')
        a.append('font-variant-numeric="tabular-nums"')
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{color}" {" ".join(a)}>{esc(s)}</text>')

    def rect(self, x, y, w, h, fill=RAISED, stroke=None, rx=0, sw=1, dash=None):
        a = f'rx="{rx}" fill="{fill}"'
        if stroke: a += f' stroke="{stroke}" stroke-width="{sw}"'
        if dash: a += f' stroke-dasharray="{dash}"'
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{max(w, 0):.1f}" height="{max(h, 0):.1f}" {a}/>')

    def line(self, x1, y1, x2, y2, color=RULE, sw=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="M{x1:.1f} {y1:.1f}L{x2:.1f} {y2:.1f}" stroke="{color}" stroke-width="{sw}"{d}/>')

    def circle(self, cx, cy, r, fill):
        self.add(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r}" fill="{fill}"/>')

    def note(self, n, x, y):
        self.circle(x, y, 9, NOTE)
        self.text(x, y + 4, str(n), 11, "#FFF", weight=700, anchor="middle")

    def chip(self, x, y, words, kind, size=11):
        fg, bg = CHIP.get(kind) or TIER.get(kind) or (SEC, FILL)
        w = len(words) * size * 0.6 + 14
        self.rect(x, y - size - 3, w, size + 8, bg, rx=(size + 8) / 2)
        self.text(x + w / 2, y, words, size, fg, weight=600, anchor="middle")
        return x + w + 6

    def button(self, x, y, words, primary=False):
        w = len(words) * 7 + 22
        self.rect(x, y, w, 24, ACCENT if primary else RAISED, stroke=None if primary else "#C7CCD3", rx=6)
        self.text(x + w / 2, y + 16, words, 12, "#FFF" if primary else INK, weight=600, anchor="middle")
        return x + w + 8

    def window(self, x, y, w, h, place):
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{GROUND}"/></g>')
        for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
            self.circle(x + 20 + i * 20, y + 20, 6, c)
        self.text(x + 90, y + 25, place, 13, SEC)
        self.line(x, y + 40, x + w, y + 40)
        return y + 40

    def phone(self, x, y, w, h):
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="34" fill="#111"/></g>')
        self.rect(x + 8, y + 8, w - 16, h - 16, GROUND, rx=28)
        self.rect(x + w / 2 - 50, y + 16, 100, 26, "#111", rx=13)
        self.text(x + 30, y + 36, "9:41", 13, INK, weight=600)
        return x + 8, y + 52

    def web_frame(self, x, y, w, h, section, pages=None, on=None):
        self.add(f'<g filter="url(#shadow)"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{GROUND}"/></g>')
        self.rect(x, y, w, 44, RAISED, rx=8)
        self.line(x, y + 44, x + w, y + 44)
        sx = x + 24
        for s in ["Overview", "Agents", "Work", "Docs", "Messages", "Machines", "Workflows", "Reports", "Requests", "People", "Settings"]:
            self.text(sx, y + 28, s, 13, INK if s == section else SEC, weight=600 if s == section else None)
            if s == section:
                self.rect(sx - 2, y + 41, len(s) * 7.2 + 4, 2, ACCENT)
            sx += len(s) * 7.2 + 24
        if not pages:
            return x + 24
        lx, ly = x + 24, y + 70
        for head, rows in pages:
            self.text(lx, ly + 12, head, 11, SEC, weight=600)
            ly += 22
            for p in rows:
                if p.strip() == on:
                    self.rect(lx - 8, ly - 2, 176, 26, FILL, rx=6)
                self.text(lx + (12 if p.startswith("  ") else 0), ly + 14, p.strip(), 13, INK, weight=600 if p.strip() == on else None)
                ly += 24
            ly += 8
        self.line(x + 210, y + 44, x + 210, y + h)
        return x + 240

    def write(self, name):
        self.add("</svg>")
        (HERE / name).write_text("\n".join(self.parts))
        print(name)


def target_row(b, x, y, w, d, words, sub, note=None, narrow=False):
    """One target on the Deployed list: the environment, its tier, what went out, the state, when."""
    b.text(x, y, d["env"] if not narrow else d["env"], 13, INK, weight=600)
    cx = x + len(d["env"]) * 7.4 + 10
    if d["tier"] == "production":
        cx = b.chip(cx, y, "production", "production", 10)
    if not narrow:
        b.text(cx + 2, y, d["comp"], 12, SEC)
    kind = d["state"]
    label = {"live": "Live", "waiting": "Waiting", "running": "Going out", "failed": "Failed",
             "cancelled": "Cancelled", "replaced": "Replaced", "rollback": "Rollback"}[kind]
    cw = len(label) * 6.6 + 14
    b.chip(x + w - cw, y, label, kind)
    b.text(x, y + 18, words, 12, SEC)
    if sub:
        b.text(x, y + 34, sub, 11, TER)
    if note:
        b.note(note, x + w + 16, y - 4)


# --- board 1: a release's page -------------------------------------------------------------------
def release():
    b = Board(1240, 760, f"1 · A release's Work page: where {LATEST} is live, from this repo's real deployments",
              "The Mac window; the web page is the same panel in its column (Work.tsx, WorkRelease.tsx). The notes, the PR list and the panel's other rows are as today (#4421).\n"
              "Real: the three targets of a tag, their states, the 28 min that the App Store deploy waited for approval, the times. Scratch: none.")
    x, y, w, h = 24, 96, 1192, 640
    top = b.window(x, y, w, h, f"Work ▸ Releases ▸ {LATEST}")
    g = TAGS[LATEST]
    b.text(x + 28, top + 38, LATEST, 22, INK, weight=700)
    b.chip(x + 28 + 90, top + 34, "Latest", "live")
    b.text(x + 28, top + 60, f"released {when(g['at'])} · {len(PRS)} pull requests since v0.17.0", 12, SEC)
    b.rect(x + 28, top + 84, 700, 380, RAISED, stroke=RULE, rx=8)
    b.text(x + 48, top + 114, "The notes and the pull requests, as today.", 13, TER, italic=True)
    # The panel.
    px, pw = x + 760, 404
    py = top + 84
    for label, value in [("Tag", f"{LATEST} · {g['sha']}"), ("Compared with", "v0.17.0"), ("Pipeline", "CI run · Build trends ↗")]:
        b.text(px, py + 14, label, 11, SEC, weight=600)
        b.text(px + 110, py + 14, value, 12, ACCENT if label == "Pipeline" else INK)
        py += 28
    b.line(px, py, px + pw, py)
    py += 26
    b.text(px, py, "Deployed", 11, SEC, weight=600)
    b.note(1, px + 70, py - 4)
    b.text(px + pw, py, "3 targets", 11, TER, anchor="end")
    py += 28
    rows = []
    tf, store, mac = tagged(LATEST, "Remote", "testflight"), tagged(LATEST, "Remote", "app-store"), tagged(LATEST, "Mac app", "github-releases")
    rows.append((store, f"Remote {LATEST[1:]} · since {when(store['end'])}",
                 f"waited {dur(gate(store))} for approval · went out in {dur(going(store))}", 2))
    rows.append((mac, f"Agents.dmg · since {when(mac['end'])}", f"went out in {dur(going(mac))}", None))
    rows.append((tf, f"Remote build · since {when(tf['end'])}", f"went out in {dur(going(tf))}", None))
    for d, words, sub, n in rows:
        target_row(b, px, py, pw, d, words, sub, n)
        py += 58
    pages = of("Docs", "github-pages")
    b.text(px, py - 4, f"Not with tags: github-pages (Docs) goes out from main, {len(pages)} times in 7 days ›", 11, SEC)
    b.note(3, px + pw + 16, py - 8)
    py += 18
    b.line(px, py - 8, px + pw, py - 8)
    b.text(px, py + 12, "Lineage", 11, SEC, weight=600)
    b.text(px + 110, py + 12, "as today", 12, TER, italic=True)
    # The same release, one version older.
    oy = y + h - 96
    b.text(x + 28, oy, "On v0.17.0's page, the same list says what replaced it:", 12, SEC, weight=600)
    old = tagged("v0.17.0", "Remote", "app-store")
    target_row(b, x + 28, oy + 30, 520, dict(old, state="replaced"), f"Remote 0.17.0 · live {when(old['end'])} to {when(store['end'])}",
               f"replaced by {LATEST}", 4)
    b.write("board-1-release.svg")


# --- board 2: a PR's page, Mac and iPhone --------------------------------------------------------
def pr():
    b = Board(1240, 800, "2 · A pull request's Work page: where its change is live, and how long it took to get there",
              "Left: the Mac window (the web page is the same). Right: the Remote on an iPhone, the narrow page (Core, #3256).\n"
              f"Real: PR and its times, from {LATEST}'s squash commits and the deployments. Scratch: the page's other rows.")
    # Pick a PR in v0.18.0 merged well before the tag.
    p = sorted(PRS, key=lambda r: r["merged"])[len(PRS) // 2]
    tf, store, mac = tagged(LATEST, "Remote", "testflight"), tagged(LATEST, "Remote", "app-store"), tagged(LATEST, "Mac app", "github-releases")
    merged = t(p["merged"])
    x, y, w, h = 24, 96, 760, 680
    top = b.window(x, y, w, h, f"Work ▸ Pull requests ▸ #{p['pr']}")
    title = re.sub(r"\s*\(#\d+\)$", "", p["title"])
    lines = wrap(title, 62)
    for i, ln in enumerate(lines):
        b.text(x + 28, top + 36 + i * 22, ln, 17, INK, weight=700)
    ty = top + 36 + len(lines) * 22
    b.chip(x + 28, ty + 6, "Merged", "cancelled")
    b.text(x + 100, ty + 6, f"agentloops-dev/Agents · merged {when(p['merged'])}", 12, SEC)
    py = ty + 40
    b.line(x + 28, py, x + w - 28, py)
    py += 26
    b.text(x + 28, py, "Pipeline", 11, SEC, weight=600)
    b.text(x + 120, py, f"CI run  ·  Release {LATEST}", 12, ACCENT)
    py += 30
    b.text(x + 28, py, "Live in", 11, SEC, weight=600)
    b.note(5, x + 84, py - 4)
    py += 26
    rows = [(store, f"Remote {LATEST[1:]} · {dur((t(store['end']) - merged).total_seconds())} after merge",
             f"since {when(store['end'])}, with {LATEST}", 6),
            (mac, f"Agents.dmg · {dur((t(mac['end']) - merged).total_seconds())} after merge", f"since {when(mac['end'])}, with {LATEST}", None),
            (tf, f"Remote build · {dur((t(tf['end']) - merged).total_seconds())} after merge", f"since {when(tf['end'])}, with {LATEST}", None)]
    for d, words, sub, n in rows:
        target_row(b, x + 28, py, w - 84, d, words, sub, n)
        py += 58
    py += 10
    b.text(x + 28, py, "A PR that is merged and in no deploy yet says, in place of the list:", 12, SEC, weight=600)
    py += 24
    b.rect(x + 28, py - 16, w - 84, 52, RAISED, stroke=RULE, rx=8, dash="4 3")
    b.text(x + 44, py + 4, "Not deployed yet. Goes out with the next release.", 13, INK)
    b.text(x + 44, py + 22, "Merged after v0.18.0 was tagged.", 12, SEC)
    b.note(7, x + w - 40, py + 6)
    py += 64
    # A docs PR, which goes out from main.
    pages = of("Docs", "github-pages")
    d = pages[-1]
    sha_time = git("show", "-s", "--format=%cI", d["sha"])
    subject = git("show", "-s", "--format=%s", d["sha"])
    b.text(x + 28, py, f"A docs change goes out from main, with no release (real: {d['sha']}):", 12, SEC, weight=600)
    py += 26
    target_row(b, x + 28, py, w - 84, dict(d, state="live"),
               f"{d['sha']} · {dur((t(d['end']) - t(sha_time)).total_seconds())} after merge", (wrap(subject, 80)[0] + " …") if len(subject) > 80 else subject, None)
    # The iPhone.
    px0, py0 = b.phone(840, 96, 376, 680)
    pw = 360 - 32
    lx = px0 + 16
    b.text(lx, py0 + 24, "‹ Pull requests", 14, ACCENT)
    b.text(px0 + 360 - 16, py0 + 24, f"#{p['pr']}", 14, INK, weight=600, anchor="end")
    for i, ln in enumerate(wrap(title, 36)[:3]):
        b.text(lx, py0 + 60 + i * 20, ln, 16, INK, weight=700)
    qy = py0 + 140
    b.chip(lx, qy, "Merged", "cancelled")
    b.text(lx + 70, qy, f"merged {when(p['merged'])}", 12, SEC)
    qy += 30
    b.line(lx, qy, lx + pw, qy)
    qy += 26
    b.text(lx, qy, "Live in", 11, SEC, weight=600)
    b.note(8, lx + 56, qy - 4)
    qy += 26
    for d, words, sub, n in rows:
        target_row(b, lx, qy, pw, d, words.replace(" · ", "\n").split("\n")[1], f"{d['comp']} · {when(d['end'])}", None, narrow=True)
        qy += 58
    b.text(lx, qy + 6, "The body and comments, as today.", 12, TER, italic=True)
    b.write("board-2-pr.svg")


# --- board 3: every state, and the general cases -------------------------------------------------
def states():
    b = Board(1240, 860, "3 · Every state in the model, as one row each on the Deployed and Live in lists",
              "Real rows are from this repo's deployments; the rows marked scratch show the general model's cases that this repo does not have\n"
              "(spec, \"The mapping\": a canary share from Cloud Run or Argo Rollouts, a region label, a rollback, a cancelled deploy).")
    x, y, w = 24, 100, 1192
    b.rect(x, y, w, 740, RAISED, stroke=RULE, rx=10)
    rx, rw = x + 28, 540
    ry = y + 40
    store = tagged(LATEST, "Remote", "app-store")
    failed = next(d for d in reversed(of("Remote", "testflight")) if d["state"] == "failed" and d["ref"].startswith("v") and d["run"])
    rows = [
        ("waiting", dict(store, state="waiting"), f"Remote {LATEST[1:]} · waiting for approval for {dur(gate(store))}",
         "Needs you: Approve or Reject, on GitHub's gate (#3587)", 9, True),
        ("running", dict(store, state="running"), f"Remote {LATEST[1:]} · going out for 12 min", "the submit job, on GitHub", None, False),
        ("live", dict(store, state="live"), f"Remote {LATEST[1:]} · since {when(store['end'])}", f"waited {dur(gate(store))} · went out in {dur(going(store))}", None, False),
        ("failed", failed, f"Remote build · {failed['ref']} · failed after {dur(going(failed))}", "the testflight job's log ↗", 10, False),
        ("cancelled", dict(store, env="production", comp="web", tier="production", state="cancelled"),
         "web 2.3.0 · cancelled after 40 s · scratch", "a newer push cancelled the run", None, False),
        ("replaced", dict(tagged("v0.17.0", "Remote", "app-store"), state="replaced"), "Remote 0.17.0 · replaced by v0.18.0",
         f"live {when(tagged('v0.17.0', 'Remote', 'app-store')['end'])} to {when(store['end'])}", None, False),
        ("rollback", dict(store, env="production", comp="web", tier="production", state="rollback"),
         "web 2.2.0 · since 14:05, after 2.3.0 · scratch", "an older version put back: change failure for DORA", 11, False),
    ]
    for kind, d, words, sub, n, approve in rows:
        target_row(b, rx, ry, rw, d, words, sub, n)
        if approve:
            bx = b.button(rx + rw + 40, ry - 14, "Approve", True)
            b.button(bx, ry - 14, "Reject")
        ry += 62
    # The general cases.
    gx = x + 840
    gy = y + 40
    b.text(gx, gy, "General cases · scratch", 11, SEC, weight=600)
    b.note(12, gx + 160, gy - 4)
    gy += 32
    b.text(gx, gy, "production", 13, INK, weight=600)
    b.chip(gx + 84, gy, "production", "production", 10)
    b.text(gx + 160, gy, "web", 12, SEC)
    b.chip(gx + 300, gy, "Live", "live")
    gy += 24
    for ver, share, colr in [("2.3.0", 90, ACCENT), ("2.4.0", 10, NOTE)]:
        b.text(gx, gy + 12, ver, 12, INK)
        b.rect(gx + 50, gy, 220, 16, FILL, rx=4)
        b.rect(gx + 50, gy, 220 * share / 100, 16, colr, rx=4)
        b.text(gx + 280, gy + 12, f"{share} %", 12, SEC)
        gy += 24
    b.text(gx, gy + 8, "Two live versions, each with its share: a canary.", 11, TER)
    gy += 50
    b.text(gx, gy, "One component in an environment, by region (labels):", 12, SEC, weight=600)
    b.note(13, gx + 340, gy - 4)
    gy += 26
    for region, ver, state in [("us-east1", "2.3.0", "live"), ("europe-west1", "2.3.0", "live"), ("asia-east1", "2.2.0", "running")]:
        b.text(gx, gy, f"production · {region}", 12, INK)
        b.text(gx + 190, gy, ver, 12, SEC)
        b.chip(gx + 240, gy, {"live": "Live", "running": "Going out"}[state], state)
        gy += 24
    gy += 30
    b.text(gx, gy, "What goes next (a path, or the system's own):", 12, SEC, weight=600)
    b.note(14, gx + 320, gy - 4)
    gy += 26
    b.text(gx, gy, "app-store", 13, INK, weight=600)
    b.text(gx + 84, gy, f"live {LATEST[1:]}", 12, SEC)
    gy += 20
    b.text(gx, gy, "next: 0.19.0, when it is live in testflight", 12, ACCENT)
    gy += 22
    b.text(gx, gy, "a Version with many artifacts (Kargo Freight):", 11, TER)
    gy += 18
    b.text(gx, gy, "web 2.4.0 = image sha256:3f1e…", 11, TER)
    b.text(gx, gy + 16, "+ chart 1.8.2 + config 9ab21c4", 11, TER)
    b.write("board-3-states.svg")


# --- board 4: the Deploys overview (an option) ---------------------------------------------------
def overview():
    b = Board(1240, 640, "4 · Option: a Deploys page, every component in every environment (Work ▸ Deploys)",
              "A new screen, so it is Alex's to choose (spec, 'Questions for Alex', 1). Each cell is a target: its live version, since when, and what goes next.\n"
              "Real: the four targets and their versions now. Shown on the web page; the Mac window would be the same, a row in the Work group.")
    fx = b.web_frame(24, 96, 1192, 520, "Work",
                     [("Work", ["Issues", "Pull requests", "Features", "Releases", "Deploys"])], on="Deploys")
    y = 96 + 80
    b.text(fx, y, "Deploys", 20, INK, weight=700)
    b.text(fx, y + 22, f"Last update {int((FETCHED - max(t(d['end']) for d in DEPLOYS if d['end'])).total_seconds() // 60)} min ago",
           12, SEC)
    b.note(15, fx + 190, y + 18)
    envs = [("testflight", "testing"), ("app-store", "production"), ("github-releases", "production"), ("github-pages", "production")]
    cx0, cw, rh = fx + 140, 200, 86
    ty = y + 60
    for i, (e, tier) in enumerate(envs):
        b.text(cx0 + i * cw, ty, e, 12, INK, weight=600)
        if tier == "production":
            b.chip(cx0 + i * cw, ty + 18, "production", "production", 10)
    b.note(16, cx0 + len(envs) * cw - 20, ty - 4)
    ry = ty + 40
    for comp in ["Remote", "Mac app", "Docs"]:
        b.line(fx, ry - 6, fx + 940, ry - 6)
        b.text(fx, ry + 24, comp, 13, INK, weight=600)
        for i, (e, _) in enumerate(envs):
            rows = [d for d in of(comp, e) if d["state"] == "live"]
            cx = cx0 + i * cw
            if not rows:
                b.text(cx, ry + 24, "–", 13, TER)
                continue
            d = rows[-1]
            b.rect(cx - 8, ry + 2, cw - 16, rh - 22, RAISED, stroke=RULE, rx=8)
            b.text(cx + 4, ry + 24, d["ref"] if d["ref"].startswith("v") else d["sha"], 13, INK, weight=600)
            b.chip(cx + cw - 70, ry + 22, "Live", "live")
            b.text(cx + 4, ry + 42, f"since {when(d['end'])}", 11, SEC)
            if e == "app-store":
                b.text(cx + 4, ry + 58, "next: none waiting", 11, TER)
        ry += rh
    b.text(fx, ry + 20, "A click on a cell opens the deploy's job; on a version, its release page (board 1).", 12, SEC)
    b.write("board-4-overview.svg")


# --- board 5: the DORA figures -------------------------------------------------------------------
def dora_of(comp, env, days):
    rows = [d for d in of(comp, env) if FETCHED - t(d["created"]) <= datetime.timedelta(days=days)]
    done = [d for d in rows if d["state"] in ("live", "replaced", "failed")]
    good = [d for d in done if d["state"] != "failed"]
    fails = [d for d in done if d["state"] == "failed"]
    restore = []
    for f in fails:
        nxt = next((g for g in good if t(g["end"]) > t(f["end"])), None)
        if nxt:
            restore.append((t(nxt["end"]) - t(f["end"])).total_seconds())
    lead = []
    for g in good:
        for p in DATA["prs"].get(g["ref"], []):
            lead.append((t(g["end"]) - t(p["merged"])).total_seconds())
    if env == "github-pages":
        for g in good:
            try:
                lead.append((t(g["end"]) - t(git("show", "-s", "--format=%cI", g["sha"]))).total_seconds())
            except subprocess.CalledProcessError:
                pass  # a commit this checkout has not fetched
    return {"n": len(good), "per_week": len(good) / days * 7, "fails": len(fails), "done": len(done),
            "lead": statistics.median(lead) if lead else None, "restore": statistics.median(restore) if restore else None}


def dora():
    b = Board(1240, 740, "5 · Reports ▸ Planning ▸ Delivery: the four DORA figures for each production target (web only, #3224)",
              "Real: this repo's deployments. The Mac app and the App Store over 30 days, the docs over 7 (the API's last 100 github-pages deploys reach that far).\n"
              "Lead time: a PR's merge to the first deploy that brings it. Change failure rate: failed deploys and rollbacks, of all deploys. Time to restore: a failure to the next deploy that went out.")
    fx = b.web_frame(24, 112, 1192, 604, "Reports",
                     [("Reports", ["Spend", "Outcomes", "Time", "Runtimes", "Planning", "  Builds", "  Delivery"])], on="Delivery")
    y = 112 + 78
    b.text(fx, y, "Delivery", 20, INK, weight=700)
    b.text(fx, y + 22, "Repository agentloops-dev/Agents · The last 30 days · Tier: production", 12, SEC)
    b.note(17, fx + 470, y + 18)
    b.text(fx, y + 40, "Last update 4 min ago", 11, TER)
    ry = y + 74
    for comp, env, days in [("Mac app", "github-releases", 30), ("Remote", "app-store", 30), ("Docs", "github-pages", 7)]:
        m = dora_of(comp, env, days)
        b.text(fx, ry, f"{comp} @ {env}", 14, INK, weight=600)
        b.text(fx + 260, ry, f"{m['n']} deploys went out, {m['fails']} failed, in {days} days", 12, SEC)
        tx = fx
        few = m["done"] < 5
        tiles = [("Deploy frequency", f"{m['per_week']:.1f} a week" if m["per_week"] < 14 else f"{m['per_week'] / 7:.0f} a day"),
                 ("Lead time for changes", dur(m["lead"]) if m["lead"] else "–"),
                 ("Change failure rate", (lambda r: f"{r:.1f} %" if 0 < r < 1 else f"{r:.0f} %")(100 * m['fails'] / m['done']) if m["done"] else "–"),
                 ("Time to restore", dur(m["restore"]) if m["restore"] else "no failure")]
        for label, fig in tiles:
            b.rect(tx, ry + 14, 216, 84, RAISED, stroke=RULE, rx=8)
            b.text(tx + 14, ry + 36, label, 11, SEC, weight=600)
            b.text(tx + 14, ry + 70, fig, 22, TER if few else INK, weight=600)
            tx += 230
        if few:
            b.text(fx, ry + 116, f"Too few deploys for a figure that means much ({m['done']}); shown dimmed.", 11, NOTE)
            b.note(18, fx + 380, ry + 112)
        ry += 156 if few else 136
    b.write("board-5-dora.svg")


# --- board 6: what a machine runs -----------------------------------------------------------------
def machine():
    m = DATA["main"]
    b = Board(1240, 760, "6 · A machine's page: this machine runs this version, with these changes, since time X",
              "The Mac window; the Remote and the web page draw the same section (the machine page is Core, #3626).\n"
              f"Real: the versions ({m['last'][1:]} and origin/main's build), the {m['prs']} PRs between them and the newest titles. Scratch: the machines' names and the times they changed.")
    x, y, w, h = 24, 96, 1192, 640
    top = b.window(x, y, w, h, "Machines ▸ mac-mini")
    b.text(x + 28, top + 38, "mac-mini", 22, INK, weight=700)
    b.chip(x + 140, top + 34, "Online", "live")
    b.text(x + 28, top + 60, "CPU 0.4 per core · memory 61 % · disk 48 % free, as today", 12, TER, italic=True)
    py = top + 100
    b.line(x + 28, py - 18, x + w - 28, py - 18)
    b.text(x + 28, py, "Agents", 11, SEC, weight=600)
    b.note(19, x + 82, py - 4)
    since = local(m["at"]) + datetime.timedelta(minutes=9)
    b.text(x + 28, py + 30, m["version"].split("+")[0], 20, INK, weight=600)
    b.text(x + 28 + len(m["version"].split("+")[0]) * 11.5 + 8, py + 30, "+g" + m["sha"], 13, SEC)
    b.text(x + 28, py + 52, f"since {since:%-d %b, %H:%M} · {m['prs']} changes since {m['last'][1:]}, the version before ›", 13, SEC)
    b.note(20, x + 640, py + 48)
    b.text(x + 28, py + 72, f"built from main at {m['sha']}, {local(m['at']):%-d %b, %H:%M}; installed with ship-app", 11, TER)
    # The changes.
    cy = py + 108
    b.rect(x + 28, cy, 640, 300, RAISED, stroke=RULE, rx=8)
    b.text(x + 44, cy + 26, f"{m['prs']} changes since {m['last'][1:]} · newest first", 12, SEC, weight=600)
    b.note(21, x + 330, cy + 22)
    ry = cy + 54
    for p in m["newest"]:
        b.text(x + 44, ry, f"#{p['pr']}", 12, ACCENT)
        title = wrap(p["title"], 70)
        b.text(x + 100, ry, title[0] + (" …" if len(title) > 1 else ""), 12, INK)
        b.text(x + 652, ry, f"{local(p['merged']):%-d %b}", 11, TER, anchor="end")
        ry += 34
    b.text(x + 44, ry + 4, f"Show all {m['prs']} ›", 12, ACCENT)
    # The other machines, compared.
    ox = x + 712
    b.text(ox, py, "Other machines", 11, SEC, weight=600)
    b.note(22, ox + 116, py - 4)
    oy = py + 30
    rows = [("mac-mini (this one)", m["version"].split("+")[0], "since " + f"{since:%-d %b, %H:%M}", None),
            ("linux-server", m["last"][1:], "since 8 Nov, 11:02", f"{m['prs']} changes behind this one"),
            ("cloud-1", m["last"][1:], "since 8 Nov, 11:40", f"{m['prs']} changes behind this one")]
    for name, ver, when_, behind in rows:
        b.text(ox, oy, name, 13, INK, weight=600)
        b.text(ox, oy + 18, f"{ver} · {when_}", 12, SEC)
        if behind:
            b.text(ox, oy + 34, behind + " ›", 11, NOTE)
        oy += 56
    b.text(ox, oy + 10, "History", 11, SEC, weight=600)
    b.note(23, ox + 60, oy + 6)
    hy = oy + 36
    for ver, when_ in [(m["version"].split("+")[0], f"{since:%-d %b, %H:%M}"), (m["last"][1:], "8 Nov, 10:58"), ("0.17.0", "7 Nov, 12:31")]:
        b.text(ox, hy, ver, 12, INK)
        b.text(ox + 440, hy, when_, 12, SEC, anchor="end")
        hy += 22
    b.write("board-6-machine.svg")


release()
pr()
states()
overview()
dora()
machine()
