// The #1631 walk of the gitlab server's views, with no account and no Agents host: the real
// gitlab-mcp binary against a stand-in GitLab (canned REST v4 answers), and its three pages
// drawn in headless Chrome inside a stand-in host that speaks the MCP Apps bridge as the
// clients' hosts do (ui/initialize, tool-input and tool-result, tools/call, agents/open-diff,
// agents/start-agent, agents/message-agent). It proves the pages run and call this server's
// tools; the clients' own hosts are walked with a real account (#1634).
//
//   node Go/internal/gitlabmcp/walk/walk.mjs <gitlab-mcp binary> <out dir>

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdirSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "../../../../Web/test/walk/cdp.mjs";

const [binary, out] = process.argv.slice(2);
mkdirSync(out, { recursive: true });
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

// MARK: The stand-in GitLab

const at = (minutes) => new Date(Date.now() + minutes * 60_000).toISOString();
const alex = { id: 1, username: "alex" }, dev = { id: 2, username: "dev" };
const web = "https://gitlab.test/group/app/-";
const mr = (iid, branch, author, extra) => ({ iid, title: `MR ${iid}`, state: "opened", source_branch: branch, target_branch: "main",
  web_url: `${web}/merge_requests/${iid}`, author, draft: false, source_project_id: 7, target_project_id: 7, has_conflicts: false,
  detailed_merge_status: "mergeable", merge_status: "can_be_merged", sha: `s${iid}`, created_at: at(-120), updated_at: at(-60), ...extra });
const mrs = [
  mr(3, "fix-mean", dev, { title: "Fix the mean", description: "Divide by the count, not the sum.", detailed_merge_status: "not_approved",
    head_pipeline: { id: 100, status: "failed", web_url: "https://gitlab.test/p/100" }, updated_at: at(-5) }),
  mr(4, "docs", alex, { title: "Write the docs", draft: true, merge_when_pipeline_succeeds: true }),
];
const routes = {
  "GET user": alex,
  "GET merge_requests": mrs,
  "GET merge_requests/3": mrs[0],
  "GET merge_requests/3/diffs": [
    { old_path: "average.py", new_path: "average.py", diff: "@@ -1,3 +1,4 @@\n def mean(xs):\n-    return sum(xs)\n+    n = len(xs)\n+    return sum(xs) / n\n" },
    { old_path: "logo.png", new_path: "logo.png", new_file: true, diff: "" }],
  "GET merge_requests/3/discussions": [
    { id: "d1", notes: [{ id: 31, body: "Looks right to me.", author: alex, created_at: at(-30) }] },
    { id: "d2", notes: [{ id: 32, type: "DiffNote", body: "What if xs is empty?", author: alex, created_at: at(-20),
      position: { new_path: "average.py", new_line: 3 } }, { id: 33, type: "DiffNote", body: "Then it raises.", author: dev, created_at: at(-10) }] }],
  "GET pipelines": [{ id: 100, status: "failed", ref: "fix-mean", sha: "s3", web_url: "https://gitlab.test/p/100", updated_at: at(-5) },
    { id: 101, status: "running", ref: "docs", sha: "s4", web_url: "https://gitlab.test/p/101", updated_at: at(-2) }],
  "GET pipelines/100/jobs": [{ id: 7, name: "test", stage: "test", status: "failed", web_url: "https://gitlab.test/j/7" },
    { id: 9, name: "build", stage: "build", status: "success", web_url: "https://gitlab.test/j/9" }],
  "GET jobs/7/trace": "\u001b[0Ksection_start:1700000000:step_script\r\u001b[0K$ pytest\n\u001b[31mFAIL: test_mean\u001b[0m\nassert 6 == 2\n",
  "GET issues": [{ iid: 5, title: "The mean is off", state: "opened", author: dev, web_url: `${web}/issues/5`, labels: ["bug"],
    assignees: [alex], user_notes_count: 2, created_at: at(-300), updated_at: at(-40) }],
  "GET issues/5": { iid: 5, title: "The mean is off", description: "## Work\n\n- **Inspect** the response.\n\n[Read the docs](https://gitlab.test/docs)", state: "opened",
    author: dev, web_url: `${web}/issues/5`, labels: ["bug"], assignees: [alex] },
  "POST merge_requests/3/notes": { id: 900 },
  "PUT merge_requests/3/merge": { iid: 3, state: "merged", merge_commit_sha: "m3" },
  "POST merge_requests/3/approve": { id: 1 },
  "POST pipelines/100/retry": { id: 100, status: "pending", web_url: "https://gitlab.test/p/100" },
};
const written = [];
const gitlab = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    const path = req.url.split("?")[0].replace(/^\/api\/v4\/(projects\/group%2Fapp\/)?/, "");
    const key = `${req.method} ${path}`;
    if (req.method !== "GET") written.push(`${key} ${body}`);
    const answer = routes[key];
    if (answer === undefined) { res.writeHead(404, { "content-type": "application/json" }); res.end('{"message":"404 Not found"}'); return; }
    res.writeHead(req.method === "POST" ? 201 : 200, { "content-type": typeof answer === "string" ? "text/plain" : "application/json" });
    res.end(typeof answer === "string" ? answer : js(answer));
  });
}).listen(0, "127.0.0.1");
await new Promise((resolve) => gitlab.once("listening", resolve));

