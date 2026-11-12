#!/usr/bin/env python3
"""Write contact-sheet.html: Paper v2's design system on one page (#4926).

    python3 specs/4926-paper-v2/contact-sheet.py <lucide icons dir>

The icons dir holds Lucide 1.72.0's SVGs (ISC), as `lucide-static/icons/<name>.svg`.
The page loads its fonts from jsDelivr (Fontsource), for the sheet only. Open it with
?mode=dark for the dark sheet. It is a picture of the system, not product code.
"""
import html
import pathlib
import re
import sys

ICONS = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(__file__).with_name("contact-sheet.html")


def icon(name, size=18, cls=""):
    svg = (ICONS / f"{name}.svg").read_text()
    svg = re.sub(r"<!--.*?-->", "", svg, flags=re.S).strip()
    svg = svg.replace('width="24"', f'width="{size}"').replace('height="24"', f'height="{size}"')
    svg = svg.replace('stroke-width="2"', 'stroke-width="1.5"')
    svg = re.sub(r'class="[^"]*"', f'class="i {cls}" aria-hidden="true"', svg, count=1)
    return re.sub(r"\s+", " ", svg)


# Colour: token, light, dark, what it is for, what it is drawn on.
SURFACES = [
    ("ground", "#fcfbf9", "#1a1a19", "The page every column sits on. Paper, a breath off white."),
    ("sidebar", "#f5f4f0", "#141413", "The folders column: one step deeper than the ground."),
    ("raised", "#ffffff", "#212120", "What floats: cards, the prompt bar, menus, sheets. Set apart by a line, not a shadow."),
    ("well", "#f3f2ee", "#262625", "What is set into the page: code, your own message, a field."),
    ("wash", "#eeece7", "#2e2e2c", "A row under the pointer; a pressed quiet button."),
    ("selection", "#e6e3dc", "#363633", "The picked row, with a cobalt bar at its edge. Every text colour still reads on it."),
]
INKS = [
    ("ink", "#1a1918", "#f4f2ed", "Text and icons: a deep charcoal, 17:1."),
    ("secondary", "#4a4741", "#bdb9b0", "A row's second line, a speaker's name, a section heading."),
    ("tertiary", "#625e57", "#a29e95", "Timestamps, counts, placeholders."),
]
LINES = [
    ("rule", "#d6d2c9", "#3d3d3a", "The line that sets things apart, in place of a shadow (1.5:1): rows, cards, columns."),
    ("edge", "#7d786e", "#85817a", "The edge of a field, a checkbox, a toggle's track: 3:1, so a control can be found."),
]
SIGNALS = [
    ("accent", "#1a52c0", "#86b4ff", "Cobalt, from the icon: links, focus, the chosen control, the text on its light gradient (5.6:1 or more)."),
    ("attention", "#a3400e", "#f3a672", "Needs you. The only tint drawn in a list."),
    ("failure", "#b0222a", "#f4878d", "Failed, denied, deleted."),
    ("vouched", "#25684f", "#92ccad", "Done and approved: an ending the app can vouch for."),
    ("issue", "#0c6278", "#73cbe0", "A label naming an issue, #812."),
    ("pull", "#6c3cae", "#bea3f2", "A label naming a pull request, P#44."),
]


def lum(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a, b):
    la, lb = sorted([lum(a), lum(b)], reverse=True)
    return (la + 0.05) / (lb + 0.05)


def swatches(rows, on=True):
    out = []
    for name, light, dark, use in rows:
        note = ""
        if on:
            note = f'<span class="ratio">{ratio(light, "#fcfbf9"):.1f}:1 · {ratio(dark, "#1a1a19"):.1f}:1 on ground</span>'
        out.append(f'''<div class="sw">
  <div class="chips"><span style="background:{light}"></span><span style="background:{dark}"></span></div>
  <div><div class="sw-name">{name}</div><div class="sw-hex">{light} · {dark}</div>
  <div class="sw-use">{html.escape(use)}</div>{note}</div></div>''')
    return "\n".join(out)


ICON_GROUPS = [
    ("States: a session's, in the list and the chat", [
        ("circle-help", "Needs you: a question or an approval waits", "attention"),
        ("loader-circle", "Working", ""),
        ("circle-pause", "Waiting: on a check, a lease, a time", ""),
        ("circle-check", "Done", "vouched"),
        ("circle-x", "Failed", "failure"),
        ("archive", "Archived", "muted"),
    ]),
    ("Things", [
        ("message-circle", "Session", ""), ("folder", "Folder", ""), ("workflow", "Workflow", ""),
        ("circle-dot", "Issue", "issue"), ("git-pull-request", "Pull request", "pull"),
        ("git-branch", "Branch, worktree", ""), ("laptop", "Machine", ""), ("user", "Person", ""),
        ("plug", "Connector", ""), ("layout-grid", "Project", ""), ("file-text", "File, doc", ""),
        ("square-terminal", "Terminal, command", ""),
    ]),
    ("Actions", [
        ("square-pen", "New session", ""), ("arrow-up", "Send", ""), ("paperclip", "Attach", ""),
        ("mic", "Voice", ""), ("search", "Search", ""), ("ellipsis", "More", ""),
        ("pin", "Pin", ""), ("external-link", "Open outside the app", ""), ("rotate-cw", "Retry", ""),
        ("circle-stop", "Stop", ""), ("check", "Approve", ""), ("x", "Close, deny", ""),
        ("chevron-right", "Open, go in", ""), ("chevron-down", "Fold, menu", ""),
    ]),
    ("Notices", [
        ("info", "For your information", ""), ("triangle-alert", "Warning: it may go wrong", "attention"),
        ("circle-alert", "Error: it went wrong", "failure"), ("shield-check", "Trust: approve a device, a tool", ""),
        ("key", "A secret", ""), ("lock", "Locked, signed in", ""), ("coins", "Cost", ""),
        ("clock", "Time, a schedule", ""), ("sparkles", "Suggested by an agent", ""),
    ]),
]


