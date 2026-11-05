// Web Push in a real Chrome, through its real push service (#3418).
//
//   node Web/test/walk/webpush3418.mjs <WEB_URL> <browser code> <out dir> [subscribe|wait]
//
// Headless Chrome on a throwaway profile with its background networking on, so it reaches
// Google's push service. It pairs with the code, allows notifications as a press in
// Settings would, and waits for the page to say Web Push is on. With `wait` it then closes
// the page, keeps Chrome and its service worker running, and waits up to ten minutes for
// one push, read from the worker's shown notifications. Writes subscription.json (the
// endpoint's host only) and, with wait, pushed.json.

import { writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, mode = "subscribe"] = process.argv.slice(2);
const origin = new URL(webURL).origin;
const chrome = await launch({ profile: `${out}/chrome`, push: true });
try {
  await chrome.send("Browser.grantPermissions", { origin, permissions: ["notifications"] });
  const page = await chrome.page(webURL, { width: 1300, height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".top-bar")`, 20_000);
  await page.eval(`location.hash = "#/settings"`);
  await sleep(1000);
  const subscribed = `navigator.serviceWorker.getRegistration("/").then((r) => r?.pushManager.getSubscription()).then((s) => s?.endpoint ?? "")`;
  let endpoint = "";
  for (let i = 0; i < 60 && !endpoint; i++) {
    endpoint = await page.eval(subscribed).catch(() => "");
    if (!endpoint) await sleep(500);
  }
  await page.eval(`document.getElementById("settings-notifications")?.scrollIntoView({ block: "center" })`);
  await sleep(300);
  await page.shot(`${out}/web-chrome-settings.png`);
  const host = endpoint ? new URL(endpoint).host : "";
  console.log("subscribed", host || "no subscription", page.errors.slice(-3), page.console.slice(-5));
  writeFileSync(`${out}/subscription.json`, JSON.stringify({ host }));
  if (!endpoint || mode !== "wait") process.exit(endpoint ? 0 : 1);

  // The page closed, as a person who went away: only the service worker is left to show it.
  const { targetInfos } = await chrome.send("Target.getTargets");
  const worker = targetInfos.find((t) => t.type === "service_worker");
  await chrome.send("Target.closeTarget", { targetId: page.targetId });
  if (!worker) throw new Error("no service worker");
  const { sessionId } = await chrome.send("Target.attachToTarget", { targetId: worker.targetId, flatten: true });
  await chrome.send("Runtime.enable", {}, sessionId);
  console.log("waiting for a push");
  for (let i = 0; i < 600; i++) {
    const { result } = await chrome.send("Runtime.evaluate", {
      expression: `self.registration.getNotifications().then((n) => JSON.stringify(n.map((x) => ({ title: x.title, body: x.body, tag: x.tag }))))`,
      awaitPromise: true, returnByValue: true,
    }, sessionId);
    const shown = JSON.parse(result.value ?? "[]");
    if (shown.length) {
      console.log("pushed", shown);
      writeFileSync(`${out}/pushed.json`, JSON.stringify(shown));
      process.exit(0);
    }
    await sleep(1000);
  }
  throw new Error("no push in ten minutes");
} finally {
  await chrome.close();
}