// MARK: The server, over stdio

const server = spawn(binary, [], { env: { ...process.env, GITLAB_TOKEN: "glpat-walk", GITLAB_URL: `http://127.0.0.1:${gitlab.address().port}` },
  stdio: ["pipe", "pipe", "inherit"] });
let next = 1, buffer = "";
const waiting = new Map();
server.stdout.on("data", (chunk) => {
  buffer += chunk;
  for (let i; (i = buffer.indexOf("\n")) >= 0;) {
    const line = buffer.slice(0, i); buffer = buffer.slice(i + 1);
    const m = JSON.parse(line);
    if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); }
  }
});
const rpc = (method, params) => new Promise((resolve) => {
  const id = next++; waiting.set(id, resolve);
  server.stdin.write(js({ jsonrpc: "2.0", id, method, params }) + "\n");
});
await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "walk", version: "1" } });
server.stdin.write(js({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
const html = async (uri) => (await rpc("resources/read", { uri })).result.contents[0].text;

// MARK: The stand-in host

const host = (view, tool, args) => `<!doctype html><html><head><title>host</title></head><body style="margin:0">
<iframe id="view" style="border:0;width:100%;height:1400px"></iframe>
<script>
window.asked = []; window.diff = null; window.started = null; window.opened = null;
const frame = document.getElementById("view");
const tell = (m) => frame.contentWindow.postMessage(Object.assign({ jsonrpc: "2.0" }, m), "*");
const call = (params) => fetch("/call", { method: "POST", body: JSON.stringify(params) }).then((r) => r.json());
window.addEventListener("message", async (event) => {
  const m = event.data;
  if (event.source !== frame.contentWindow || !m || m.jsonrpc !== "2.0") return;
  window.asked.push(m.method);
  const reply = (result, error) => tell(error ? { id: m.id, error } : { id: m.id, result });
  switch (m.method) {
    case "ui/initialize": reply({ protocolVersion: "2026-01-26", hostContext: { theme: "light" } }); break;
    case "ui/notifications/initialized":
      tell({ method: "ui/notifications/tool-input", params: { arguments: ${js(args)} } });
      tell({ method: "ui/notifications/tool-result", params: await call({ name: ${js(tool)}, arguments: ${js(args)} }) });
      break;
    case "tools/call": reply(await call(m.params)); break;
    case "agents/open-diff": window.diff = m.params; reply({}); break;
    case "agents/start-agent": window.started = m.params; reply({}); break;
    case "agents/message-agent": reply(null, { code: -32001, message: "no agent on that branch" }); break;
    case "ui/open-link": window.opened = m.params.url; reply({}); break;
    default: if (m.id !== undefined) reply(null, { code: -32601, message: "not here" });
  }
});
fetch("/view?uri=" + encodeURIComponent(${js(view)})).then((r) => r.text()).then((page) => { frame.srcdoc = page; });
</script></body></html>`;
const pages = {};
const front = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/call") {
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", async () => { res.writeHead(200, { "content-type": "application/json" }); res.end(js((await rpc("tools/call", JSON.parse(body))).result)); });
    return;
  }
  if (url.pathname === "/view") { html(url.searchParams.get("uri")).then((h) => { res.writeHead(200, { "content-type": "text/html" }); res.end(h); }); return; }
  res.writeHead(200, { "content-type": "text/html" });
  res.end(pages[url.pathname] ?? "no such page");
}).listen(0, "127.0.0.1");
await new Promise((resolve) => front.once("listening", resolve));
const base = `http://127.0.0.1:${front.address().port}`;
pages["/mrs"] = host("ui://gitlab/merge-requests", "show_merge_requests", { project: "group/app" });
pages["/issues"] = host("ui://gitlab/issues", "show_issues", { project: "group/app" });
pages["/mr"] = host("ui://gitlab/mr", "show_merge_request", { project: "group/app", number: 3 });

