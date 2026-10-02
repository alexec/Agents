// The US1 walk (071 quickstart §2, T035): pair a browser on a scratch root, restart it, two
// tabs, a spent and an expired code, promote and demote, forgotten from Settings, Forget
// This Browser… Settings' calls are made by walk/operator.mjs over TLS, as the window does.
//
//   node Web/test/walk/us1.mjs <WEB_URL> <CONTROL_URL> <operator code> <expired code> <out dir>

import { writeFileSync } from "node:fs";
import { launch } from "./cdp.mjs";
import { Operator } from "./operator.mjs";

const [webURL, controlURL, operatorCode, expiredCode, out] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
// A throwaway profile, outside the repository.
const profile = `/tmp/071-us1-chrome-${process.pid}`;

const op = await Operator.pair(controlURL, operatorCode);
const newCode = async () => (await op.call("clients/startPairing", { kind: "browser" })).text;
const browsers = async () => (await op.call("clients/list")).filter((c) => c.kind === "browser");

async function pairIn(page, code) {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.eval(`document.querySelector("textarea").select()`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
}

let chrome = await launch({ profile });
say(`browser: ${await chrome.version()}`);
let a = await chrome.page(webURL);
await a.waitFor(`document.querySelector("textarea")`);
say(`1. no key: the page shows ${JSON.stringify((await a.text()).split("\n")[0])} and only pairing`);
await a.shot(`${out}/us1-1-pairing.png`);

// Scenario 3: an expired code, then a spent one.
await pairIn(a, expiredCode);
await a.waitFor(`document.querySelector("[role=alert]")`);
say(`3a. expired code: ${await a.text("[role=alert]")}`);
await a.shot(`${out}/us1-3-expired.png`);

// Scenario 2: pairing with a code.
const code = await newCode();
await pairIn(a, code);
await a.waitFor(`document.body.innerText.includes("on this Mac")`);
const listed = await browsers();
say(`2. paired: ${JSON.stringify(await a.text(".identity"))}; Settings lists ${JSON.stringify(listed.map((c) => `${c.name} · ${c.kind}`))}`);
await a.shot(`${out}/us1-2-paired.png`);
const id = listed[0].id;

const spent = await chrome.page(webURL, { incognito: true });
await pairIn(spent, code);
await spent.waitFor(`document.querySelector("[role=alert]")`);
say(`3b. spent code: ${await spent.text("[role=alert]")}`);

// Scenario 4: a full restart of the browser; and two tabs at once.
await chrome.close();
chrome = await launch({ profile });
a = await chrome.page(webURL);
await a.waitFor(`document.body.innerText.includes("on this Mac")`);
say(`4. after a full restart: ${JSON.stringify(await a.text(".identity"))}, with no code`);
const tab2 = await chrome.page(webURL);
await tab2.waitFor(`document.body.innerText.includes("on this Mac")`);
say("   a second tab connects too, on the same key");

// Scenario 5: forgotten in Settings; within 2 s the page says so and drops its key.
const started = Date.now();
await op.call("clients/forget", { client: id });
await a.waitFor(`document.body.innerText.includes("This browser was forgotten")`, 2000);
const took = Date.now() - started;
await tab2.waitFor(`document.querySelector("textarea")`, 2000);
const dbs = await a.eval(`indexedDB.databases().then(d => d.map(x => x.name))`);
say(`5. forgotten in Settings: the page said so after ${took} ms; both tabs show pairing; IndexedDB holds ${JSON.stringify(dbs)}`);
await a.shot(`${out}/us1-5-forgotten.png`);

// Scenario 6: paired again, then Forget This Browser… in the page.
await pairIn(a, await newCode());
await a.waitFor(`document.body.innerText.includes("on this Mac")`);
await a.press("Forget This Browser…");
await a.shot(`${out}/us1-6-confirm.png`);
await a.press("Forget");
await a.waitFor(`document.querySelector("textarea")`);
await new Promise((r) => setTimeout(r, 300));
say(`6. Forget This Browser…: the page shows pairing (${(await a.text()).includes("was forgotten") ? "with" : "without"} the forgotten line); Settings lists ${(await browsers()).length} browsers`);

const off = [...a.requests, ...tab2.requests].filter((r) => !r.startsWith(webURL));
say(`checks: errors ${JSON.stringify([...a.errors, ...tab2.errors, ...spent.errors])}; requests off the page's origin ${JSON.stringify(off)}; console ${JSON.stringify([...new Set(a.console)])}`);
await chrome.close();
op.stop();
writeFileSync(`${out}/us1-notes.txt`, notes.join("\n") + "\n");
