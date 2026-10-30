// The #2941 walk of the Lineage section on the github, gitlab and linear servers' Issues and
// PR pages, with no account and no Agents host: each page, put together from its files as
// the server's page() does, drawn in headless Chrome inside a stand-in host that speaks the
// MCP Apps bridge as the clients' hosts do. The stand-in answers the servers' tools with
// scratch data, and agents_lineage as the Agents host does (Go/internal/agentsd/viewlineage.go,
// whose tests prove those words). It proves the pages ask for the section with their own
// address and draw what the host says, and that a host which refuses it is said plainly.
//
//   node Go/internal/githubmcp/walk/lineage2941.mjs <out dir>

import { createServer } from "node:http";
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "../../../../Web/test/walk/cdp.mjs";

const [out] = process.argv.slice(2);
mkdirSync(out, { recursive: true });
const internal = join(dirname(fileURLToPath(import.meta.url)), "../..");
const js = JSON.stringify;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

// A page as its server's page() puts it together.
const page = (server, name) => {
  const read = (n) => readFileSync(join(internal, server, "pages", n), "utf8");
  let html = read(name);
  for (const part of ["common.css", "prpage.css", "mrpage.css", "bridge.js", "lineage.js", "prpage.js", "mrpage.js"]) {
    if (html.includes(`/*${part}*/`)) html = html.replace(`/*${part}*/`, () => read(part));
  }
  return html;
};

// MARK: Scratch answers

const at = (minutes) => new Date(Date.now() + minutes * 60_000).toISOString();
const ghIssue = "https://github.com/example/shop/issues/41";
const ghPR = "https://github.com/example/shop/pull/52";
const glIssue = "https://gitlab.test/group/app/-/issues/5";
const lnIssue = "https://linear.app/example/issue/ENG-4/fix-the-totals";
const sessions = [
  { id: "A1", title: "Fix the cart totals", how: "works on it", words: "$3.10 · 412.0k tokens · 1h 20m · archived" },
  { id: "A2", title: "Round the totals again", how: "opened #52", words: "$1.25 · 160.5k tokens · 35m" },
  { id: "A3", title: "Run the cart tests", how: "a helper of “Fix the cart totals”", words: "$0.40 · 51.2k tokens · 9m · archived" },
];
const lineage = {
  [ghIssue]: { ref: "github:example/shop#41", summary: "3 sessions · 2 pull requests (1 merged, 1 waste)",
    total: "$4.75 · 540.2k in, 83.5k out · 1h 52m agent time", waste: "Waste: $1.30 · 150.1k in, 22.0k out · 31m agent time",
    sessions, issues: [], prs: [
      { ref: "github:example/shop#52", name: "#52", url: ghPR, outcome: "merged", words: "$2.10 · 230.0k in, 35.5k out · 48m agent time" },
      { ref: "github:example/shop#47", name: "#47", url: "https://github.com/example/shop/pull/47", outcome: "closed", waste: true,
        words: "$1.30 · 150.1k in, 22.0k out · 31m agent time" }] },
  [ghPR]: { ref: "github:example/shop#52", summary: "1 session", total: "$2.10 · 230.0k in, 35.5k out · 48m agent time",
    sessions: [sessions[1]], prs: [], issues: [{ ref: "github:example/shop#41", name: "#41", url: ghIssue }] },
  [glIssue]: { ref: "gitlab:group/app#5", summary: "1 session · 1 pull request (1 open)",
    total: "$0.85 · 98.0k in, 12.4k out · 22m agent time",
    sessions: [{ id: "B1", title: "Divide by the count", how: "works on it", words: "$0.85 · 110.4k tokens · 25m" }], issues: [],
    prs: [{ ref: "gitlab:group/app!3", name: "!3", url: "https://gitlab.test/group/app/-/merge_requests/3", outcome: "open",
      words: "$0.40 · 41.0k in, 6.0k out · 10m agent time" }] },
  [lnIssue]: { ref: "linear:ENG-4", summary: "No session has worked on it yet.", sessions: [], prs: [], issues: [] },
};
const tools = {
  "github show_issues": { repo: "example/shop", issues: [
    { number: 41, title: "The cart total is off by a cent", url: ghIssue, labels: ["bug"], assignees: ["dev"], author: "dev", comments: 2, updatedAt: at(-40) },
    { number: 40, title: "Say the delivery date", url: "https://github.com/example/shop/issues/40", labels: [], assignees: [], author: "dev", updatedAt: at(-300) }] },
  "github show_issue_details": { body: "Totals round each line, then add.", bodyHTML: "<p>Totals round each line, then add.</p>",
    closed_by_pull_requests: { total_count: 1, references: [{ number: 52, title: "Round once, at the end", url: ghPR, state: "MERGED", repository: "example/shop" }] } },
  "github show_pull_request": { number: 52, title: "Round once, at the end", url: ghPR, repo: "example/shop", state: "merged",
    branch: "agents/41-cart-totals", base: "main", author: "dev", viewer: "dev", createdAt: at(-200), additions: 12, deletions: 4,
    checks: "passing", body: "Fixes #41", comments: [], threads: [], files: [{ path: "cart.py", additions: 12, deletions: 4 }],
    filesTotal: 1, checkRuns: [{ name: "test", state: "passing" }], headSha: "abc" },
  "gitlab show_issues": { project: "group/app", issues: [
    { number: 5, title: "The mean is off", url: glIssue, labels: ["bug"], assignees: ["dev"], author: "dev", updatedAt: at(-40) }] },
  "gitlab show_issue_details": { description: "Divide by the count.", descriptionHTML: "<p>Divide by the count.</p>" },
  "linear show_issues": { teams: [{ key: "ENG", name: "Engineering" }], states: ["started"], issues: [
    { identifier: "ENG-4", title: "Fix the totals", url: lnIssue, state: "In Progress", stateType: "started", author: "dev", updatedAt: at(-20) }] },
  "linear show_issue_details": { description: "The totals are off.", descriptionHTML: "<p>The totals are off.</p>" },
};
const answer = (server, name, args, refuse) => {
  if (name === "agents_lineage") {
    if (refuse) return { isError: true, content: [{ type: "text", text: "A view may not call agents_lineage." }] };
    const l = lineage[args.url];
    return l ? { content: [{ type: "text", text: js(l) }], structuredContent: l }
      : { isError: true, content: [{ type: "text", text: `No issue or pull request at ${js(args.url)}.` }] };
  }
  const found = tools[`${server} ${name}`];
  return found ? { content: [{ type: "text", text: js(found) }], structuredContent: found }
    : { isError: true, content: [{ type: "text", text: "no such tool" }] };
};

