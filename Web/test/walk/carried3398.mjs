// The #3398 walk: a GitHub Codespaces provider (the codespaces-api preset) carried by the
// scratch Mac's host, from the web page alone. A fake GitHub API on loopback stands in for
// api.github.com. The provider is added over the page's own socket with a token; the host that
// carries it calls the API with the token, and the control plane only routes. Then a codespace
// is linked to the host, started and stopped through it. Prints the token it used, so the
// caller can search the control plane's folder and store for it.
//
//   node Web/test/walk/carried3398.mjs <WEB_URL> <browser code> <out dir>

import http from "node:http";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const token = `ghp_walk3398_${process.pid}_secret`;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

// The fake API: one codespace, its state, and every request with the token it carried.
let state = "Shutdown";
const seen = [];
const api = http.createServer((request, response) => {
  seen.push({ method: request.method, url: request.url, bearer: request.headers.authorization === `Bearer ${token}` });
  response.setHeader("content-type", "application/json");
  if (request.method === "GET" && request.url.startsWith("/user/codespaces")) {
    response.end(JSON.stringify({ codespaces: [{ name: "fuzzy-space", display_name: "fuzzy", state, git_status: { ref: "main" } }] }));
  } else if (request.method === "POST" && request.url === "/user/codespaces/fuzzy-space/start") {
    state = "Available";
    response.end("{}");
  } else if (request.method === "POST" && request.url === "/user/codespaces/fuzzy-space/stop") {
    state = "Shutdown";
    response.end("{}");
  } else {
    response.statusCode = 404;
    response.end("{}");
  }
});
await new Promise((done) => api.listen(0, "127.0.0.1", done));
const base = `http://127.0.0.1:${api.address().port}`;

const chrome = await launch({ profile: `/tmp/w3398-chrome-${process.pid}` });
let page;
try {
  page = await chrome.page(webURL, { width: 1300, height: 1000 });
  await page.onNewDocument(`(() => { const W = window.WebSocket; window.WebSocket = function (...a) { const s = new W(...a); window.__walkSocket = s; return s; }; window.WebSocket.prototype = W.prototype; })();`);
  await page.goto(webURL);
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`!document.querySelector("textarea") && document.body.textContent.includes("Settings")`, 20_000);
  await page.eval(`window.__walkReplies = {}; window.__walkSocket.addEventListener("message", (e) => { try { const m = JSON.parse(e.data); if (String(m.id).startsWith("walk-")) window.__walkReplies[m.id] = m; } catch {} })`);
  let n = 0;
  const call = async (method, params, wait = 60_000) => {
    const id = `walk-${n += 1}`;
    await page.eval(`window.__walkSocket.send(${JSON.stringify(JSON.stringify({ jsonrpc: "2.0", id, method, params }))})`);
    await page.waitFor(`!!window.__walkReplies[${JSON.stringify(id)}]`, wait);
    return JSON.parse(await page.eval(`JSON.stringify(window.__walkReplies[${JSON.stringify(id)}])`));
  };

  const hosts = await call("hosts/list", {});
  const host = (hosts.result?.hosts ?? hosts.result ?? []).find((h) => h.state === "online");
  check(!!host, `the scratch host is online: ${JSON.stringify(hosts).slice(0, 300)}`);

  const added = await call("providers/add", {
    name: "Codespaces", kind: "commands", secrets: { GITHUB_TOKEN: token },
    commands: { preset: "codespaces-api", api: base, ssh: "walk@127.0.0.1 -p 9" },
  });
  check(!added.error, `added: ${JSON.stringify(added).slice(0, 400)}`);
  const summary = added.result ?? {};
  check(summary.machine === host?.id, `carried by the scratch host (${summary.machineName})`);
  check(!JSON.stringify(added).includes(token), "the answer holds no token");
  check(seen.some((s) => s.method === "GET" && s.bearer), "the host listed the codespaces with the token");

  const linked = await call("hosts/link", { host: host.id, provider: summary.id, workspace: "fuzzy-space" });
  check(!linked.error, `linked: ${JSON.stringify(linked).slice(0, 300)}`);

  const started = await call("hosts/start", { host: host.id });
  check(!started.error, `start: ${JSON.stringify(started).slice(0, 200)}`);
  for (let i = 0; i < 100 && state !== "Available"; i += 1) await new Promise((r) => setTimeout(r, 100));
  check(state === "Available" && seen.some((s) => s.url.endsWith("/start") && s.bearer), "started through the host, with the token");

  // The stop closes the host's uplink, as a stopped workspace's would be, and it joins again.
  const stopped = await call("hosts/stop", { host: host.id });
  check(!stopped.error, `stop: ${JSON.stringify(stopped).slice(0, 200)}`);
  for (let i = 0; i < 100 && state !== "Shutdown"; i += 1) await new Promise((r) => setTimeout(r, 100));
  check(state === "Shutdown" && seen.some((s) => s.url.endsWith("/stop") && s.bearer), "stopped through the host, with the token");

  await page.goto(`${new URL(webURL).origin}/#/settings`);
  await page.waitFor(`document.querySelector("[aria-labelledby=settings-providers]")?.textContent.includes("Codespaces")`, 30_000);
  await page.eval(`document.querySelector("[aria-labelledby=settings-providers]").scrollIntoView()`);
  await page.shot(`${out}/web-providers.png`);
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) await page.shot(`${out}/web-failed.png`).catch(() => undefined);
} finally {
  await chrome.close();
  api.close();
}
console.log(`TOKEN=${token}`);
console.log(`requests: ${JSON.stringify(seen)}`);
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
