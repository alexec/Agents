// Azure DevOps in the Work pages (#3803): on a run-app root whose folder's remote is the fixture
// Azure DevOps's http://127.0.0.1:<port>/acme/Web%20Shop/_git/shop (.agents/skills/run-app/scripts/fake-azure-devops.py),
// with the host's Azure DevOps connection made at it, open Work ▸ Pull requests and see the
// repository's pull requests; open pull request #7 (its description as Markdown, its checks,
// Open on Azure DevOps, Rerun failed, Approve, Labels, Close) and write a comment; show its diff.
// Screenshots into <out dir>. The browser joins the scratch root's lock with the recovery key its
// window showed (RECOVERY_KEY), when it asks.
//
//   node Web/test/walk/work3803.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-ado3803-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const click = (text, scope = "button") => page.eval(`[...document.querySelectorAll(${JSON.stringify(scope)})].find((b) => b.textContent.trim() === ${JSON.stringify(text)}).click()`);
const rows = () => page.eval(`[...document.querySelectorAll(".work-row")].map((r) => r.textContent.replace(/\\s+/g, " ").trim())`);
const asked = `document.body.innerText.includes("Approve this device")`;

/** Joins the machine lock (#3490) with the recovery key, when the page asks (on Agents). */
async function joinLock() {
  await page.eval(`location.hash = "#/agents"`);
  for (let i = 0; i < 10 && !(await page.eval(asked)); i += 1) await sleep(1000);
  if (!await page.eval(asked)) return;
  await page.press("Use Recovery Key");
  await page.waitFor(`document.querySelector("#lock-recovery-key")`);
  await page.eval(`(() => { const f = document.querySelector("#lock-recovery-key"); f.focus(); f.select(); })()`);
  await page.type(process.env.RECOVERY_KEY ?? "");
  await page.press("Use");
  await page.waitFor(`!${asked}`, 30_000);
  await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  // What it read before it was in the lock was refused: read it all again.
  await page.eval(`location.reload()`);
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
}

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);
  await joinLock();

  await page.eval(`location.hash = "#/work/pr"`);
  await page.waitFor(`[...document.querySelectorAll(".work-row")].some((r) => r.textContent.includes("Pay with a saved card"))`, 30_000);
  const pulls = await rows();
  ok(`the Azure DevOps pull requests are listed: ${pulls.join(" | ")}`, pulls.some((r) => r.includes("Coupon field above the keyboard")));
  ok("its repository is a choice of the Repo filter", await page.eval(`[...document.querySelectorAll(".work-filters option")].some((o) => o.textContent.includes("acme/web shop/shop"))`));
  await sleep(400);
  await page.shot(`${out}/web-pulls.png`);

  await page.eval(`location.hash = "#/work/pr/" + encodeURIComponent("azuredevops:acme/web shop/shop#7")`);
  await page.waitFor(`[...document.querySelectorAll(".work-actions button")].some((b) => b.textContent === "Show Diff")`, 30_000);
  ok("the page has Rerun failed, Approve, Labels and Close", await page.eval(`(() => { const t = [...document.querySelectorAll(".work-actions button")].map((b) => b.textContent);
      return ["Rerun failed", "Approve", "Labels ▾", "Close"].every((x) => t.includes(x)); })()`));
  ok("Open on Azure DevOps", await page.eval(`[...document.querySelectorAll("a")].some((a) => a.textContent === "Open on Azure DevOps")`));
  ok("the description is Markdown, drawn", await page.eval(`[...document.querySelectorAll("strong")].some((b) => b.textContent === "saved cards")`));
  ok("the checks are one passing and shop-pr failing", await page.eval(`document.body.innerText.includes("1 passing, 1 failing") && document.body.innerText.includes("Failed: shop-pr")`));
  await page.focus(".work-comment-box textarea");
  await page.type("Written on the web page.");
  await click("Comment");
  await page.waitFor(`[...document.querySelectorAll(".work-comment")].some((c) => c.textContent.includes("Written on the web page."))`, 30_000);
  ok("the comment is on the page", true);
  await sleep(400);
  await page.shot(`${out}/web-pull.png`);

  await click("Show Diff");
  await page.waitFor(`document.querySelector(".view-diff-file")`, 30_000);
  ok("the diff says Open on Azure DevOps", await page.eval(`[...document.querySelectorAll("button")].some((b) => b.textContent === "Open on Azure DevOps")`));
  ok("the diff has both files", await page.eval(`["src/checkout.ts", "src/saved.ts"].every((p) => document.querySelector(\`.view-diff-file[data-path="\${p}"]\`))`));
  await sleep(400);
  await page.shot(`${out}/web-pull-diff.png`);
} catch (e) {
  await page.shot(`${out}/web-failed.png`);
  console.log(`at ${await page.eval("location.hash")}: ${(await page.text()).replace(/\s+/g, " ").slice(0, 400)}`);
  throw e;
} finally {
  await chrome.close();
}