// MARK: The stand-in host

const host = (server, file, tool, args, refuse) => `<!doctype html><html><head><title>host</title></head><body style="margin:0">
<iframe id="view" style="border:0;width:100%;height:1400px"></iframe>
<script>
window.asked = [];
const frame = document.getElementById("view");
const tell = (m) => frame.contentWindow.postMessage(Object.assign({ jsonrpc: "2.0" }, m), "*");
const call = (params) => fetch("/call", { method: "POST", body: JSON.stringify({ server: ${js(server)}, refuse: ${js(!!refuse)}, ...params }) }).then((r) => r.json());
window.addEventListener("message", async (event) => {
  const m = event.data;
  if (event.source !== frame.contentWindow || !m || m.jsonrpc !== "2.0") return;
  window.asked.push(m.method === "tools/call" ? m.params.name + " " + JSON.stringify(m.params.arguments) : m.method);
  const reply = (result, error) => tell(error ? { id: m.id, error } : { id: m.id, result });
  switch (m.method) {
    case "ui/initialize": reply({ protocolVersion: "2026-01-26", hostContext: { theme: "light" } }); break;
    case "ui/notifications/initialized":
      tell({ method: "ui/notifications/tool-input", params: { arguments: ${js(args)} } });
      tell({ method: "ui/notifications/tool-result", params: await call({ name: ${js(tool)}, arguments: ${js(args)} }) });
      break;
    case "tools/call": reply(await call(m.params)); break;
    default: if (m.id !== undefined) reply(null, { code: -32601, message: "not here" });
  }
});
frame.srcdoc = ${js(page(`${server}mcp`, file)).replace(/</g, "\\u003c")};
</script></body></html>`;
const pages = {
  "/github-issues": host("github", "issues.html", "show_issues", { repo: "example/shop" }),
  "/github-pr": host("github", "pr.html", "show_pull_request", { repo: "example/shop", number: 52 }),
  "/gitlab-issues": host("gitlab", "issues.html", "show_issues", { project: "group/app" }),
  "/linear-issues": host("linear", "issues.html", "show_issues", {}),
  "/github-refused": host("github", "issues.html", "show_issues", { repo: "example/shop" }, true),
};
const front = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/call") {
    let body = "";
    req.on("data", (c) => { body += c; });
    req.on("end", () => {
      const p = JSON.parse(body);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(js(answer(p.server, p.name, p.arguments || {}, p.refuse)));
    });
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(pages[url.pathname] ?? "no such page");
}).listen(0, "127.0.0.1");
await new Promise((resolve) => front.once("listening", resolve));
const base = `http://127.0.0.1:${front.address().port}`;

// MARK: The walk