def icon_grid():
    out = []
    for title, items in ICON_GROUPS:
        cells = "".join(
            f'<div class="ic"><span class="ic-glyph {tone}">{icon(n, 22)}</span>'
            f'<span class="ic-name">{n}</span><span class="ic-use">{html.escape(use)}</span></div>'
            for n, use, tone in items)
        out.append(f'<h3>{title}</h3><div class="icgrid">{cells}</div>')
    return "\n".join(out)


I = icon
page = f'''<!doctype html>
<!-- Written by contact-sheet.py (#4926). Icons: Lucide 1.72.0, ISC. Not product code. -->
<html lang="en">
<head>
<meta charset="utf-8">
<title>Paper v2: the design system</title>
<style>
@font-face {{ font-family: "Atkinson Hyperlegible Next"; src: url("https://cdn.jsdelivr.net/fontsource/fonts/atkinson-hyperlegible-next:vf@latest/latin-wght-normal.woff2") format("woff2-variations"); font-weight: 200 800; }}
@font-face {{ font-family: "Atkinson Hyperlegible Mono"; src: url("https://cdn.jsdelivr.net/fontsource/fonts/atkinson-hyperlegible-mono:vf@latest/latin-wght-normal.woff2") format("woff2-variations"); font-weight: 200 800; }}
@font-face {{ font-family: "Lexend"; src: url("https://cdn.jsdelivr.net/fontsource/fonts/lexend:vf@latest/latin-wght-normal.woff2") format("woff2-variations"); font-weight: 100 900; }}
@font-face {{ font-family: "Figtree"; src: url("https://cdn.jsdelivr.net/fontsource/fonts/figtree:vf@latest/latin-wght-normal.woff2") format("woff2-variations"); font-weight: 300 900; }}
:root {{
  --ground:#fcfbf9; --sidebar:#f5f4f0; --raised:#ffffff; --well:#f3f2ee; --wash:#eeece7; --selection:#e6e3dc;
  --ink:#1a1918; --secondary:#4a4741; --tertiary:#625e57; --rule:#d6d2c9; --edge:#7d786e;
  --accent:#1a52c0; --attention:#a3400e; --failure:#b0222a; --vouched:#25684f; --issue:#0c6278; --pull:#6c3cae;
  --on-ink:#ffffff;
  --grad-plain: linear-gradient(180deg, #ffffff, #efede8);
  --grad-accent: linear-gradient(180deg, #f3f7ff, #dde8fc);
  --grad-attention: linear-gradient(180deg, #fff6ef, #fbe2cf);
  --grad-vouched: linear-gradient(180deg, #f1faf5, #d6eee0);
  --grad-failure: linear-gradient(180deg, #fff3f3, #fadadb);
  --grad-selection: linear-gradient(90deg, #e3ecfc, #f3f7ff);
  --grad-switch: linear-gradient(180deg, #5b9bff, #2f6ee0);
  --line-accent: #a9c2ee; --line-attention: #ebbf9f; --line-vouched: #a9d3bb; --line-failure: #eeb0b3;
  --shadow-raised: 0 0 #0000;
  --shadow-floating: 0 4px 12px rgb(26 25 24 / 10%);
  --shadow-sheet: 0 12px 32px rgb(26 25 24 / 18%);
  --focus: 0 0 0 2px var(--raised), 0 0 0 4px var(--accent);
  --text: "Atkinson Hyperlegible Next", -apple-system, system-ui, sans-serif;
  --mono: "Atkinson Hyperlegible Mono", ui-monospace, "SF Mono", monospace;
}}
.dark {{
  --ground:#1a1a19; --sidebar:#141413; --raised:#212120; --well:#262625; --wash:#2e2e2c; --selection:#363633;
  --ink:#f4f2ed; --secondary:#bdb9b0; --tertiary:#a29e95; --rule:#3d3d3a; --edge:#85817a;
  --accent:#86b4ff; --attention:#f3a672; --failure:#f4878d; --vouched:#92ccad; --issue:#73cbe0; --pull:#bea3f2;
  --on-ink:#141413;
  --grad-plain: linear-gradient(180deg, #2e2e2c, #262625);
  --grad-accent: linear-gradient(180deg, #22314d, #1b2740);
  --grad-attention: linear-gradient(180deg, #3a2a1f, #2f2219);
  --grad-vouched: linear-gradient(180deg, #1f3a2e, #1a2f26);
  --grad-failure: linear-gradient(180deg, #3d2224, #321c1e);
  --grad-selection: linear-gradient(90deg, #22314d, #212120);
  --grad-switch: linear-gradient(180deg, #86b4ff, #5b9bff);
  --line-accent: #3d5687; --line-attention: #6b4a33; --line-vouched: #36614d; --line-failure: #6b3a3d;
  --shadow-raised: 0 0 #0000;
  --shadow-floating: 0 4px 12px rgb(0 0 0 / 40%);
  --shadow-sheet: 0 12px 32px rgb(0 0 0 / 55%);
}}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: var(--ground); color: var(--ink); font: 15px/1.5 var(--text); letter-spacing: .005em; -webkit-font-smoothing: antialiased; }}
.sheet {{ width: 1360px; margin: 0 auto; padding: 48px 56px 64px; }}
header {{ display: flex; align-items: baseline; justify-content: space-between; border-bottom: 1px solid var(--rule); padding-bottom: 20px; margin-bottom: 8px; }}
h1 {{ font-size: 30px; font-weight: 650; letter-spacing: -.01em; margin: 0; }}
.sub {{ color: var(--secondary); font-size: 15px; max-width: 760px; }}
h2 {{ font-size: 20px; font-weight: 650; margin: 40px 0 4px; }}
h2 + p {{ color: var(--secondary); margin: 0 0 18px; max-width: 900px; }}
h3 {{ font-size: 13px; font-weight: 650; color: var(--secondary); margin: 22px 0 10px; }}
.grid3 {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px 28px; }}
.grid2 {{ display: grid; grid-template-columns: 1fr 1fr; gap: 28px; }}
.typegrid {{ display: grid; grid-template-columns: 1.7fr 1fr; gap: 28px; }}
.sw {{ display: grid; grid-template-columns: 76px 1fr; gap: 12px; align-items: start; }}
.chips {{ display: flex; border-radius: 10px; overflow: hidden; height: 52px; box-shadow: inset 0 0 0 1px var(--rule); }}
.chips span {{ flex: 1; }}
.sw-name {{ font-weight: 650; }}
.sw-hex {{ font: 12px/1.4 var(--mono); color: var(--tertiary); }}
.sw-use {{ font-size: 13px; color: var(--secondary); line-height: 1.45; }}
.ratio {{ font-size: 12px; color: var(--tertiary); }}
.panel {{ background: var(--raised); border-radius: 10px; box-shadow: var(--shadow-raised), 0 0 0 1px var(--rule); padding: 18px 20px; }}
.cap {{ font-size: 12px; color: var(--tertiary); margin-top: 8px; }}
.row {{ display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }}
.stack > * + * {{ margin-top: 12px; }}
.i {{ display: inline-block; vertical-align: -3px; flex: none; }}
/* Type */
.spec {{ display: grid; grid-template-columns: 100px 1fr 250px; gap: 6px 18px; align-items: baseline; padding: 8px 0; border-bottom: 1px solid var(--rule); }}
.spec:last-child {{ border-bottom: 0; }}
.spec .k {{ color: var(--secondary); font-size: 13px; }} .spec .m {{ color: var(--tertiary); font-size: 12px; font-family: var(--mono); }}
.glyphs {{ font-size: 40px; letter-spacing: .04em; line-height: 1.2; }}
.faces {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }}
.face .n {{ font: 600 12px var(--text); color: var(--secondary); margin-bottom: 4px; }}
.face .g {{ font-size: 26px; line-height: 1.25; }}
.face .p {{ font-size: 14px; color: var(--secondary); }}
/* Edges and depth */
.levels {{ display: grid; grid-template-columns: repeat(4, 1fr); gap: 24px; }}
.lvl {{ height: 110px; border-radius: 10px; padding: 14px; font-size: 13px; color: var(--secondary); }}
.lvl b {{ display: block; color: var(--ink); font-size: 14px; }}
.l0 {{ background: var(--ground); box-shadow: inset 0 0 0 1px var(--rule); }}
.l1 {{ background: var(--raised); box-shadow: var(--shadow-raised), 0 0 0 1px var(--rule); }}
.l2 {{ background: var(--raised); box-shadow: var(--shadow-floating), 0 0 0 1px var(--rule); border-radius: 12px; }}
.l3 {{ background: var(--raised); box-shadow: var(--shadow-sheet), 0 0 0 1px var(--rule); border-radius: 16px; }}
.radii {{ display: flex; gap: 22px; }}
.rad {{ width: 84px; height: 56px; background: var(--well); box-shadow: inset 0 0 0 1px var(--rule); display: grid; place-items: center; font-size: 12px; color: var(--secondary); }}
.lines .ln {{ display: grid; grid-template-columns: 110px 1fr; align-items: center; gap: 14px; margin: 10px 0; font-size: 13px; color: var(--secondary); }}
.lines .ln div {{ height: 0; }}
/* Icons */
.icgrid {{ display: grid; grid-template-columns: repeat(7, 1fr); gap: 8px; }}
.ic {{ background: var(--raised); box-shadow: 0 0 0 1px var(--rule); border-radius: 10px; padding: 12px 10px 10px; display: flex; flex-direction: column; gap: 4px; min-height: 104px; }}
.ic-glyph {{ color: var(--ink); }} .ic-glyph.attention {{ color: var(--attention); }} .ic-glyph.failure {{ color: var(--failure); }}
.ic-glyph.vouched {{ color: var(--vouched); }} .ic-glyph.issue {{ color: var(--issue); }} .ic-glyph.pull {{ color: var(--pull); }} .ic-glyph.muted {{ color: var(--tertiary); }}
.ic-name {{ font: 11px var(--mono); color: var(--tertiary); }} .ic-use {{ font-size: 12.5px; line-height: 1.35; color: var(--secondary); }}
/* Components */
.btn {{ font: 500 14px/1 var(--text); border-radius: 7px; padding: 8px 14px; border: 0; display: inline-flex; gap: 6px; align-items: center; color: var(--ink); background: var(--grad-plain); box-shadow: 0 0 0 1px var(--rule), var(--shadow-raised); }}
.btn.prom {{ background: var(--grad-plain); color: var(--ink); font-weight: 650; box-shadow: 0 0 0 1px var(--edge); }}
.btn.accent {{ background: var(--grad-accent); color: var(--accent); font-weight: 650; box-shadow: 0 0 0 1px var(--line-accent); }}
.btn.quiet {{ background: transparent; box-shadow: none; color: var(--secondary); }}
.btn.quiet.hover {{ background: var(--wash); color: var(--ink); }}
.btn.danger {{ color: var(--failure); }}
.btn.focus {{ box-shadow: 0 0 0 1px var(--rule), var(--focus); }}
.btn[disabled] {{ opacity: .45; }}
.icon-btn {{ width: 32px; height: 32px; padding: 0; justify-content: center; }}
.field {{ font: 14px var(--text); color: var(--ink); background: var(--raised); border-radius: 7px; padding: 8px 10px; box-shadow: inset 0 0 0 1px var(--edge); width: 240px; display: flex; gap: 8px; align-items: center; }}
.field.ph {{ color: var(--tertiary); }} .field.focus {{ box-shadow: inset 0 0 0 1px var(--accent), var(--focus); }}
.field.well {{ background: var(--well); box-shadow: none; color: var(--tertiary); }}
.toggle {{ width: 34px; height: 20px; border-radius: 10px; background: var(--wash); box-shadow: inset 0 0 0 1px var(--edge); position: relative; }}
.toggle::after {{ content: ""; position: absolute; top: 3px; left: 3px; width: 14px; height: 14px; border-radius: 50%; background: var(--raised); box-shadow: 0 0 0 1px var(--edge); }}
.toggle.on {{ background: var(--grad-switch); box-shadow: none; }} .toggle.on::after {{ left: 17px; box-shadow: none; }}
.check {{ width: 16px; height: 16px; border-radius: 4px; box-shadow: inset 0 0 0 1px var(--edge); background: var(--raised); display: grid; place-items: center; }}
.check.on {{ background: var(--grad-switch); box-shadow: none; color: #fff; }}
.seg {{ display: inline-flex; background: var(--well); border-radius: 8px; padding: 2px; }}
.seg span {{ font-size: 13px; padding: 5px 12px; border-radius: 6px; color: var(--secondary); }}
.seg span.on {{ background: var(--raised); color: var(--ink); box-shadow: var(--shadow-raised), 0 0 0 1px var(--rule); }}
.chip {{ font: 600 12px/1 var(--text); padding: 4px 7px; border-radius: 6px; background: var(--raised); box-shadow: inset 0 0 0 1px var(--rule); color: var(--secondary); display: inline-flex; gap: 4px; align-items: center; }}
.chip.issue {{ color: var(--issue); }} .chip.pull {{ color: var(--pull); }}
.chip.mono {{ font: 12px/1 var(--mono); }}
.badge {{ font: 600 12px/1 var(--text); padding: 4px 9px 4px 6px; border-radius: 99px; display: inline-flex; gap: 4px; align-items: center; }}
.badge.attention {{ background: var(--grad-attention); color: var(--attention); box-shadow: inset 0 0 0 1px var(--line-attention); }} .badge.failure {{ background: var(--grad-failure); color: var(--failure); box-shadow: inset 0 0 0 1px var(--line-failure); }} .badge.vouched {{ background: var(--grad-vouched); color: var(--vouched); box-shadow: inset 0 0 0 1px var(--line-vouched); }} .badge.working {{ background: var(--raised); color: var(--secondary); box-shadow: inset 0 0 0 1px var(--rule); }}
.side {{ background: var(--sidebar); border-radius: 10px; padding: 10px; box-shadow: inset 0 0 0 1px var(--rule); }}
.sec {{ font-size: 12px; font-weight: 650; color: var(--secondary); padding: 8px 8px 4px; display: flex; justify-content: space-between; }}
.srow {{ display: grid; grid-template-columns: 20px 1fr auto; gap: 2px 8px; padding: 7px 8px; border-radius: 8px; }}
.srow .t {{ font-weight: 600; font-size: 14px; }} .srow .s {{ grid-column: 2; font-size: 13px; color: var(--secondary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
.srow .w {{ font-size: 12px; color: var(--tertiary); }}
.srow.hover {{ background: var(--wash); }} .srow.sel {{ background: var(--grad-selection); box-shadow: inset 3px 0 0 var(--accent); }}
.srow .st {{ color: var(--secondary); }} .srow .st.attention {{ color: var(--attention); }} .srow .st.vouched {{ color: var(--vouched); }} .srow .st.failure {{ color: var(--failure); }}
.srow.unread .t::after {{ content: ""; display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: var(--accent); margin-left: 6px; vertical-align: 2px; }}
.chat {{ background: var(--ground); border-radius: 10px; padding: 16px 18px; box-shadow: inset 0 0 0 1px var(--rule); }}
.me {{ background: var(--well); border-radius: 12px; padding: 9px 13px; margin-left: auto; max-width: 78%; width: fit-content; }}
.who {{ font-size: 12.5px; font-weight: 650; color: var(--secondary); margin-top: 14px; }}
.prose {{ line-height: 1.5; letter-spacing: .01em; word-spacing: .06em; max-width: 68ch; }}
code {{ font: 13px var(--mono); background: var(--well); padding: 1px 5px; border-radius: 5px; }}
pre {{ font: 13px/1.6 var(--mono); background: var(--well); border-radius: 10px; padding: 12px 14px; margin: 10px 0; overflow: hidden; }}
.kw {{ color: #2b4c8c; }} .str {{ color: #4e6420; }} .cm {{ color: #64707a; font-style: italic; }} .fn {{ color: #5b4bb5; }}
.dark .kw {{ color: #8fb0e8; }} .dark .str {{ color: #a9c27a; }} .dark .cm {{ color: #a3adb8; }} .dark .fn {{ color: #b3a6f0; }}
.tool {{ display: flex; gap: 8px; align-items: center; font-size: 13px; color: var(--secondary); padding: 6px 0; }}
.tool code {{ background: none; padding: 0; color: var(--ink); }}
.card {{ background: var(--raised); border-radius: 10px; padding: 14px 16px; box-shadow: var(--shadow-raised), 0 0 0 1px var(--rule); }}
.card .by {{ font-size: 12px; color: var(--tertiary); margin-bottom: 4px; }}
.card .q {{ font-weight: 650; margin-bottom: 10px; }}
.opt {{ display: block; width: 100%; text-align: left; padding: 9px 12px; border-radius: 8px; margin-top: 6px; background: var(--raised); box-shadow: inset 0 0 0 1px var(--edge); font-size: 14px; }}
.opt.pick {{ background: var(--grad-accent); color: var(--accent); box-shadow: inset 0 0 0 1.5px var(--accent); font-weight: 650; }}
.notice {{ display: flex; gap: 10px; align-items: flex-start; border-radius: 10px; padding: 10px 12px; font-size: 14px; background: var(--raised); box-shadow: 0 0 0 1px var(--rule); }}
.notice .bar {{ width: 3px; align-self: stretch; border-radius: 2px; }}
.notice .bar {{ display: none; }} .notice.info {{ background: var(--grad-accent); box-shadow: 0 0 0 1px var(--line-accent); }} .notice.warn {{ background: var(--grad-attention); box-shadow: 0 0 0 1px var(--line-attention); }} .notice.err {{ background: var(--grad-failure); box-shadow: 0 0 0 1px var(--line-failure); }}
.notice.warn .i {{ color: var(--attention); }} .notice.err .i {{ color: var(--failure); }} .notice.info .i {{ color: var(--accent); }}
.prompt {{ background: var(--raised); border-radius: 16px; padding: 12px 14px 10px; box-shadow: var(--shadow-floating), 0 0 0 1px var(--rule); }}
.prompt .ph {{ color: var(--tertiary); min-height: 44px; }}
.prompt .bar2 {{ display: flex; justify-content: space-between; align-items: center; color: var(--secondary); }}
.send {{ width: 30px; height: 30px; border-radius: 50%; background: var(--grad-accent); box-shadow: 0 0 0 1px var(--line-accent); color: var(--accent); display: grid; place-items: center; }}
.menu {{ background: var(--raised); border-radius: 12px; padding: 5px; width: 230px; box-shadow: var(--shadow-floating), 0 0 0 1px var(--rule); font-size: 14px; }}
.menu div {{ padding: 7px 10px; border-radius: 7px; display: flex; gap: 9px; align-items: center; }}
.menu .hl {{ background: var(--wash); }} .menu hr {{ border: 0; border-top: 1px solid var(--rule); margin: 4px 6px; }}
.menu .danger {{ color: var(--failure); }} .menu .kbd {{ margin-left: auto; color: var(--tertiary); font-size: 12px; }}
.tip {{ background: var(--grad-plain); color: var(--ink); box-shadow: 0 0 0 1px var(--rule), var(--shadow-floating); font-size: 12.5px; padding: 5px 9px; border-radius: 6px; width: fit-content; }}
.toast {{ background: var(--raised); border-radius: 12px; padding: 10px 14px; box-shadow: var(--shadow-floating), 0 0 0 1px var(--rule); display: flex; gap: 10px; align-items: center; font-size: 14px; width: fit-content; }}
.toast .i {{ color: var(--vouched); }}
.empty {{ text-align: center; padding: 26px 10px; color: var(--secondary); }}
.empty .i {{ color: var(--accent); }} .empty b {{ display: block; color: var(--ink); font-size: 16px; margin: 8px 0 2px; }}
.progress {{ height: 4px; background: var(--wash); border-radius: 2px; overflow: hidden; width: 240px; }}
.progress span {{ display: block; height: 100%; width: 62%; background: linear-gradient(90deg, #5b9bff, var(--accent)); border-radius: 2px; }}
.sheetdemo {{ background: color-mix(in srgb, #000 12%, var(--ground)); border-radius: 12px; padding: 26px; }}
.dark .sheetdemo {{ background: color-mix(in srgb, #000 40%, var(--ground)); }}
.sheetdemo .l3 {{ height: auto; padding: 18px 20px; color: var(--ink); }}
.label {{ font-size: 12px; color: var(--tertiary); margin: 0 0 6px; }}
</style>
</head>
<body>
<script>if (new URLSearchParams(location.search).get("mode") === "dark") document.documentElement.classList.add("dark");</script>
<div class="sheet">
<header>
  <div><h1>Paper v2</h1><div class="sub">The design system of Agents on the Mac, iPhone, iPad and the web. Clear and crisp: deep charcoal on paper, one face, thin icons. Lines set things apart, not shadows. Fills are light: soft gradients, tinted by what they mean, with the colour in the text.</div></div>
  <div class="sub" style="text-align:right">#4926 · proposal · <span class="mode-name"></span></div>
</header>

<h2>Colour</h2>
<p>Few colours, each with one job, at high contrast. Surfaces are near white; text is deep charcoal (17:1); colour means something (a link, a state, a label) and is never decoration. Each chip shows light, then dark. Every text colour is 4.5:1 or more on every surface, the selection included.</p>
<h3>Surfaces</h3><div class="grid3">{swatches(SURFACES, on=False)}</div>
<h3>Ink</h3><div class="grid3">{swatches(INKS)}</div>
<h3>Lines</h3><div class="grid3">{swatches(LINES)}</div>
<h3>Signals: colour that means something</h3><div class="grid3">{swatches(SIGNALS)}</div>

<h2>Type</h2>
<p>One face for everything you read, and its mono for code: Atkinson Hyperlegible Next and Mono (Braille Institute, OFL). Letters that look alike are drawn to differ, which helps people with low vision and dyslexia. Sizes follow the person's text size on every platform.</p>
<div class="typegrid">
<div class="panel">
  <div class="spec"><span class="k">title</span><span style="font-size:22px;font-weight:650;letter-spacing:-.01em">Fix the login redirect</span><span class="m">22 Mac · 28 iOS · 1.375rem · 650</span></div>
  <div class="spec"><span class="k">reading</span><span class="prose">The redirect drops the next parameter.</span><span class="m">15 Mac · 17 iOS · 1rem · 1.5 leading</span></div>
  <div class="spec"><span class="k">heading</span><span style="font-weight:650">Needs you</span><span class="m">reading at 650</span></div>
  <div class="spec"><span class="k">supporting</span><span style="font-size:13px;color:var(--secondary)">Asks: which callback URL? · web-shop</span><span class="m">13 Mac · 15 iOS · .875rem</span></div>
  <div class="spec"><span class="k">fine</span><span style="font-size:11.5px;color:var(--tertiary)">2 min ago · $0.25</span><span class="m">11 Mac · 13 iOS · .75rem</span></div>
  <div class="spec"><span class="k">code</span><span style="font:13px var(--mono)">return Response.redirect(safe, 302);</span><span class="m">mono · 13 Mac · 15 iOS</span></div>
</div>
<div class="panel">
  <div class="glyphs">Il1 0O bd pq rn m</div>
  <div class="glyphs" style="font-family:var(--mono);font-size:30px">Il1 0O {{}} [] =&gt; !=</div>
  <div class="cap">Letters that are easy to confuse, drawn to differ. Rules for reading: line height 1.5, a little letter and word spacing, at most about 70 characters a line, no italics or capitals for emphasis.</div>
</div>
</div>
<h3>The faces we compared (yours to choose)</h3>
<div class="faces">
  <div class="panel face"><div class="n">Atkinson Hyperlegible Next (proposed)</div><div class="g" style="font-family:'Atkinson Hyperlegible Next'">Il1 0O bd · Agents</div><div class="p" style="font-family:'Atkinson Hyperlegible Next'">The redirect drops the next parameter.</div></div>
  <div class="panel face"><div class="n">Lexend</div><div class="g" style="font-family:Lexend">Il1 0O bd · Agents</div><div class="p" style="font-family:Lexend">The redirect drops the next parameter.</div></div>
  <div class="panel face"><div class="n">Figtree</div><div class="g" style="font-family:Figtree">Il1 0O bd · Agents</div><div class="p" style="font-family:Figtree">The redirect drops the next parameter.</div></div>
  <div class="panel face"><div class="n">System (SF, today)</div><div class="g" style="font-family:-apple-system,system-ui">Il1 0O bd · Agents</div><div class="p" style="font-family:-apple-system,system-ui">The redirect drops the next parameter.</div></div>
</div>

<h2>Edges and depth</h2>
<p>Flat and crisp. A line (1.5:1) sets things apart; nothing on the page casts a shadow. Only what floats over the page (a menu, a toast, a sheet) has one, short and close. A control's edge is 3:1 or more. No dark fills: a button, a badge, a notice or a picked choice is a light gradient tinted by its meaning, with a line in the same hue and the colour in its text. Only a switch that is on is a strong cobalt. Focus is a cobalt ring.</p>
<div class="levels">
  <div class="lvl l0"><b>0 · On the page</b>Rows, the chat. A line, no shadow.</div>
  <div class="lvl l1"><b>1 · Raised</b>Cards, buttons. White and a line; no shadow.</div>
  <div class="lvl l2"><b>2 · Floating</b>Menus, the prompt bar, toasts. A line + 0 4px 12px at 10%.</div>
  <div class="lvl l3"><b>3 · Sheet</b>Dialogs and sheets. A line + 0 12px 32px at 18%, over a dimmed page.</div>
</div>
<div class="grid2" style="margin-top:22px">
  <div class="panel lines">
    <div class="ln"><span>rule · 1px</span><div style="border-top:1px solid var(--rule)"></div></div>
    <div class="ln"><span>edge · 1px</span><div style="border-top:1px solid var(--edge)"></div></div>
    <div class="ln"><span>accent · focus</span><div style="border-top:2px solid var(--accent)"></div></div>
    <div class="ln"><span>plain gradient</span><div style="height:18px;border-radius:7px;background:var(--grad-plain);box-shadow:inset 0 0 0 1px var(--rule)"></div></div>
    <div class="ln"><span>accent gradient</span><div style="height:18px;border-radius:7px;background:var(--grad-accent);box-shadow:inset 0 0 0 1px var(--line-accent)"></div></div>
    <div class="ln"><span>state gradients</span><div style="height:18px;border-radius:7px;background:linear-gradient(90deg,var(--line-attention),var(--line-vouched) 50%,var(--line-failure))"></div></div>
  </div>
  <div class="panel"><div class="radii"><div class="rad" style="border-radius:5px">5 · code</div><div class="rad" style="border-radius:7px">7 · control</div><div class="rad" style="border-radius:10px">10 · card</div><div class="rad" style="border-radius:16px">16 · floating</div><div class="rad" style="border-radius:99px">pill · state</div></div></div>
</div>

<h2>Icons</h2>
<p>Lucide (ISC), one set on all three clients, drawn at a 1.5 stroke: thin, round, quiet. 16 in a row, 18 in a control, 22 here. An icon is ink unless it shows a state. Then it takes that state's colour, and a word always goes with it.</p>
{icon_grid()}

<h2>Components</h2>
<p>The pieces every screen is made of, each in its states.</p>
<div class="grid2">
<div class="stack">
  <h3>Buttons</h3>
  <div class="row"><span class="btn prom">Send</span><span class="btn accent">Approve</span><span class="btn">Files</span><span class="btn focus">Focused</span><span class="btn quiet">Cancel</span><span class="btn quiet hover">Hover</span><span class="btn danger">{I("archive",16)}Archive</span><span class="btn" disabled>Disabled</span></div>
  <div class="row"><span class="btn icon-btn">{I("ellipsis",16)}</span><span class="btn icon-btn">{I("pin",16)}</span><span class="btn quiet icon-btn">{I("x",16)}</span><span class="btn quiet icon-btn">{I("search",16)}</span></div>
  <div class="cap">Every button is light. Prominent has a stronger edge and bold text, one per view. Accent is a light cobalt gradient with cobalt text, for the one choice that moves work on. Quiet buttons have no edge until the pointer is on them.</div>
  <h3>Fields and choices</h3>
  <div class="row"><span class="field ph">{I("search",16)}Search, or label:name</span><span class="field focus">web-shop</span></div>
  <div class="row"><span class="field well">Filled field, set into the page</span><span class="seg"><span class="on">Sessions</span><span>Workflows</span><span>Files</span></span></div>
  <div class="row"><span class="toggle on"></span><span>Fast mode</span><span class="toggle"></span><span>Sandbox</span><span class="check on">{I("check",12)}</span><span>Remember</span><span class="check"></span><span>Not set</span></div>
  <h3>Labels and states</h3>
  <div class="row"><span class="chip issue">{I("circle-dot",13)}#812</span><span class="chip pull">{I("git-pull-request",13)}P#44</span><span class="chip mono">{I("git-branch",13)}main</span><span class="chip">ui</span><span class="chip">audit</span></div>
  <div class="row"><span class="badge attention">{I("circle-help",14)}Needs you</span><span class="badge working">{I("loader-circle",14)}Working</span><span class="badge vouched">{I("circle-check",14)}Merged</span><span class="badge failure">{I("circle-x",14)}Failed</span></div>
  <h3>Notices</h3>
  <div class="notice info"><span class="bar"></span>{I("info",18)}<div>The host is offline. Sessions wait until it is back.</div></div>
  <div class="notice warn"><span class="bar"></span>{I("triangle-alert",18)}<div>This session has used 80% of its budget.</div></div>
  <div class="notice err"><span class="bar"></span>{I("circle-alert",18)}<div>The build failed. <a style="color:var(--accent)">Open the log</a></div></div>
  <h3>Menu, tooltip, toast, progress</h3>
  <div class="row" style="align-items:flex-start;gap:24px">
    <div class="menu"><div>{I("pin",16)}Pin</div><div class="hl">{I("git-branch",16)}Move to a worktree</div><div>{I("external-link",16)}Open in Finder<span class="kbd">⌘O</span></div><hr><div class="danger">{I("archive",16)}Archive</div></div>
    <div class="stack"><div class="tip">Archive · ⌘⌫</div><div class="toast">{I("circle-check",18)}Merged P#44 into main</div><div class="progress"><span></span></div><div class="row" style="color:var(--secondary);font-size:13px">{I("loader-circle",16)}Working · 12s</div></div>
  </div>
</div>
<div class="stack">
  <h3>Session list</h3>
  <div class="side">
    <div class="sec"><span>Needs you</span><span style="color:var(--attention)">1</span></div>
    <div class="srow sel"><span class="st attention">{I("circle-help",17)}</span><span class="t">Fix the login redirect</span><span class="w">2m</span><span class="s">Asks: which callback URL?</span></div>
    <div class="sec"><span>Working</span><span>2</span></div>
    <div class="srow hover"><span class="st">{I("loader-circle",17)}</span><span class="t">Docs: dark mode screenshots</span><span class="w">5m</span><span class="s"><span style="color:var(--issue)">#812</span> · writing the page</span></div>
    <div class="srow"><span class="st">{I("circle-pause",17)}</span><span class="t">Speed up the test suite</span><span class="w">12m</span><span class="s">Waiting for the build lease</span></div>
    <div class="sec"><span>Done</span><span>2</span></div>
    <div class="srow unread"><span class="st vouched">{I("circle-check",17)}</span><span class="t">Rename the export button</span><span class="w">1h</span><span class="s"><span style="color:var(--pull)">P#44</span> merged</span></div>
    <div class="srow"><span class="st failure">{I("circle-x",17)}</span><span class="t">Upgrade the test runner</span><span class="w">3h</span><span class="s">Failed: the build broke</span></div>
  </div>
  <div class="cap">Selected (a light cobalt gradient and bar) · hover · waiting · unread (the cobalt dot) · failed. Only "needs you" and the endings have colour.</div>
  <h3>Chat</h3>
  <div class="chat">
    <div class="me prose">After sign-in the page goes back to the home page, not the page I was on.</div>
    <div class="who">Claude</div>
    <div class="tool">{I("file-text",15)}Read <code>src/auth/callback.ts</code></div>
    <div class="prose">The callback always redirects to <code>/</code>. Keep the path in the OAuth <code>state</code> and read it back:</div>
<pre><span class="kw">const</span> returnTo = url.searchParams.<span class="fn">get</span>(<span class="str">"state"</span>) ?? <span class="str">"/"</span>;
<span class="cm">// accept only same-site paths</span>
<span class="kw">return</span> Response.<span class="fn">redirect</span>(<span class="kw">new</span> URL(returnTo, url), 302);</pre>
    <div class="card"><div class="by">Asked by "Fix the login redirect"</div><div class="q">Which callback URL do you use in production?</div>
      <span class="opt pick">/auth/callback</span><span class="opt">/oauth/return</span><div class="row" style="margin-top:10px"><span class="btn quiet">No thanks</span><span class="btn quiet">No, because…</span></div></div>
  </div>
  <h3>Prompt bar</h3>
  <div class="prompt"><div class="ph">What do you want to do?</div><div class="bar2"><span class="row" style="gap:6px">{I("paperclip",18)}{I("mic",18)}<span class="chip mono">{I("git-branch",13)}main</span></span><span class="send">{I("arrow-up",16)}</span></div></div>
  <h3>Sheet and empty state</h3>
  <div class="sheetdemo"><div class="l3"><b style="font-size:16px">Approve this machine?</b><div style="color:var(--secondary);font-size:14px;margin:4px 0 14px">Compare the digits with the ones in its log: <code>506 767</code></div><div class="row" style="justify-content:flex-end"><span class="btn">Deny</span><span class="btn accent">{I("shield-check",16)}Approve</span></div></div></div>
  <div class="panel empty">{I("message-circle",28)}<b>No sessions yet</b>Start one with {I("square-pen",15)} or ⌘N.</div>
</div>
</div>
</div>
<script>document.querySelector(".mode-name").textContent = document.documentElement.classList.contains("dark") ? "dark" : "light";</script>
</body>
</html>
'''
OUT.write_text(page)
print(OUT)
