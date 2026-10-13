// The CI watcher's views (MCP apps), carried in the binary so it is one file on a host.
// Each is a page with no network: it talks to the host only through postMessage.

/// `ui://ci/board`: the open pull requests with a check pill, and Rerun on a failing one. A
/// PR's title opens its page in the same view (#837).
let boardHTML = #"""
<!doctype html>
<html><head><meta charset="utf-8"><title>Pull requests</title>
<!-- The CI watcher's board (ui://ci/board): list_prs's result, with Rerun on a failing PR.
     A PR's title opens its page (get_pr, #837) in place, with a way back to the list.
     It has no network: it speaks only the MCP Apps postMessage bridge to its host. -->
<style>
:root { color-scheme: light dark;
  --color-background-primary: light-dark(#fff, #111); --color-background-secondary: light-dark(#f7f7f7, #1a1a1a);
  --color-text-primary: light-dark(#111, #eee); --color-text-secondary: light-dark(#555, #aaa);
  --color-border-primary: light-dark(#ddd, #333); --color-text-info: light-dark(#33c, #99f);
  --color-text-danger: light-dark(#b00, #f77); --color-text-success: light-dark(#070, #7c7);
  --color-background-danger: light-dark(#fdecec, #3a1414); --color-background-success: light-dark(#e9f6e9, #12301a);
  --color-background-info: light-dark(#ececfd, #1c1c3a); --color-background-tertiary: light-dark(#f2f2f2, #222);
  --font-sans: system-ui, sans-serif; --font-mono: ui-monospace, monospace;
  --border-radius-sm: 6px; --border-radius-full: 999px; --font-text-sm-size: 12px; --font-text-md-size: 14px; }
html, body { margin: 0; background: transparent; }
body { font: var(--font-text-md-size)/1.45 var(--font-sans); color: var(--color-text-primary); }
main { padding: 12px 14px; display: grid; gap: 8px; }
header { display: flex; gap: 8px; align-items: baseline; }
h1 { font-size: 15px; margin: 0; font-weight: 600; }
.muted { color: var(--color-text-secondary); font-size: var(--font-text-sm-size); }
.grow { flex: 1; }
ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; }
li { display: grid; grid-template-columns: auto 1fr auto auto; gap: 4px 10px; align-items: center;
  padding: 6px 4px; border-top: 1px solid var(--color-border-primary); }
li:first-child { border-top: none; }
.title { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.branch { grid-column: 2; font: var(--font-text-sm-size) var(--font-mono); color: var(--color-text-secondary);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
a { color: var(--color-text-info); text-decoration: none; cursor: pointer; }
a:hover { text-decoration: underline; }
.pill { font-size: var(--font-text-sm-size); padding: 1px 8px; border-radius: var(--border-radius-full);
  background: var(--color-background-tertiary); color: var(--color-text-secondary); white-space: nowrap; }
.pill.passing { background: var(--color-background-success); color: var(--color-text-success); }
.pill.failing { background: var(--color-background-danger); color: var(--color-text-danger); }
.pill.running { background: var(--color-background-info); color: var(--color-text-info); }
.pill.conflicts { background: var(--color-background-warning); color: var(--color-text-warning); }
button { font: inherit; font-size: 13px; color: var(--color-text-primary); background: var(--color-background-primary);
  border: 1px solid var(--color-border-primary); border-radius: var(--border-radius-sm); padding: 2px 10px; cursor: pointer; }
button:disabled { opacity: 0.5; cursor: default; }
.error { color: var(--color-text-danger); font-size: var(--font-text-sm-size); }
#list { display: grid; gap: 8px; }
a.title { color: inherit; }
\#(prPageCSS)
</style></head>
<body><main><div id="list">
  <header><h1>Pull requests</h1><span id="repo" class="muted"></span><span class="grow"></span>
    <button id="refresh" type="button" disabled>Refresh</button></header>
  <div id="state" class="muted">Waiting for the host…</div>
  <ul id="prs"></ul>
</div><div id="page" hidden></div></main>
<script>
\#(prPageJS)
(() => {
  let nextID = 1, repo = "";
  const waiting = new Map();
  const $ = (id) => document.getElementById(id);
  const post = (message) => window.parent.postMessage(Object.assign({ jsonrpc: "2.0" }, message), "*");
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = nextID++; waiting.set(id, { resolve, reject }); post({ id, method, params });
  });
  const notify = (method, params) => post({ method, params });
  const log = (data, level) => notify("notifications/message", { level: level || "info", logger: "ci-board", data });
  const el = (tag, props, children) => {
    const node = Object.assign(document.createElement(tag), props || {});
    for (const child of children || []) node.append(child);
    return node;
  };
  const say = (text, isError) => { $("state").textContent = text; $("state").className = isError ? "error" : "muted"; };
  const openLink = (url) => request("ui/open-link", { url }).catch((e) => log("open-link refused: " + e.message, "warning"));
  const link = (text, url) => {
    const a = el("a", { textContent: text, href: url });
    a.onclick = (event) => { event.preventDefault(); openLink(url); };
    return a;
  };
  const errorText = (result) => ((result && result.content) || []).map((c) => c.text || "").join("\n") || "it failed";
  const PILLS = { passing: "Passing", failing: "Failing", running: "Running", none: "No checks" };

  const apply = (ctx) => {
    const vars = (ctx && ctx.styles && ctx.styles.variables) || {};
    for (const [key, value] of Object.entries(vars)) if (value) document.documentElement.style.setProperty(key, value);
    if (ctx && ctx.theme) document.documentElement.style.colorScheme = ctx.theme;
  };
  const size = () => {
    const box = document.querySelector("main").getBoundingClientRect();
    notify("ui/notifications/size-changed", { width: Math.ceil(box.width), height: Math.ceil(box.height) });
  };

  const draw = (result) => {
    if (!result || result.isError) { say("Couldn't list pull requests: " + errorText(result), true); return; }
    let prs = result.structuredContent && result.structuredContent.prs;
    if (!prs) { try { prs = JSON.parse(result.content[0].text).prs; } catch (e) { prs = null; } }
    if (!Array.isArray(prs)) { say("The result has no pull requests in it.", true); return; }
    $("prs").replaceChildren(...prs.map(row));
    say(prs.length ? `${prs.length} open · as of ${new Date().toLocaleTimeString()}` : "No open pull requests.");
    $("refresh").disabled = !repo;
  };

  const row = (pr) => {
    const checks = PILLS[pr.checks] ? pr.checks : "none";
    const action = el("span");
    if (checks === "failing" && pr.failedRunId && repo) {
      const button = el("button", { type: "button", textContent: "Rerun" });
      button.onclick = () => rerun(pr, button, action);
      action.append(button);
    }
    return el("li", {}, [
      link(`#${pr.number}`, pr.url),
      title(pr),
      el("span", {}, [
        el("span", { className: `pill ${checks}`, textContent: PILLS[checks] }),
        ...(pr.conflicts ? [" ", el("span", { className: "pill conflicts", textContent: "Conflicts", title: "Conflicts with its base: rebase it" })] : []),
      ]),
      action,
      el("span", { className: "branch", textContent: pr.branch, title: pr.branch }),
    ]);
  };

  // The title opens the PR's page in place; ‹ Pull requests comes back to a fresh list.
  const title = (pr) => {
    const a = el("a", { className: "title", textContent: pr.title, title: "Open #" + pr.number, href: "#" });
    a.onclick = (event) => { event.preventDefault(); $("list").hidden = true; $("page").hidden = false; page.show(pr.number); };
    return a;
  };
  const back = () => { $("page").hidden = true; $("list").hidden = false; list(); };
  const page = prPage({ el, request, link, openLink, log, errorText, repo: () => repo, size: () => size() }, back);

  const list = async () => {
    $("refresh").disabled = true;
    try { draw(await request("tools/call", { name: "list_prs", arguments: { repo } })); }
    catch (e) { say("Couldn't list pull requests: " + e.message, true); $("refresh").disabled = false; }
  };

  const rerun = async (pr, button, action) => {
    button.disabled = true; button.textContent = "Rerunning…";
    try {
      const result = await request("tools/call", { name: "rerun_failed", arguments: { repo, runId: pr.failedRunId } });
      if (result.isError) throw new Error(errorText(result));
      log(`rerun #${pr.number} run ${pr.failedRunId}`);
      await list();
    } catch (e) {
      button.disabled = false; button.textContent = "Rerun";
      action.append(el("span", { className: "error", textContent: " " + e.message }));
    }
  };

  window.addEventListener("message", (event) => {
    const m = event.data;
    if (!m || m.jsonrpc !== "2.0") return;
    if (m.id !== undefined && !m.method && waiting.has(m.id)) {
      const w = waiting.get(m.id); waiting.delete(m.id);
      return m.error ? w.reject(new Error(m.error.message)) : w.resolve(m.result);
    }
    switch (m.method) {
      case "ui/notifications/tool-input":
        repo = (m.params && m.params.arguments && m.params.arguments.repo) || "";
        $("repo").textContent = repo;
        say("Listing…"); break;
      case "ui/notifications/tool-result":
        draw(m.params); break;
      case "ui/notifications/tool-cancelled":
        say("Cancelled: " + ((m.params && m.params.reason) || "no reason given"), true); break;
      case "ui/notifications/host-context-changed":
        apply(m.params); size(); break;
      case "ui/resource-teardown":
        post({ id: m.id, result: {} }); break;
      case "ping":
        post({ id: m.id, result: {} }); break;
    }
  });

  $("refresh").onclick = list;
  new ResizeObserver(size).observe(document.querySelector("main"));
  request("ui/initialize", {
    protocolVersion: "2026-01-26", clientInfo: { name: "ci-board", version: "0.1.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
  }).then((result) => {
    apply(result && result.hostContext);
    notify("ui/notifications/initialized", {});
    say("Waiting for the pull requests…");
    size();
  }).catch((e) => say("The host refused: " + e.message, true));
})();
</script>
</body></html>

"""#

/// `ui://ci/issues`: the open issues with their labels; a label narrows the list.
let issuesHTML = #"""
<!doctype html>
<html><head><meta charset="utf-8"><title>Issues</title>
<!-- The CI watcher's issues (ui://ci/issues): list_issues's result; a label narrows it.
     Start Agent opens the app's new-agent form filled in for the issue (agents/start-agent, #834).
     It has no network: it speaks only the MCP Apps postMessage bridge to its host. -->
<style>
:root { color-scheme: light dark;
  --color-background-primary: light-dark(#fff, #111); --color-background-secondary: light-dark(#f7f7f7, #1a1a1a);
  --color-text-primary: light-dark(#111, #eee); --color-text-secondary: light-dark(#555, #aaa);
  --color-border-primary: light-dark(#ddd, #333); --color-text-info: light-dark(#33c, #99f);
  --color-text-danger: light-dark(#b00, #f77); --color-text-success: light-dark(#070, #7c7);
  --color-background-danger: light-dark(#fdecec, #3a1414); --color-background-success: light-dark(#e9f6e9, #12301a);
  --color-background-info: light-dark(#ececfd, #1c1c3a); --color-background-tertiary: light-dark(#f2f2f2, #222);
  --font-sans: system-ui, sans-serif; --font-mono: ui-monospace, monospace;
  --border-radius-sm: 6px; --border-radius-full: 999px; --font-text-sm-size: 12px; --font-text-md-size: 14px; }
html, body { margin: 0; background: transparent; }
body { font: var(--font-text-md-size)/1.45 var(--font-sans); color: var(--color-text-primary); }
main { padding: 12px 14px; display: grid; gap: 8px; }
header { display: flex; gap: 8px; align-items: baseline; }
h1 { font-size: 15px; margin: 0; font-weight: 600; }
.muted { color: var(--color-text-secondary); font-size: var(--font-text-sm-size); }
.grow { flex: 1; }
ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; }
li { display: grid; grid-template-columns: auto 1fr auto; gap: 2px 10px; align-items: center;
  padding: 6px 4px; border-top: 1px solid var(--color-border-primary); }
li:first-child { border-top: none; }
.title { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.start { grid-column: 3; grid-row: 1 / span 2; white-space: nowrap; }
.meta { grid-column: 2; display: flex; flex-wrap: wrap; gap: 4px 6px; align-items: center;
  font-size: var(--font-text-sm-size); color: var(--color-text-secondary); }
a { color: var(--color-text-info); text-decoration: none; cursor: pointer; }
a:hover { text-decoration: underline; }
.pill { font-size: var(--font-text-sm-size); padding: 1px 8px; border-radius: var(--border-radius-full);
  background: var(--color-background-tertiary); color: var(--color-text-secondary); white-space: nowrap; }
button.pill { border: none; font: inherit; font-size: var(--font-text-sm-size); }
button.pill:hover, .pill.chosen { background: var(--color-background-info); color: var(--color-text-info); }
button { font: inherit; font-size: 13px; color: var(--color-text-primary); background: var(--color-background-primary);
  border: 1px solid var(--color-border-primary); border-radius: var(--border-radius-sm); padding: 2px 10px; cursor: pointer; }
button:disabled { opacity: 0.5; cursor: default; }
.error { color: var(--color-text-danger); font-size: var(--font-text-sm-size); }
</style></head>
<body><main>
  <header><h1>Issues</h1><span id="repo" class="muted"></span><span id="label"></span><span class="grow"></span>
    <button id="refresh" type="button" disabled>Refresh</button></header>
  <div id="state" class="muted">Waiting for the host…</div>
  <ul id="issues"></ul>
</main>
<script>
(() => {
  let nextID = 1, repo = "", label = "";
  const waiting = new Map();
  const $ = (id) => document.getElementById(id);
  const post = (message) => window.parent.postMessage(Object.assign({ jsonrpc: "2.0" }, message), "*");
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = nextID++; waiting.set(id, { resolve, reject }); post({ id, method, params });
  });
  const notify = (method, params) => post({ method, params });
  const log = (data, level) => notify("notifications/message", { level: level || "info", logger: "ci-issues", data });
  const el = (tag, props, children) => {
    const node = Object.assign(document.createElement(tag), props || {});
    for (const child of children || []) node.append(child);
    return node;
  };
  const say = (text, isError) => { $("state").textContent = text; $("state").className = isError ? "error" : "muted"; };
  const openLink = (url) => request("ui/open-link", { url }).catch((e) => log("open-link refused: " + e.message, "warning"));
  const link = (text, url) => {
    const a = el("a", { textContent: text, href: url });
    a.onclick = (event) => { event.preventDefault(); openLink(url); };
    return a;
  };
  const errorText = (result) => ((result && result.content) || []).map((c) => c.text || "").join("\n") || "it failed";
  const ago = (time) => {
    const minutes = Math.max(0, Math.round((Date.now() - Date.parse(time)) / 60000));
    if (!Number.isFinite(minutes)) return "";
    if (minutes < 60) return minutes + "m ago";
    if (minutes < 48 * 60) return Math.round(minutes / 60) + "h ago";
    return Math.round(minutes / 1440) + "d ago";
  };

  const apply = (ctx) => {
    const vars = (ctx && ctx.styles && ctx.styles.variables) || {};
    for (const [key, value] of Object.entries(vars)) if (value) document.documentElement.style.setProperty(key, value);
    if (ctx && ctx.theme) document.documentElement.style.colorScheme = ctx.theme;
  };
  const size = () => {
    const box = document.querySelector("main").getBoundingClientRect();
    notify("ui/notifications/size-changed", { width: Math.ceil(box.width), height: Math.ceil(box.height) });
  };

  // The label the list is narrowed to, with a way back to every open issue.
  const drawLabel = () => {
    if (!label) { $("label").replaceChildren(); return; }
    const clear = el("button", { type: "button", className: "pill chosen", textContent: label + " ✕", title: "Show every open issue" });
    clear.onclick = () => choose("");
    $("label").replaceChildren(clear);
  };

  const draw = (result) => {
    if (!result || result.isError) { say("Couldn't list issues: " + errorText(result), true); $("refresh").disabled = !repo; return; }
    let issues = result.structuredContent && result.structuredContent.issues;
    if (!issues) { try { issues = JSON.parse(result.content[0].text).issues; } catch (e) { issues = null; } }
    if (!Array.isArray(issues)) { say("The result has no issues in it.", true); return; }
    $("issues").replaceChildren(...issues.map(row));
    drawLabel();
    say(issues.length ? `${issues.length} open · as of ${new Date().toLocaleTimeString()}`
      : label ? `No open issues labelled ${label}.` : "No open issues.");
    $("refresh").disabled = !repo;
  };

  const row = (issue) => {
    const labels = (issue.labels || []).map((name) => {
      if (!repo) return el("span", { className: "pill", textContent: name });
      const pill = el("button", { type: "button", className: name === label ? "pill chosen" : "pill", textContent: name,
        title: "Only issues labelled " + name });
      pill.onclick = () => choose(name === label ? "" : name);
      return pill;
    });
    const comments = issue.comments ? ` · ${issue.comments} comment${issue.comments === 1 ? "" : "s"}` : "";
    const start = el("button", { type: "button", className: "start", textContent: "Start Agent",
      title: `A new agent for #${issue.number}, in a worktree of its own` });
    start.onclick = () => startAgent(issue);
    return el("li", {}, [
      link(`#${issue.number}`, issue.url),
      el("span", { className: "title", textContent: issue.title, title: issue.title }),
      start,
      el("span", { className: "meta" }, [
        el("span", { textContent: `${issue.author || "someone"}${comments}${issue.updatedAt ? " · " + ago(issue.updatedAt) : ""}` }),
        ...labels,
      ]),
    ]);
  };

  // The app's new-agent form, filled in for this issue (#834). The person starts it, or not;
  // the agent assigns the issue to the signed-in gh user once it does.
  const startAgent = async (issue) => {
    const n = issue.number, on = repo ? ` --repo ${repo}` : "";
    const prompt = `Work on GitHub issue #${n} (\`gh issue view ${n}${on}\`): ${issue.title}\n\n`
      + `First assign it to yourself: \`gh issue edit ${n}${on} --add-assignee @me\`.`;
    try {
      await request("agents/start-agent", { prompt, labels: ["#" + n], worktree: `${n} ${issue.title}` });
      say(`A new agent for #${n} is ready to start.`);
    } catch (e) { say("Couldn't open a new agent: " + e.message, true); log("start-agent refused: " + e.message, "warning"); }
  };

  const list = async () => {
    $("refresh").disabled = true;
    const args = label ? { repo, label } : { repo };
    try { draw(await request("tools/call", { name: "list_issues", arguments: args })); }
    catch (e) { say("Couldn't list issues: " + e.message, true); $("refresh").disabled = false; }
  };
  const choose = (name) => { label = name; drawLabel(); say("Listing…"); list(); };

  window.addEventListener("message", (event) => {
    const m = event.data;
    if (!m || m.jsonrpc !== "2.0") return;
    if (m.id !== undefined && !m.method && waiting.has(m.id)) {
      const w = waiting.get(m.id); waiting.delete(m.id);
      return m.error ? w.reject(new Error(m.error.message)) : w.resolve(m.result);
    }
    switch (m.method) {
      case "ui/notifications/tool-input": {
        const args = (m.params && m.params.arguments) || {};
        repo = args.repo || ""; label = args.label || "";
        $("repo").textContent = repo;
        say("Listing…"); break;
      }
      case "ui/notifications/tool-result":
        draw(m.params); break;
      case "ui/notifications/tool-cancelled":
        say("Cancelled: " + ((m.params && m.params.reason) || "no reason given"), true); break;
      case "ui/notifications/host-context-changed":
        apply(m.params); size(); break;
      case "ui/resource-teardown":
        post({ id: m.id, result: {} }); break;
      case "ping":
        post({ id: m.id, result: {} }); break;
    }
  });

  $("refresh").onclick = list;
  new ResizeObserver(size).observe(document.querySelector("main"));
  request("ui/initialize", {
    protocolVersion: "2026-01-26", clientInfo: { name: "ci-issues", version: "0.1.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
  }).then((result) => {
    apply(result && result.hostContext);
    notify("ui/notifications/initialized", {});
    say("Waiting for the issues…");
    size();
  }).catch((e) => say("The host refused: " + e.message, true));
})();
</script>
</body></html>

"""#

// MARK: A pull request's page (#837)

/// The PR page's styles, in the board (a PR's title opens it) and in `ui://ci/pr`.
let prPageCSS = #"""
#page { display: grid; gap: 8px; }
#page[hidden], #list[hidden] { display: none; }
#page .branch { grid-column: auto; white-space: normal; overflow-wrap: anywhere; }
.bar { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
h2 { font-size: 15px; margin: 0; font-weight: 600; }
.pills { display: flex; gap: 4px; flex-wrap: wrap; }
.pill.approved, .pill.merged { background: var(--color-background-success); color: var(--color-text-success); }
.pill.changes_requested, .pill.closed { background: var(--color-background-danger); color: var(--color-text-danger); }
.pill.skipped { opacity: 0.7; }
.tabs { display: flex; gap: 4px; border-bottom: 1px solid var(--color-border-primary); }
.tabs button { border: none; border-bottom: 2px solid transparent; border-radius: 0; background: transparent; padding: 4px 10px; }
.tabs button.chosen { border-bottom-color: var(--color-text-info); color: var(--color-text-info); }
.body { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0; }
.note { border: 1px solid var(--color-border-primary); border-radius: var(--border-radius-sm); padding: 6px 10px; display: grid; gap: 4px; }
.note .who { font-size: var(--font-text-sm-size); color: var(--color-text-secondary); display: flex; gap: 6px; align-items: center; }
details { border: 1px solid var(--color-border-primary); border-radius: var(--border-radius-sm); }
summary { padding: 4px 8px; cursor: pointer; display: flex; gap: 8px; font: var(--font-text-sm-size) var(--font-mono); }
summary .path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.add { color: var(--color-text-success); } .del { color: var(--color-text-danger); }
pre.diff { margin: 0; padding: 4px 0; overflow-x: auto; font: 12px/1.4 var(--font-mono); border-top: 1px solid var(--color-border-primary); }
pre.diff span { display: block; padding: 0 8px; white-space: pre; }
pre.diff .add { background: var(--color-background-success); } pre.diff .del { background: var(--color-background-danger); }
pre.diff .hunk { color: var(--color-text-info); background: var(--color-background-info); }
.checks li { grid-template-columns: auto 1fr; }
textarea { font: inherit; color: inherit; background: var(--color-background-primary); border: 1px solid var(--color-border-primary);
  border-radius: var(--border-radius-sm); padding: 6px 8px; min-height: 3.2em; resize: vertical; width: 100%; box-sizing: border-box; }
.actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
button.primary { background: var(--color-background-success); color: var(--color-text-success); border-color: transparent; font-weight: 600; }
.confirm { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; padding: 6px 10px; border-radius: var(--border-radius-sm);
  background: var(--color-background-secondary); }
"""#

/// The PR page itself: `prPage(ui, back)` gives `{ show(number), draw(result) }`. `ui` is the
/// view's bridge: `request`, `link`, `openLink`, `el`, `log`, `errorText`, `repo()` and
/// `size()`. With `back`, a ‹ Pull requests button calls it.
let prPageJS = #"""
const prPage = (ui, back) => {
  const { el, request, link, errorText, log } = ui;
  const root = document.getElementById("page");
  let pr = null, tab = "conversation", confirming = false, line = { text: "", error: false };
  // Kept across redraws, so a tab or a refresh doesn't lose what was typed.
  const text = el("textarea", { placeholder: "Comment, or what the agent is to fix…", rows: 3 });
  const opened = new Set();
  const PILLS = { passing: "Passing", failing: "Failing", running: "Running", none: "No checks", skipped: "Skipped" };
  const REVIEWS = { approved: "Approved", changes_requested: "Changes requested", review_required: "Review required", commented: "Commented" };
  const ago = (time) => {
    const minutes = Math.max(0, Math.round((Date.now() - Date.parse(time)) / 60000));
    if (!Number.isFinite(minutes)) return "";
    if (minutes < 60) return minutes + "m ago";
    if (minutes < 48 * 60) return Math.round(minutes / 60) + "h ago";
    return Math.round(minutes / 1440) + "d ago";
  };
  const pill = (kind, text, title) => el("span", { className: "pill " + kind, textContent: text, title: title || "" });
  const button = (text, onclick, props) => {
    const b = el("button", Object.assign({ type: "button", textContent: text }, props || {}));
    b.onclick = onclick;
    return b;
  };
  const say = (text, error) => { line = { text, error: !!error }; const s = root.querySelector(".status"); if (s) { s.textContent = text; s.className = "status " + (error ? "error" : "muted"); } };
  const call = async (name, args) => {
    const result = await request("tools/call", { name, arguments: Object.assign({ repo: ui.repo(), number: pr.number }, args || {}) });
    if (!result || result.isError) throw new Error(errorText(result));
    return result.structuredContent || JSON.parse(result.content[0].text);
  };
  const fetchPR = async (number, diff) => {
    const result = await request("tools/call", { name: "get_pr", arguments: diff ? { repo: ui.repo(), number, diff: true } : { repo: ui.repo(), number } });
    if (!result || result.isError) throw new Error(errorText(result));
    return result.structuredContent || JSON.parse(result.content[0].text);
  };

  const pills = () => {
    const out = [];
    if (pr.state !== "open") out.push(pill(pr.state, pr.state === "merged" ? "Merged" : "Closed"));
    if (pr.draft) out.push(pill("none", "Draft"));
    out.push(pill(PILLS[pr.checks] ? pr.checks : "none", PILLS[pr.checks] || "No checks"));
    if (pr.conflicts) out.push(pill("conflicts", "Conflicts", "Conflicts with its base: rebase it"));
    if (pr.review && REVIEWS[pr.review]) out.push(pill(pr.review, REVIEWS[pr.review]));
    if (pr.autoMerge && pr.state === "open") out.push(pill("running", "Auto-merge on", "Merges once its checks pass"));
    return out;
  };

  const conversation = () => {
    const notes = [];
    notes.push(el("div", { className: "note" }, [
      el("div", { className: "who" }, [el("span", { textContent: `${pr.author || "someone"} · ${ago(pr.createdAt)}` })]),
      el("p", { className: "body", textContent: pr.body || "No description." }),
    ]));
    for (const c of pr.comments || []) {
      const who = [el("span", { textContent: `${c.author || "someone"} · ${ago(c.at)}` })];
      if (c.review && REVIEWS[c.review]) who.push(pill(c.review, REVIEWS[c.review]));
      const note = [el("div", { className: "who" }, who)];
      if (c.body) note.push(el("p", { className: "body", textContent: c.body }));
      notes.push(el("div", { className: "note" }, note));
    }
    notes.push(el("div", { className: "muted", textContent: "Comments on lines of code are on GitHub." }));
    return notes;
  };

  const diffLines = (patch) => el("pre", { className: "diff" }, patch.split("\n").map((text) =>
    el("span", { textContent: text || " ", className: text.startsWith("@@") ? "hunk" : text.startsWith("+") ? "add" : text.startsWith("-") ? "del" : "" })));

  const files = () => {
    const list = (pr.files || []).map((f) => {
      const d = el("details", { open: opened.has(f.path) }, [el("summary", {}, [
        el("span", { className: "path", textContent: f.path, title: f.path }),
        el("span", { className: "add", textContent: "+" + f.additions }), el("span", { className: "del", textContent: "−" + f.deletions }),
      ])]);
      if (typeof f.patch === "string") d.append(f.patch ? diffLines(f.patch) : el("div", { className: "muted", textContent: "  No lines to show (a binary file or a rename)." }));
      else if (pr.diffTruncated) d.append(el("div", { className: "muted", textContent: "  Too long to show here: open it on GitHub." }));
      d.ontoggle = () => { if (d.open) opened.add(f.path); else opened.delete(f.path); size(); };
      return d;
    });
    if (!(pr.files || []).some((f) => typeof f.patch === "string") && !pr.diffTruncated) {
      list.unshift(el("div", { className: "muted", textContent: "Loading the diff…" }));
      loadDiff();
    }
    return list.length ? list : [el("div", { className: "muted", textContent: "No files changed." })];
  };
  let loadingDiff = false;
  const loadDiff = async () => {
    if (loadingDiff) return;
    loadingDiff = true;
    try { pr = await fetchPR(pr.number, true); draw(); }
    catch (e) { say("Couldn't load the diff: " + e.message, true); }
    finally { loadingDiff = false; }
  };

  const checks = () => {
    const rows = (pr.checkRuns || []).map((c) => el("li", {}, [
      pill(PILLS[c.state] ? c.state : "none", PILLS[c.state] || c.state),
      c.url ? link(c.name, c.url) : el("span", { textContent: c.name }),
    ]));
    const out = [el("ul", { className: "checks" }, rows.length ? rows : [el("li", { className: "muted", textContent: "No checks." })])];
    if (pr.checks === "failing" && pr.failedRunId && pr.state === "open") {
      out.push(el("div", { className: "actions" }, [button("Rerun Failed", async (event) => {
        event.target.disabled = true;
        try { await call("rerun_failed", { runId: pr.failedRunId }); say("Rerunning the failed jobs."); refresh(); }
        catch (e) { event.target.disabled = false; say("Couldn't rerun: " + e.message, true); }
      })]));
    }
    return out;
  };

  const mergeWords = () => pr.checks === "running" ? "Auto-merge" : "Merge";
  const actions = () => {
    if (pr.state !== "open") return [];
    const comment = button("Comment", async () => {
      if (!text.value.trim()) { say("Write a comment first.", true); return; }
      comment.disabled = true;
      try { await call("comment_on_pr", { body: text.value }); text.value = ""; say("Commented."); refresh(); }
      catch (e) { say("Couldn't comment: " + e.message, true); }
      finally { comment.disabled = false; }
    });
    const fix = button("Ask the Agent to Fix", () => askToFix(text.value), { title: "Send it to this chat's agent as your message; you say Send first" });
    const blocked = pr.conflicts || pr.draft || (pr.autoMerge && pr.checks === "running");
    const merge = button(mergeWords(), () => { confirming = true; draw(); }, {
      className: "primary", disabled: !!blocked,
      title: pr.conflicts ? "It conflicts with its base: rebase it first" : pr.draft ? "A draft can't be merged" : "",
    });
    const out = [text, el("div", { className: "actions" }, [comment, fix, el("span", { className: "grow" }), merge])];
    if (confirming) {
      const auto = pr.checks === "running";
      const words = auto ? `Squash and merge #${pr.number} into ${pr.base} once its checks pass, then delete ${pr.branch}?`
        : `Squash and merge #${pr.number} into ${pr.base} and delete ${pr.branch}?` + (pr.checks === "failing" ? " Its checks are failing." : "");
      const yes = button(mergeWords(), async () => {
        yes.disabled = true;
        try {
          const r = await call("merge_pr", { auto });
          confirming = false;
          say(r.auto ? "Auto-merge is on: it merges once its checks pass." : `Merged #${pr.number}.`);
          log(`merge #${pr.number}${auto ? " (auto)" : ""}`);
          refresh();
        } catch (e) { yes.disabled = false; say("Couldn't merge: " + e.message, true); }
      }, { className: "primary" });
      out.push(el("div", { className: "confirm" }, [el("span", { className: "grow", textContent: words }), yes,
        button("Cancel", () => { confirming = false; draw(); })]));
    }
    return out;
  };

  // Into this chat, as the person's own message: the host asks them first (ui/message).
  const askToFix = async (note) => {
    const n = pr.number, failing = pr.checks === "failing";
    const text = `Fix pull request #${n} (\`gh pr view ${n} --comments\`) on ${pr.branch}: `
      + [failing ? "its failing checks" + (pr.failedRunId ? ` (failed_log runId ${pr.failedRunId})` : "") : "",
         pr.review === "changes_requested" ? "the changes asked for in its reviews" : "", pr.conflicts ? `its conflict with ${pr.base}` : ""]
        .filter(Boolean).concat(note.trim() ? [] : ["its review comments"]).join(", ") + "."
      + (note.trim() ? "\n\n" + note.trim() : "") + "\n\nPush to the same branch.";
    say("Send it from under the view…");
    try { await request("ui/message", { role: "user", content: [{ type: "text", text }] }); say("Sent to the agent."); }
    catch (e) { say(e.message, true); }
  };

  const size = () => ui.size();
  const draw = () => {
    if (!pr) return;
    const head = [];
    if (back) head.push(button("‹ Pull requests", back));
    head.push(el("span", { className: "grow" }), link("GitHub ↗", pr.url), button("Refresh", refresh));
    const tabs = [["conversation", "Conversation", (pr.comments || []).length], ["files", "Files", (pr.files || []).length],
      ["checks", "Checks", (pr.checkRuns || []).length]].map(([id, words, count]) =>
      button(count ? `${words} ${count}` : words, () => { tab = id; draw(); }, { className: tab === id ? "chosen" : "" }));
    const panel = tab === "files" ? files() : tab === "checks" ? checks() : conversation();
    root.replaceChildren(
      el("div", { className: "bar" }, head),
      el("div", { className: "bar" }, [link(`#${pr.number}`, pr.url), el("h2", { className: "title grow", textContent: pr.title, title: pr.title })]),
      el("div", { className: "pills" }, pills()),
      el("div", { className: "branch", textContent: `${pr.branch} → ${pr.base} · ${pr.author || "someone"} · ${ago(pr.createdAt)} · +${pr.additions} −${pr.deletions} · ${(pr.files || []).length} files` }),
      el("div", { className: "tabs" }, tabs),
      ...panel,
      ...actions(),
      el("div", { className: "status " + (line.error ? "error" : "muted"), textContent: line.text }),
    );
    size();
  };
  const refresh = async () => {
    if (!pr) return;
    try { const fresh = await fetchPR(pr.number, tab === "files"); pr = fresh; draw(); }
    catch (e) { say("Couldn't refresh: " + e.message, true); }
  };
  return {
    show: async (number) => {
      pr = null; tab = "conversation"; confirming = false; line = { text: "", error: false }; text.value = ""; opened.clear();
      root.replaceChildren(el("div", { className: "muted", textContent: `Loading #${number}…` }));
      try { pr = await fetchPR(number, false); draw(); }
      catch (e) {
        root.replaceChildren(...(back ? [button("‹ Pull requests", back)] : []), el("div", { className: "error", textContent: `Couldn't show #${number}: ` + e.message }));
      }
    },
    draw: (result) => {
      if (!result || result.isError) { root.replaceChildren(el("div", { className: "error", textContent: "Couldn't show the pull request: " + errorText(result) })); return; }
      let detail = result.structuredContent;
      if (!detail) { try { detail = JSON.parse(result.content[0].text); } catch (e) { detail = null; } }
      if (!detail || !detail.number) { root.replaceChildren(el("div", { className: "error", textContent: "The result has no pull request in it." })); return; }
      pr = detail; draw();
    },
  };
};
"""#

/// `ui://ci/pr`: one pull request's page (#837), fed by get_pr.
let prHTML = #"""
<!doctype html>
<html><head><meta charset="utf-8"><title>Pull request</title>
<!-- The CI watcher's pull request page (ui://ci/pr): get_pr's result, with Comment, Merge and
     Ask the Agent to Fix (ui/message, which the person sends). It has no network: it speaks
     only the MCP Apps postMessage bridge to its host. -->
<style>
:root { color-scheme: light dark;
  --color-background-primary: light-dark(#fff, #111); --color-background-secondary: light-dark(#f7f7f7, #1a1a1a);
  --color-text-primary: light-dark(#111, #eee); --color-text-secondary: light-dark(#555, #aaa);
  --color-border-primary: light-dark(#ddd, #333); --color-text-info: light-dark(#33c, #99f);
  --color-text-danger: light-dark(#b00, #f77); --color-text-success: light-dark(#070, #7c7);
  --color-background-danger: light-dark(#fdecec, #3a1414); --color-background-success: light-dark(#e9f6e9, #12301a);
  --color-background-info: light-dark(#ececfd, #1c1c3a); --color-background-tertiary: light-dark(#f2f2f2, #222);
  --font-sans: system-ui, sans-serif; --font-mono: ui-monospace, monospace;
  --border-radius-sm: 6px; --border-radius-full: 999px; --font-text-sm-size: 12px; --font-text-md-size: 14px; }
html, body { margin: 0; background: transparent; }
body { font: var(--font-text-md-size)/1.45 var(--font-sans); color: var(--color-text-primary); }
main { padding: 12px 14px; display: grid; gap: 8px; }
.muted { color: var(--color-text-secondary); font-size: var(--font-text-sm-size); }
.grow { flex: 1; }
ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; }
li { display: grid; gap: 4px 10px; align-items: center; padding: 6px 4px; border-top: 1px solid var(--color-border-primary); }
li:first-child { border-top: none; }
.title { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.branch { font: var(--font-text-sm-size) var(--font-mono); color: var(--color-text-secondary); overflow-wrap: anywhere; }
a { color: var(--color-text-info); text-decoration: none; cursor: pointer; }
a:hover { text-decoration: underline; }
.pill { font-size: var(--font-text-sm-size); padding: 1px 8px; border-radius: var(--border-radius-full);
  background: var(--color-background-tertiary); color: var(--color-text-secondary); white-space: nowrap; }
.pill.passing { background: var(--color-background-success); color: var(--color-text-success); }
.pill.failing { background: var(--color-background-danger); color: var(--color-text-danger); }
.pill.running { background: var(--color-background-info); color: var(--color-text-info); }
.pill.conflicts { background: var(--color-background-warning); color: var(--color-text-warning); }
button { font: inherit; font-size: 13px; color: var(--color-text-primary); background: var(--color-background-primary);
  border: 1px solid var(--color-border-primary); border-radius: var(--border-radius-sm); padding: 2px 10px; cursor: pointer; }
button:disabled { opacity: 0.5; cursor: default; }
.error { color: var(--color-text-danger); font-size: var(--font-text-sm-size); }
\#(prPageCSS)
</style></head>
<body><main><div id="page"><div class="muted">Waiting for the host…</div></div></main>
<script>
\#(prPageJS)
(() => {
  let nextID = 1, repo = "";
  const waiting = new Map();
  const post = (message) => window.parent.postMessage(Object.assign({ jsonrpc: "2.0" }, message), "*");
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = nextID++; waiting.set(id, { resolve, reject }); post({ id, method, params });
  });
  const notify = (method, params) => post({ method, params });
  const log = (data, level) => notify("notifications/message", { level: level || "info", logger: "ci-pr", data });
  const el = (tag, props, children) => {
    const node = Object.assign(document.createElement(tag), props || {});
    for (const child of children || []) node.append(child);
    return node;
  };
  const openLink = (url) => request("ui/open-link", { url }).catch((e) => log("open-link refused: " + e.message, "warning"));
  const link = (text, url) => {
    const a = el("a", { textContent: text, href: url });
    a.onclick = (event) => { event.preventDefault(); openLink(url); };
    return a;
  };
  const errorText = (result) => ((result && result.content) || []).map((c) => c.text || "").join("\n") || "it failed";
  const apply = (ctx) => {
    const vars = (ctx && ctx.styles && ctx.styles.variables) || {};
    for (const [key, value] of Object.entries(vars)) if (value) document.documentElement.style.setProperty(key, value);
    if (ctx && ctx.theme) document.documentElement.style.colorScheme = ctx.theme;
  };
  const size = () => {
    const box = document.querySelector("main").getBoundingClientRect();
    notify("ui/notifications/size-changed", { width: Math.ceil(box.width), height: Math.ceil(box.height) });
  };
  const page = prPage({ el, request, link, openLink, log, errorText, repo: () => repo, size }, null);
  const say = (text, isError) => document.getElementById("page").replaceChildren(el("div", { className: isError ? "error" : "muted", textContent: text }));

  window.addEventListener("message", (event) => {
    const m = event.data;
    if (!m || m.jsonrpc !== "2.0") return;
    if (m.id !== undefined && !m.method && waiting.has(m.id)) {
      const w = waiting.get(m.id); waiting.delete(m.id);
      return m.error ? w.reject(new Error(m.error.message)) : w.resolve(m.result);
    }
    switch (m.method) {
      case "ui/notifications/tool-input": {
        const args = (m.params && m.params.arguments) || {};
        repo = args.repo || "";
        say(args.number ? `Loading #${args.number}…` : "Loading…"); break;
      }
      case "ui/notifications/tool-result":
        page.draw(m.params); break;
      case "ui/notifications/tool-cancelled":
        say("Cancelled: " + ((m.params && m.params.reason) || "no reason given"), true); break;
      case "ui/notifications/host-context-changed":
        apply(m.params); size(); break;
      case "ui/resource-teardown":
        post({ id: m.id, result: {} }); break;
      case "ping":
        post({ id: m.id, result: {} }); break;
    }
  });

  new ResizeObserver(size).observe(document.querySelector("main"));
  request("ui/initialize", {
    protocolVersion: "2026-01-26", clientInfo: { name: "ci-pr", version: "0.1.0" },
    appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
  }).then((result) => {
    apply(result && result.hostContext);
    notify("ui/notifications/initialized", {});
    say("Waiting for the pull request…");
    size();
  }).catch((e) => say("The host refused: " + e.message, true));
})();
</script>
</body></html>

"""#
