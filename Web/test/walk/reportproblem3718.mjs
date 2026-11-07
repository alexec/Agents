// The #3718 walk: Report a Problem… from the person menu, on a scratch control plane. The form, then
// the issue's text as the host made it (tokens and home folders cut out), and the GitHub link it opens.
// Each shot is the dialog alone; `<name>.rect.json` beside it is the dialog's box, for a crop.
//
//   node Web/test/walk/reportproblem3718.mjs <WEB_URL> <browser code> <out dir>

import { writeFileSync } from "node:fs";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
let failed = 0;
const check = (ok, line) => { if (!ok) failed += 1; console.log(`${ok ? "ok  " : "FAIL"} ${line}`); };
const pause = (ms) => new Promise((done) => setTimeout(done, ms));

// One profile for every run, so a browser the window approved once stays in the lock.
const chrome = await launch({ profile: "/tmp/rp3718-chrome" });
const shot = async (page, name) => {
  await pause(600);
  await page.shot(`${out}/${name}.png`);
  const rect = await page.eval(`(() => { const r = document.querySelector("dialog.sheet").getBoundingClientRect();
    return JSON.stringify({ x: r.x, y: r.y, width: r.width, height: r.height, scale: devicePixelRatio }); })()`);
  writeFileSync(`${out}/${name}.rect.json`, rect);
};
const fill = (label, text) => `(() => { const l = [...document.querySelectorAll(".report-problem label")].find((x) => x.textContent.startsWith(${JSON.stringify(label)}));
  const t = l.querySelector("textarea"); t.value = ${JSON.stringify(text)}; t.dispatchEvent(new Event("input", { bubbles: true })); })()`;
try {
  const page = await chrome.page(webURL, { width: 1280, height: 860 });
  await page.waitFor(`document.querySelector("textarea") || document.querySelector(".person-button")`, 30_000);
  if (await page.eval(`!!document.querySelector("textarea")`)) {
    await page.focus("textarea");
    await page.type(code);
    await page.press("Connect");
  }
  await page.waitFor(`document.querySelector(".person-button")`, 30_000);
  // A new browser joins the machine lock (#3490): the window approves it meanwhile.
  await page.eval(`location.hash = "#/agents"`);
  for (let i = 0; i < 30 && !(await page.eval(`document.body.innerText.includes("Approve this device")`)); i += 1) await pause(1000);
  if (await page.eval(`document.body.innerText.includes("Approve this device")`)) {
    console.log("approve this browser in the window: press its Compare Digits");
    await page.waitFor(`!!document.querySelector(".lock-join-own code") || !document.body.innerText.includes("Approve this device")`, 300_000);
    console.log("this browser's digits:", await page.eval(`document.querySelector(".lock-join-own code")?.textContent ?? "none"`));
    await page.waitFor(`!document.body.innerText.includes("Approve this device")`, 300_000);
    await page.eval(`[...document.querySelectorAll("button")].find((b) => b.textContent.trim() === "OK")?.click()`);
  }

  await page.eval(`document.querySelector(".person-button").click()`);
  await page.waitFor(`[...document.querySelectorAll(".person-list [role=menuitem]")].some((b) => b.textContent === "Report a Problem…")`);
  check(true, "the person menu has Report a Problem…");
  await page.eval(`[...document.querySelectorAll(".person-list [role=menuitem]")].find((b) => b.textContent === "Report a Problem…").click()`);
  await page.waitFor(`document.querySelector("dialog.sheet .report-problem")`);
  check(await page.eval(`document.querySelector(".report-problem button[type=submit]").disabled`), "Review… waits for what happened");

  await page.eval(fill("What happened", "The chat stopped scrolling after a long turn in /Users/someone/work"));
  await page.eval(fill("What you expected", "The chat to follow the newest message"));
  await shot(page, "web-form");

  await page.eval(`document.querySelector(".report-problem button[type=submit]").click()`);
  await page.waitFor(`document.querySelector(".report-problem .report-body, .report-problem .failure")`, 20_000);
  if (await page.eval(`!!document.querySelector(".report-problem .failure")`)) {
    await shot(page, "web-failure");
    throw new Error(await page.text(".report-problem .failure"));
  }
  const body = await page.text(".report-problem .report-body");
  check(body.includes("~/work") && !body.includes("/Users/someone"), "the home folder is cut out");
  check(body.includes("- Client: Web page") && body.includes("- Agents Host: "), "the versions are added");
  check(body.includes("Recent log lines"), "the log lines are added");
  await shot(page, "web-review");

  check(await page.eval(`[...document.querySelectorAll(".report-problem button")].some((b) => b.textContent.trim() === "Open on GitHub")`), "Open on GitHub is there");
  await page.eval(`[...document.querySelectorAll(".report-problem button")].find((b) => b.textContent.trim() === "Back").click()`);
  await page.waitFor(`document.querySelector(".report-problem textarea")`);
  check(await page.eval(`document.querySelector(".report-problem textarea").value.startsWith("The chat stopped")`), "Back keeps what was written");
} finally {
  await chrome.close();
}
console.log(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
