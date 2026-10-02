// The #119 walk: an agent whose worktree was removed. Its row and chat say Folder is missing, a
// send is refused with the folder named and the words kept in the prompt, and Continue in the
// project folder opens a successor. Needs a scratch root with such an agent in project "work".
//
//   node Web/test/walk/foldergone.mjs <WEB_URL> <browser code> <out dir> [width]

import { launch } from "./cdp.mjs";

const [webURL, code, out, width = "1440"] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/119-foldergone-chrome-${process.pid}` });
const typed = "Please carry on from where you were";
try {
  const page = await chrome.page(webURL, { width: Number(width), height: 900 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".projects .row")`);
  await page.eval(`[...document.querySelectorAll(".projects .row")].find((e) => e.textContent.includes("work"))?.click()`);
  await page.waitFor(`[...document.querySelectorAll(".sessions .session")].some((e) => e.textContent.includes("Folder is missing"))`, 30_000);
  console.log(`row: ${await page.eval(`[...document.querySelectorAll(".sessions .session")].find((e) => e.textContent.includes("Folder is missing")).textContent`)}`);
  await page.eval(`[...document.querySelectorAll(".sessions .session")].find((e) => e.textContent.includes("Folder is missing")).click()`);
  await page.waitFor(`document.querySelector(".missing-folder-strip")`);
  console.log(`strip: ${await page.text(".missing-folder-strip")}`);
  await page.shot(`${out}/119-web-strip-${width}.png`);

  await page.focus(`textarea[aria-label="Prompt"]`);
  await page.type(typed);
  await page.press("Send");
  await page.waitFor(`document.querySelector(".folder-gone")`, 20_000);
  await new Promise((done) => setTimeout(done, 300));
  console.log(`refusal: ${await page.text(".folder-gone")}`);
  console.log(`kept: ${await page.eval(`document.querySelector('textarea[aria-label="Prompt"]').value`)}`);
  await page.shot(`${out}/119-web-refused-${width}.png`);

  const before = await page.eval(`location.hash`);
  await page.eval(`[...document.querySelectorAll(".folder-gone button")].find((b) => b.textContent.includes("Continue in the project folder")).click()`);
  await page.waitFor(`location.hash !== ${JSON.stringify(before)} && location.hash.includes("/s/")`, 30_000);
  await page.waitFor(`!document.querySelector(".missing-folder-strip")`, 20_000);
  await new Promise((done) => setTimeout(done, 1500));
  console.log(`successor: ${await page.eval(`location.hash`)}`);
  console.log(`title: ${await page.text(".chat .column-head h1")}`);
  await page.shot(`${out}/119-web-successor-${width}.png`);
} finally {
  await chrome.close();
}