// MARK: The walk

const chrome = await launch({ profile: `/tmp/1631-gitlab-chrome-${process.pid}` });
const view = (expression) => `(() => { const d = document.getElementById("view").contentDocument; return (${expression}); })()`;
const waitFor = async (page, expression, what, timeout = 15_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await page.eval(view(`Boolean(${expression})`)).catch(() => false)) return true;
    await sleep(100);
  }
  const seen = await page.eval(view(`d.querySelector("main") ? d.querySelector("main").innerText.slice(0, 300) : "no view"`)).catch((e) => e.message);
  check(false, `waited for ${what}; the view says ${js(seen)}, the host was asked ${js(await page.eval("window.asked").catch(() => null))}`);
  return false;
};
const press = (page, words) => page.eval(view(`(() => {
  const b = [...d.querySelectorAll("button, a")].find((b) => b.textContent.trim().startsWith(${js(words)}));
  if (b) b.click();
  return Boolean(b);
})()`));
const text = (page) => page.eval(view(`d.querySelector("main").innerText`));

try {
  // Merge requests, and a merge request's page in place.
  const list = await chrome.page(`${base}/mrs`, { width: 900, height: 1100 });
  await waitFor(list, `d.querySelectorAll("#mrs li").length === 2`, "two merge requests");
  const rows = await list.eval(view(`[...d.querySelectorAll("#mrs li")].map((li) => li.innerText.replace(/\\s+/g, " "))`));
  check(/Pipeline failed/.test(rows[0]) && /Approval needed/.test(rows[0]) && /Retry/.test(rows[0]), `!3 says its failed pipeline, approvals and Retry: ${js(rows[0])}`);
  check(/Draft/.test(rows[1]) && /Pipeline running/.test(rows[1]) && /Auto-merge on/.test(rows[1]), `!4 says draft, running and auto-merge: ${js(rows[1])}`);
  await list.shot(`${out}/web-1-merge-requests.png`);

  await press(list, "Fix the mean");
  await waitFor(list, `d.querySelector("#page .tabs")`, "the merge request's page");
  const head = await text(list);
  check(/‹ Merge requests/.test(head) && /GitLab ↗/.test(head) && /fix-mean → main/.test(head) && /\+2 −1/.test(head), "its page: back, GitLab, branches and counts");
  check(/Looks right to me/.test(head) && /Divide by the count/.test(head), "Conversation: its description and comment");
  await list.shot(`${out}/web-2-merge-request.png`);

  await press(list, "Discussions on lines");
  await waitFor(list, `d.querySelector(".path") && d.querySelector(".path").textContent.startsWith("average.py:3")`, "a discussion on average.py:3");
  check(/Then it raises/.test(await text(list)), "the thread's answer is under it");

  await press(list, "Files");
  await press(list, "Show Diff");
  await sleep(500);
  const diff = await list.eval("window.diff");
  check(diff && diff.files.length === 2 && diff.files[0].hunks[0].lines.length === 4 && /\/diffs$/.test(diff.url),
    `Show Diff asks the app's diff (agents/open-diff) with the files: ${js(diff && diff.files.map((f) => f.path))}`);

  await press(list, "Pipeline");
  await waitFor(list, `[...d.querySelectorAll("button")].some((b) => b.textContent === "Show Log")`, "Show Log on the failed job");
  await press(list, "Show Log");
  await waitFor(list, `d.querySelector("pre.log") && /FAIL: test_mean/.test(d.querySelector("pre.log").textContent)`, "the job's log");
  check(!/section_start|\u001b/.test(await list.eval(view(`d.querySelector("pre.log").textContent`))), "the log is plain text");
  await list.shot(`${out}/web-3-pipeline-log.png`);

  await list.eval(view(`(() => { const t = d.querySelector("textarea"); t.value = "Rebased on main."; return true; })()`));
  await press(list, "Comment");
  await waitFor(list, `/Commented\\./.test(d.querySelector(".status").textContent)`, "Commented.");
  await press(list, "Approve");
  await waitFor(list, `/Approved !3/.test(d.querySelector(".status").textContent)`, "Approved !3.");
  await press(list, "Merge");
  await waitFor(list, `d.querySelector(".confirm")`, "Merge's question");
  check(/Merge !3 into main and delete fix-mean\? Its pipeline failed\./.test(await text(list)), "Merge asks first, and says the pipeline failed");
  await list.shot(`${out}/web-4-merge-confirm.png`);
  await list.eval(view(`d.querySelector(".confirm button.primary").click()`));
  await waitFor(list, `/Merged !3/.test(d.querySelector(".status").textContent)`, "Merged !3.");
  await press(list, "Ask an Agent");
  await sleep(500);
  const started = await list.eval("window.started");
  check(started && started.branch === "fix-mean" && /GitLab merge request !3/.test(started.prompt) && started.labels[0] === "!3",
    `Ask an Agent with no agent on the branch: the new-agent form on fix-mean: ${js(started)}`);
  check(written.some((w) => w.startsWith("POST merge_requests/3/notes") && w.includes("Rebased on main.")) &&
    written.some((w) => w.startsWith("POST merge_requests/3/approve")) && written.some((w) => w.startsWith("PUT merge_requests/3/merge")),
  `the comment, approve and merge reached GitLab: ${js(written)}`);

  // The merge request's page on its own (ui://gitlab/mr), on a phone's width.
  const one = await chrome.page(`${base}/mr`, { width: 390, height: 1000 });
  await waitFor(one, `d.querySelector("#page .tabs")`, "ui://gitlab/mr drawn");
  check(!/‹ Merge requests/.test(await text(one)), "on its own, it has no way back to a list");
  await one.shot(`${out}/web-5-merge-request-phone.png`);

  // Issues, and Start Agent.
  const issues = await chrome.page(`${base}/issues`, { width: 900, height: 700 });
  await waitFor(issues, `d.querySelectorAll("#issues li").length === 1`, "one issue");
  check(/@alex/.test(await text(issues)) && /bug/.test(await text(issues)), "the issue with its assignee and label");
  check(!/Show details|Hide details/.test(await text(issues)), "the issue has no details button");
  await issues.eval(view(`d.querySelector("#issues .title").click()`));
  await waitFor(issues, `d.querySelector(".issue-body strong")`, "the Markdown description");
  check(/Work/.test(await text(issues)) && /Inspect/.test(await text(issues)), "the row expands with rich-text Markdown");
  await issues.eval(view(`d.querySelector(".issue-body a").click()`));
  await waitFor(issues, `window.parent.opened === "https://gitlab.test/docs"`, "a Markdown link opens through the host");
  await issues.eval(view(`d.querySelector("#issues .title").click()`));
  check(await issues.eval(view(`d.querySelector("#issues li").getAttribute("aria-expanded")`)) === "false", "clicking the row closes its details");
  await issues.eval(view(`d.querySelector("#issues .title").click()`));
  await waitFor(issues, `d.querySelector("#issues li").getAttribute("aria-expanded") === "true"`, "the row opens again");
  await press(issues, "Start Agent");
  await sleep(500);
  const forIssue = await issues.eval("window.started");
  check(forIssue && forIssue.prompt.startsWith("#5: The mean is off\n") && /GitLab issue in group\/app/.test(forIssue.prompt) && forIssue.labels[0] === "#5", `Start Agent fills the form: ${js(forIssue)}`);
  await issues.shot(`${out}/web-6-issues.png`);

  for (const [name, page] of [["merge requests", list], ["merge request", one], ["issues", issues]]) {
    check(page.errors.length === 0, `no script errors on ${name}: ${js(page.errors)}`);
  }
} catch (e) {
  check(false, e.stack);
} finally {
  await chrome.close();
  server.kill();
  gitlab.close();
  front.close();
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
