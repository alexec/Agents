// The #329 walk: the Dashboard's own view (ui://agents/dashboard), as every client draws it,
// in headless Chrome under the strict policy a view with nothing declared gets. A parent page
// plays the host: it answers ui/initialize, gives a snapshot with all six kinds of tile, and
// answers the view's dashboard_action calls. Checks each tile kind, each action the person
// has, that a page tile's HTML is drawn with no scripts and no network, and that a later
// result redraws the open view. Needs no app, daemon or pairing.
//
//   node Web/test/walk/dashboard329.mjs [out dir]

import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const out = process.argv[2];
const root = new URL("../../../", import.meta.url);

// The view's HTML, as the Swift string literal in AppViewCatalog holds it.
const swift = readFileSync(new URL("Packages/AgentsKit/Sources/AgentsKit/AppViews/AppViewCatalog.swift", root), "utf8");
const literal = /static let dashboardHTML = """\n([\s\S]*?)\n    """/.exec(swift)?.[1];
if (!literal) throw new Error("dashboardHTML not found in AppViewCatalog.swift");
// An odd run of backslashes before "(" is Swift interpolation; an even one is an escaped backslash.
if (/(?<!\\)(?:\\\\)*\\\(/.test(literal)) throw new Error("dashboardHTML interpolates: this walk can't read it");
const html = literal.split("\n").map((line) => line.replace(/^ {4}/, "")).join("\n")
  .replace(/\\(["\\])/g, "$1");

// AppViewPolicy.strict.header: what a view that declared nothing is drawn under.
const strict = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
  + "img-src 'self' data: blob:; font-src 'self' data:; media-src 'self' data: blob:; connect-src 'none'; "
  + "frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'";

// A page tile's file that tries everything a page must not do.
const evilPage = `<style>.hi{font-weight:700} body{background:url(https://example.com/bg.png)}</style>
<script>parent.postMessage({ evil: "script" }, "*")</script>
<p class="hi" onclick="parent.postMessage({ evil: 'click' }, '*')">Hello from the page</p>
<img src="https://example.com/pixel.png" onerror="parent.postMessage({ evil: 'onerror' }, '*')">
<a id="bad" href="javascript:parent.postMessage({ evil: 'href' }, '*')">bad link</a>
<a id="good" href="https://example.org/docs">good link</a>
<iframe src="https://example.com/"></iframe><svg><animate attributeName="href" to="javascript:alert(1)"/></svg>`;

const iso = (minutesAgo) => new Date(Date.now() - minutesAgo * 60_000).toISOString();
const keeper = { id: "11111111-1111-1111-1111-111111111111", name: "Lead", kind: "agent", state: "finished" };
const snapshot = (bugs) => ({
  now: iso(0),
  update: { name: "Dashboard update" },
  order: { sections: [{ title: "Quality", tiles: ["bugs", "ci"] }] },
  tiles: [
    { id: "bugs", setAt: iso(5), keeper, points: [{ at: iso(3000), value: 9 }, { at: iso(5), value: bugs }],
      tile: { type: "number", title: "Open bugs", section: "Quality", source: "gh issue list", number: { value: bugs, good: "down" } } },
    { id: "ci", setAt: iso(5), keeper, tile: { type: "status", title: "CI", section: "Quality", status: { level: "ok", line: "green" } } },
    { id: "lanes", setAt: iso(5), keeper, tile: { type: "table", title: "Lanes", table: { columns: ["Issue", "State"],
      rows: [[{ text: "#329", url: "https://github.com/alexec/Agents/issues/329" }, "running"]] } } },
    { id: "note", setAt: iso(5), keeper, tile: { type: "note", title: "Note", note: { markdown: "**Bold** and `code`" } } },
    { id: "link", setAt: iso(5), keeper, tile: { type: "link", title: "Board", link: { url: "https://example.org/board" } } },
    { id: "page", setAt: iso(5), keeper, tile: { type: "page", title: "Status page", page: { file: "docs/status.html" } } },
    { id: "plan", setAt: iso(5), keeper, tile: { type: "page", title: "Plan", page: { file: "docs/plan.md" } } },
    { id: "quiet", setAt: iso(5), keeper, tile: { type: "status", title: "Quiet", hidden: true, status: { level: "ok", line: "x" } } },
  ],
});

// JSON inside the host's <script>, with no "</script>" to end it early.
const inScript = (value) => JSON.stringify(value).replace(/</g, "\\u003c");
const host = `<!doctype html><meta charset="utf-8"><body style="margin:0">
<iframe id="view" src="/view.html" sandbox="allow-scripts allow-same-origin" style="border:0;width:100vw;height:100vh"></iframe>
<script>
  window.calls = []; window.evil = []; window.links = []; window.reads = 0;
  const frame = document.getElementById("view");
  const say = (m) => frame.contentWindow.postMessage(Object.assign({ jsonrpc: "2.0" }, m), "*");
  window.result = (data, revision) => say({ method: "ui/notifications/tool-result",
    params: { content: [], structuredContent: data, _meta: { "agents/pageRevision": revision } } });
  addEventListener("message", (event) => {
    const m = event.data;
    if (m && m.evil) { window.evil.push(m.evil); return; }
    if (!m || m.jsonrpc !== "2.0" || !m.method) return;
    if (m.method === "ui/initialize") return say({ id: m.id, result: { hostContext: { platform: "web", theme: "light" } } });
    if (m.method === "ui/notifications/initialized") return window.result(${inScript(snapshot(4))}, 0);
    if (m.method === "ui/open-link") { window.links.push(m.params.url); return say({ id: m.id, result: {} }); }
    if (m.method !== "tools/call") return;
    const a = m.params.arguments;
    if (a.action === "read_page") {
      window.reads += 1;
      const page = a.id === "page" ? { kind: "html", text: ${inScript(evilPage)} }
        : { kind: "markdown", text: "# Plan\\n- one\\n- **two**\\n\\nDone." };
      return say({ id: m.id, result: { content: [], structuredContent: page } });
    }
    window.calls.push(a);
    say({ id: m.id, result: { content: [{ type: "text", text: "ok" }] } });
  });
</script>`;

const server = createServer((request, response) => {
  if (request.url === "/view.html") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8", "content-security-policy": strict });
    return response.end(html);
  }
  response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  response.end(host);
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;

let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const js = JSON.stringify;
const chrome = await launch({ profile: `/tmp/329-dashboard-chrome-${process.pid}` });

let page;
try {
  page = await chrome.page(`${origin}/`, { width: 1200, height: 1400 });
  const view = (expression) => page.eval(`(() => { const document = window.frames[0].document; return ${expression}; })()`);
  const press = async (label, tile) => {
    const ok = await view(`(() => {
      const scope = ${tile ? `[...document.querySelectorAll("article")].find((a) => a.querySelector("h3")?.textContent.startsWith(${js(tile)}))` : "document"};
      const b = scope && [...scope.querySelectorAll("button")].find((x) => x.textContent.trim() === ${js(label)});
      if (!b || b.disabled) return false; b.click(); return true;
    })()`);
    if (!ok) throw new Error(`no ${label} to press${tile ? ` on ${tile}` : ""}`);
    await sleep(150);
  };
  const lastCall = () => page.eval("window.calls[window.calls.length - 1]");
  await page.waitFor(`window.frames[0]?.document.querySelectorAll("article").length >= 7`);
  await page.waitFor(`window.frames[0].document.getElementById("page-page")?.shadowRoot?.textContent.includes("Hello")`);
  await sleep(500);

  // The six kinds, as the native tiles draw them.
  check(await view(`document.querySelector("article svg polyline") !== null`), "number: a trend line");
  check((await view(`document.querySelector(".delta")?.className`))?.includes("good"), "number: a fall is good when good is down");
  check(await view(`document.querySelector(".light.ok") !== null`), "status: its light");
  check(await view(`document.querySelector("td a")?.href`) === "https://github.com/alexec/Agents/issues/329", "table: a linked cell");
  check(await view(`document.querySelector("article strong")?.textContent`) === "Bold", "note: Markdown");
  check(await view(`[...document.querySelectorAll("article a")].some((a) => a.href === "https://example.org/board")`), "link: its address");
  const shadow = `document.getElementById("page-page").shadowRoot`;
  check(await view(`${shadow}.querySelector(".hi")?.textContent`) === "Hello from the page", "page: its HTML drawn as a page");
  check(await view(`document.querySelector("#page-plan h1")?.textContent`) === "Plan"
    && await view(`document.querySelectorAll("#page-plan li").length`) === 2, "page: Markdown drawn as text");
  check(await view(`[...document.querySelectorAll("h3")].every((h) => !h.textContent.startsWith("Quiet"))`), "a hidden tile is not shown");

  // Scripts and the network, off.
  check(await view(`${shadow}.querySelector("script, iframe, animate") === null`), "page: no script, frame or animation kept");
  check(await view(`[...${shadow}.querySelectorAll("*")].every((el) => ![...el.attributes].some((a) => a.name.startsWith("on")))`), "page: no event handlers kept");
  check(await view(`${shadow}.getElementById("bad").hasAttribute("href")`) === false, "page: a javascript: link is dropped");
  await view(`${shadow}.querySelector(".hi").click()`);
  await view(`${shadow}.getElementById("bad").click()`);
  await view(`${shadow}.getElementById("good").click()`);
  await sleep(300);
  check((await page.eval("window.evil")).length === 0, `page: nothing of the page's ran: ${js(await page.eval("window.evil"))}`);
  check((await page.eval("window.links")).includes("https://example.org/docs"), "page: a link in it is asked for, not followed");
  const reached = page.requests.filter((url) => url.includes("example.com"));
  check(reached.length === 0, `the page's HTML asked for nothing at for example.com: ${js(reached)}`);
  // The policy on its own, not only what the page's HTML lost: the view itself can't reach out.
  const tried = await page.eval(`(async () => {
    const w = window.frames[0];
    const fetched = await w.fetch("https://example.com/").then(() => "reached", () => "blocked");
    const image = await new Promise((done) => { const i = w.document.createElement("img"); i.onload = () => done("reached");
      i.onerror = () => done("blocked"); i.src = "https://example.com/favicon.ico"; w.document.body.append(i); });
    return fetched + " " + image;
  })()`);
  check(tried === "blocked blocked", `the strict policy blocks the view's own fetch and image: ${tried}`);
  if (out) await page.shot(`${out}/web-329-1-six-kinds.png`);

  // Each action the person has.
  await press("Update now");
  check((await lastCall())?.action === "update", "Update now");
  await press("Hide", "CI");
  check(js(await lastCall()) === js({ action: "hide", id: "ci" }), "Hide");
  await press("Show hidden");
  await press("Show", "Quiet");
  check(js(await lastCall()) === js({ action: "show", id: "quiet" }), "Show hidden, then Show");
  await press("Remove", "Quiet");
  check(js(await lastCall()) === js({ action: "remove", id: "quiet" }), "Remove");
  await press("↓", "Open bugs");
  check(js(await lastCall()) === js({ action: "move", id: "bugs", step: 1 }), "Move down");
  await view(`(() => { const s = document.querySelector("select[data-id=ci]"); s.value = "__none__"; s.dispatchEvent(new Event("change", { bubbles: true })); })()`);
  await sleep(150);
  check(js(await lastCall()) === js({ action: "move", id: "ci", section: "" }), "Move to another section");
  await press("Keeper", "Open bugs");
  check(js(await lastCall()) === js({ action: "open_keeper", id: "bugs" }), "Open Keeper");
  await press("Open", "Status page");
  check(js(await lastCall()) === js({ action: "open_page", id: "page" }), "Open a page tile");
  await press("Details", "Open bugs");
  check(await view(`document.getElementById("details").open && document.getElementById("details").textContent.includes(".agents/dashboard/bugs.json")`), "Details");
  if (out) await page.shot(`${out}/web-329-2-details.png`);
  await view(`document.getElementById("close-details").click()`);
  check(!(await page.eval("window.calls")).some((c) => c.action === "set" || "value" in c), "no action changes a tile's value");

  // A later result redraws the open view, and its pages are read again.
  const reads = await page.eval("window.reads");
  await page.eval(`window.result(${js(snapshot(2))}, 1)`);
  await page.waitFor(`window.frames[0].document.querySelector(".value")?.textContent.startsWith("2")`);
  await page.waitFor(`window.reads >= ${reads + 2}`);
  check(true, "a later result redraws the open view and reads its pages again");
  // Blocked loads are logged as refusals; the harness's own same-origin frame is warned about.
  check(page.errors.filter((e) => !e.includes("Content Security Policy") && !e.includes("Refused")
    && !e.includes("can escape its sandboxing")).length === 0,
    `no errors: ${js(page.errors)}`);
} catch (e) {
  failed += 1;
  console.log(`FAIL ${e.message}`);
  console.log(`     errors: ${JSON.stringify(page?.errors ?? [])}`);
  console.log(`     view: ${await page?.eval("window.frames[0]?.document.body.innerText.slice(0, 400)").catch(() => "?")}`);
} finally {
  await chrome.close();
  server.close();
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
