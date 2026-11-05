// The #3416 walk: a Coder deployment (in a local container) as a machine provider, through its
// API (the coder-api preset), carried by the scratch Mac's host, from the web page. Adds the
// provider, lists its workspace, adds the workspace as a machine (the control plane installs
// Agents over the coder.<name> ssh host that `coder config-ssh` wrote), then stops and starts it
// through the provider. Reads the token from CODER_SESSION_TOKEN, never prints it.
//
//   CODER_SESSION_TOKEN=… node Web/test/walk/coder3416.mjs <WEB_URL> <browser code> <coder url> <workspace> <out dir> [step]
//
// step is "add" (the provider and Add as Machine), "turn" (a Claude turn on the machine, with
// this Mac's sign-in lent as the window lends it), "cycle" (Stop and Start) or "all". AGENT=<id>
// follows a turn already started. The set-up is in specs/691-workspace-providers/walks/3416-coder.md.

import { launch } from "./cdp.mjs";

const [webURL, code, coderURL, workspace, out, step = "all"] = process.argv.slice(2);
const token = process.env.CODER_SESSION_TOKEN;
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const chrome = await launch({ profile: `/tmp/w3416-chrome-${process.pid}` });
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
  await page.eval(`window.__walkReplies = {}; window.__walkSocket.addEventListener("message", (e) => { try { const m = JSON.parse(e.data); const r = m.m ?? m; if (String(r.id).startsWith("walk-")) window.__walkReplies[r.id] = r; } catch {} })`);
  let n = 0;
  const call = async (method, params, wait = 300_000, host) => {
    const id = `walk-${n += 1}`;
    const message = { jsonrpc: "2.0", id, method, params };
    const line = host ? { h: host, m: message } : { m: message };
    await page.eval(`window.__walkSocket.send(${JSON.stringify(JSON.stringify(line))})`);
    await page.waitFor(`!!window.__walkReplies[${JSON.stringify(id)}]`, wait);
    return JSON.parse(await page.eval(`JSON.stringify(window.__walkReplies[${JSON.stringify(id)}])`));
  };
  const providers = async () => { const r = (await call("providers/list", {})).result; return r?.providers ?? r ?? []; };
  const coder = async () => (await providers()).find((p) => p.name === "Coder");
  const hosts = async () => { const h = await call("hosts/list", {}); return h.result?.hosts ?? h.result ?? []; };
  const settings = async (name) => {
    await page.goto(`${new URL(webURL).origin}/#/settings`);
    await page.waitFor(`document.querySelector("[aria-labelledby=settings-providers]")?.textContent.includes("Coder")`, 30_000);
    await page.eval(`document.querySelector("[aria-labelledby=settings-providers]").scrollIntoView()`);
    await sleep(1500);
    await page.shot(`${out}/web-${name}.png`);
  };
  const stateOf = async () => (await coder())?.workspaces?.find((w) => w.name === workspace)?.state;
  const waitState = async (want, seconds) => {
    for (let i = 0; i < seconds / 5; i += 1) {
      await call("providers/refresh", { id: (await coder()).id }).catch(() => undefined);
      const s = await stateOf();
      if (s === want) return s;
      await sleep(5000);
    }
    return stateOf();
  };

  if (step === "add" || step === "all") {
    const machines = await hosts();
    const mac = machines.find((h) => h.name !== workspace && h.state === "online");
    check(!!mac, `the scratch host is online: ${mac?.name}`);
    // Again on a second run: the provider is there already.
    const added = (await coder()) ? { result: await coder() } : await call("providers/add", {
      name: "Coder", kind: "commands", secrets: { CODER_SESSION_TOKEN: token },
      commands: { preset: "coder-api", url: coderURL },
    });
    check(!added.error, `added: ${JSON.stringify(added).slice(0, 400)}`);
    check(added.result?.machine === mac?.id, `carried by the scratch host (${added.result?.machineName})`);
    check(!JSON.stringify(added).includes(token), "the answer holds no token");
    const provider = await coder();
    console.log(`provider: ${JSON.stringify(provider).slice(0, 800)}`);
    const ws = provider?.workspaces?.find((w) => w.name === workspace);
    check(!!ws, `lists the workspace ${workspace}: ${JSON.stringify(ws)}`);
    await settings("provider-added");

    // Add as Machine…, as the page does it: install over coder.<name>, then link on join.
    const destination = `coder.${workspace}`;
    const there = (await hosts()).find((h) => h.name === workspace && h.state === "online");
    let trust;
    let installed = there ? { result: { name: workspace } } : await call("hosts/install", { destination, name: workspace }, 600_000);
    // A second run links the machine the first installed, with the key the first trusted.
    if (there) trust = process.env.TRUST;
    if (installed.result?.needsTrust) {
      trust = installed.result.needsTrust;
      console.log(`needsTrust ${installed.result.needsTrust}`);
      installed = await call("hosts/install", { destination, name: workspace, trust: installed.result.needsTrust }, 600_000);
    }
    check(!installed.error, `installed: ${JSON.stringify(installed).slice(0, 400)}`);
    let joined;
    for (let i = 0; i < 60 && !joined; i += 1) {
      joined = (await hosts()).find((h) => h.name === (installed.result?.name || workspace) && h.state === "online");
      if (!joined) await sleep(2000);
    }
    check(!!joined, `the workspace joined: ${JSON.stringify(joined).slice(0, 300)}`);
    if (joined) {
      const linked = await call("hosts/link", { host: joined.id, provider: provider.id, workspace: ws.id, ...(trust ? { trust } : {}) });
      check(!linked.error, `linked: ${JSON.stringify(linked).slice(0, 300)}`);
    }
    await settings("machine-added");
  }

  if (step === "turn" || step === "all") {
    // A turn on the machine, sent through the control plane as the clients send it.
    const host = (await hosts()).find((h) => h.name === workspace && h.state === "online");
    check(!!host, `the machine ${workspace} is online`);
    const mac = (await hosts()).find((h) => h.name !== workspace && h.state === "online");
    const lent = process.env.AGENT ? {} : await call("hosts/lendSignIn", { host: host.id, from: mac.id, runtime: "claude", allowed: true });
    check(!lent.error, `Claude's sign-in lent from ${mac.name}: ${JSON.stringify(lent).slice(0, 200)}`);
    // Then as the window's Lending.swift: the Mac's host grants its relay, the server is offered it.
    const grant = process.env.AGENT ? { result: {} } : await call("relay/grant", { runtime: "claude" }, 30_000, mac.id);
    check(!grant.error, `relay granted: ${grant.error ? JSON.stringify(grant.error) : "yes"}`);
    const offer = process.env.AGENT ? {} : await call("relay/offer", { runtime: "claude", socketPath: "tunnel",
      caCertificate: grant.result?.caCertificate, standIn: grant.result?.standIn }, 30_000, host.id);
    check(!offer.error, `relay offered: ${JSON.stringify(offer).slice(0, 200)}`);
    const folder = "file:///home/coder/src/hello";
    const added = await call("folders/add", { folder }, 60_000, host.id);
    check(!added.error, `folder: ${JSON.stringify(added).slice(0, 200)}`);
    const started = process.env.AGENT ? { result: process.env.AGENT } : await call("agents/start", { runtimeID: "claude", cwd: folder,
      prompt: "Read README.md and say in one line what it is, then run uname -m and say what it printed." }, 180_000, host.id);
    check(!started.error, `started: ${JSON.stringify(started).slice(0, 300)}`);
    const agentID = typeof started.result === "string" ? started.result : started.result?.id;
    let state;
    for (let i = 0; i < 90; i += 1) {
      const pending = (await call("permissions/pending", {}, 30_000, host.id)).result;
      for (const p of pending?.permissions ?? pending ?? []) {
        const option = (p.options ?? []).find((o) => /allow/i.test(o.optionID ?? o.id ?? "")) ?? p.options?.[0];
        console.log(`permission: ${p.toolCall?.title ?? p.title ?? p.id} -> ${option?.optionID ?? option?.id}`);
        await call("permissions/answer", { permissionID: p.id, optionID: option?.optionID ?? option?.id }, 30_000, host.id);
      }
      const list = (await call("agents/list", { includeArchived: false }, 30_000, host.id)).result;
      const agent = (list?.agents ?? list ?? []).find((a) => a.id === agentID);
      state = agent?.state;
      if (state === "finished" || state === "stopped") break;
      await sleep(2000);
    }
    check(state === "finished", `the turn ended: ${state}`);
    const transcript = await call("agents/transcript", { agentID, from: 0, limit: 100 }, 60_000, host.id);
    const text = JSON.stringify(transcript.result ?? transcript.error);
    console.log(`transcript tail: ${text.slice(-1200)}`);
    check(/aarch64/.test(text), "the agent ran uname -m on the workspace (aarch64)");
    await page.goto(`${new URL(webURL).origin}/#/agents`);
    await sleep(4000);
    await page.shot(`${out}/web-turn.png`);
  }

  if (step === "cycle" || step === "all") {
    const host = (await hosts()).find((h) => h.name === workspace);
    check(!!host, `the machine ${workspace}: ${JSON.stringify(host).slice(0, 300)}`);
    const stopped = await call("hosts/stop", { host: host.id, confirmRunning: true });
    check(!stopped.error, `stop: ${JSON.stringify(stopped).slice(0, 300)}`);
    check(await waitState("stopped", 180) === "stopped", `stopped through the provider (${await stateOf()})`);
    await settings("stopped");
    let offline;
    for (let i = 0; i < 60 && !offline; i += 1) {
      offline = (await hosts()).find((h) => h.id === host.id && h.state !== "online");
      if (!offline) await sleep(2000);
    }
    check(!!offline, `the machine went offline: ${offline?.state}`);

    const started = await call("hosts/start", { host: host.id });
    check(!started.error, `start: ${JSON.stringify(started).slice(0, 300)}`);
    check(await waitState("running", 300) === "running", `started through the provider (${await stateOf()})`);
    let back;
    for (let i = 0; i < 90 && !back; i += 1) {
      back = (await hosts()).find((h) => h.id === host.id && h.state === "online");
      if (!back) await sleep(2000);
    }
    check(!!back, `the machine is back online: ${JSON.stringify(back).slice(0, 200)}`);
    await settings("started");
  }
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.message}`);
  if (page) await page.shot(`${out}/web-failed.png`).catch(() => undefined);
} finally {
  await chrome.close();
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