const chrome = await launch({ profile: `/tmp/2941-lineage-chrome-${process.pid}` });
const view = (expression) => `(() => { const d = document.getElementById("view").contentDocument; return (${expression}); })()`;
const waitFor = async (p, expression, what, timeout = 15_000) => {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await p.eval(view(`Boolean(${expression})`)).catch(() => false)) return true;
    await sleep(100);
  }
  const seen = await p.eval(view(`d.querySelector("main") ? d.querySelector("main").innerText.slice(0, 300) : "no view"`)).catch((e) => e.message);
  check(false, `waited for ${what}; the view says ${js(seen)}, the host was asked ${js(await p.eval("window.asked").catch(() => null))}`);
  return false;
};
const text = (p) => p.eval(view(`d.querySelector("main").innerText`));
const lineageText = (p) => p.eval(view(`d.querySelector(".lineage").innerText.replace(/\\s+/g, " ")`));
const expand = (p) => p.eval(view(`d.querySelector("#issues .title").click()`));
const opened = [];

try {
  const gh = await chrome.page(`${base}/github-issues`, { width: 900, height: 900 });
  await waitFor(gh, `d.querySelectorAll("#issues li").length === 2`, "two GitHub issues");
  await expand(gh);
  await waitFor(gh, `d.querySelector(".lineage .lineage-row strong")`, "the issue's Lineage section");
  const l = await lineageText(gh);
  check(/3 sessions · 2 pull requests \(1 merged, 1 waste\)/.test(l) && /Cost: \$4\.75/.test(l) && /Waste: \$1\.30/.test(l),
    `GitHub issue: the summary, the cost and the waste: ${js(l)}`);
  check(/Fix the cart totals works on it · \$3\.10/.test(l) && /a helper of “Fix the cart totals”/.test(l) && /#52 Merged/.test(l) && /#47 Closed/.test(l),
    "GitHub issue: each session and pull request, with its end and cost");
  check((await gh.eval("window.asked")).includes(`agents_lineage ${js({ url: ghIssue })}`), "it asks with the issue's own address");
  opened.push(gh);
  await gh.shot(`${out}/web-github-issue.png`);

  const pr = await chrome.page(`${base}/github-pr`, { width: 900, height: 700 });
  await waitFor(pr, `d.querySelector("#page .tabs")`, "the pull request's page");
  check(!(await pr.eval("window.asked")).some((a) => a.startsWith("agents_lineage")), "the PR page asks for nothing until its Lineage tab is chosen");
  await pr.eval(view(`[...d.querySelectorAll(".tabs button")].find((b) => b.textContent === "Lineage").click()`));
  await waitFor(pr, `d.querySelector(".lineage .lineage-row strong")`, "the PR's Lineage tab");
  const pl = await lineageText(pr);
  check(/1 session/.test(pl) && /Round the totals again opened #52/.test(pl) && /Fixes #41/.test(pl), `GitHub PR: its session and the issue it fixes: ${js(pl)}`);
  opened.push(pr);
  await pr.shot(`${out}/web-github-pr.png`);

  const gl = await chrome.page(`${base}/gitlab-issues`, { width: 900, height: 700 });
  await waitFor(gl, `d.querySelectorAll("#issues li").length === 1`, "one GitLab issue");
  await expand(gl);
  await waitFor(gl, `d.querySelector(".lineage .lineage-row strong")`, "the GitLab issue's Lineage section");
  const gll = await lineageText(gl);
  check(/1 session · 1 pull request \(1 open\)/.test(gll) && /!3 Open/.test(gll), `GitLab issue: its session and merge request: ${js(gll)}`);
  opened.push(gl);
  await gl.shot(`${out}/web-gitlab-issue.png`);

  const ln = await chrome.page(`${base}/linear-issues`, { width: 900, height: 600 });
  await waitFor(ln, `d.querySelectorAll("#issues li").length === 1`, "one Linear issue");
  await expand(ln);
  await waitFor(ln, `d.querySelector(".lineage .lineage-row strong")`, "the Linear issue's Lineage section");
  check(/No session has worked on it yet\./.test(await lineageText(ln)), "Linear issue with nothing on it: says so");
  opened.push(ln);
  await ln.shot(`${out}/web-linear-empty.png`);

  const old = await chrome.page(`${base}/github-refused`, { width: 900, height: 600 });
  await waitFor(old, `d.querySelectorAll("#issues li").length === 2`, "the issues, on a host that refuses");
  await expand(old);
  await waitFor(old, `/Lineage: this app keeps none here/.test(d.querySelector(".lineage").innerText)`, "the refusal, said");
  check(/Totals round each line/.test(await text(old)), "the rest of the issue is drawn as before");
  opened.push(old);
  await old.shot(`${out}/web-github-refused.png`);

  for (const p of opened) check(p.errors.length === 0, `no script errors: ${js(p.errors)}`);
} catch (e) {
  check(false, e.stack);
} finally {
  await chrome.close();
  front.close();
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
