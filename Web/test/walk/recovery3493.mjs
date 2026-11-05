// The #3493 walk: the recovery key. The window made the root and its recovery key when it paired, and
// showed the key once. A new browser asks to join; with no other device to approve it, it types the
// recovery key (a typo first) and is in the lock. A second new browser, with no key either, starts a new
// lock, and shows its own key once. Shots go to <out>/web-<state>.png.
//
//   node Web/test/walk/recovery3493.mjs <WEB_URL> <browser code> <browser code> <recovery key> <out dir>

import { launch } from "./cdp.mjs";

const [webURL, firstCode, secondCode, key, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };

/** Takes a shot with this Mac's own name in the page's words given a scratch one: the repo is public. */
async function shot(page, path) {
  await page.eval(`(() => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      n.nodeValue = n.nodeValue.replace(/[A-Z][a-z]+[’']?s[ -]MacBook[ -]Air(\\.local)?|[A-Z][a-z]+s-MacBook-Air(\\.local)?/g, "Sam’s MacBook");
    }
  })()`);
  await page.shot(path);
}

async function paired(chrome, code) {
  const page = await chrome.page(webURL, { width: 1280, height: 860 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.body.innerText.includes("Overview")`, 30_000);
  await page.eval(`location.hash = "#/agents"`);
  await page.waitFor(`document.body.innerText.includes("Approve this device on another of your devices.")`, 30_000);
  return page;
}

async function typeKey(page, text) {
  await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
  await page.type(text);
  await page.press("Use");
}

const chrome = await launch({ profile: `/tmp/run-lk3493-chrome-${process.pid}` });
// The second browser has a profile of its own: a new device.
const other = await launch({ profile: `/tmp/run-lk3493-chrome2-${process.pid}` });
try {
  const first = await paired(chrome, firstCode);
  await shot(first, `${out}/web-asking.png`);
  await first.press("Use Recovery Key");
  await first.waitFor(`document.querySelector("#lock-recovery-key")`);
  await typeKey(first, "RKB4-J2JQ-6XZY");
  await first.waitFor(`document.body.innerText.includes("Check it for a typo")`, 10_000);
  check(true, "a typo is said before anything is sent");
  await shot(first, `${out}/web-recovery-typo.png`);
  await typeKey(first, key);
  await first.waitFor(`!document.body.innerText.includes("Approve this device on another of your devices.")`, 30_000);
  check(true, "the recovery key added this browser to the lock");
  await shot(first, `${out}/web-recovered.png`);

  const second = await paired(other, secondCode);
  await second.press("Use Recovery Key");
  await second.waitFor(`document.querySelector("#lock-recovery-key")`);
  await second.eval(`window.confirm = () => true`);
  await second.press("Start a New Lock");
  await second.waitFor(`document.body.innerText.includes("Save your recovery key.")`, 30_000);
  const shown = await second.eval(`document.querySelector(".recovery-key")?.innerText`);
  check(/^([0-9A-Z]{4}-){7}[0-9A-Z]{4}$/.test(shown ?? "") && shown !== key, `a new lock shows a new key: ${shown}`);
  await shot(second, `${out}/web-recovery-key.png`);
  await second.press("I Saved It");
  await second.waitFor(`!document.body.innerText.includes("Save your recovery key.")`, 10_000);
  check(true, "I Saved It puts the key away");
  await first.eval(`location.reload()`);
  await first.waitFor(`document.body.innerText.includes("The lock changed in a way your devices did not sign.")`, 30_000);
  check(true, "the browser that pinned the old lock refuses the new one");
  await shot(first, `${out}/web-old-lock.png`);
  const errors = [...(first.errors ?? []), ...(second.errors ?? [])].filter((e) => !e.includes("Autofocus processing was blocked"));
  check(errors.length === 0, `no errors on the pages: ${errors.join(" | ")}`);
} catch (error) {
  failed += 1;
  console.log(`FAIL ${error.stack ?? error}`);
} finally {
  await chrome.close();
  await other.close();
}
process.exit(failed ? 1 : 0);
