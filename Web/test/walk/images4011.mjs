// Images on a Work page on the web (#4011): on a run-app root whose folder's origin is example/shop on
// the fixture GitHub (forge4010-github.py, AGENTS_TEST_GITHUB_URL) and whose host has a GitHub
// connection, open issue #50's page; see the body's image drawn from forge/image (a blob: src), the
// example.com image left as its alternative text, and the comment's image drawn; open the viewer, zoom
// in with +, close it with Esc, with a click on the backdrop and with Done. Screenshots into <out dir>.
//
//   node Web/test/walk/images4011.mjs <WEB_URL> <browser code> <out dir>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-img4011-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 900 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const open = `document.querySelector("dialog.image-viewer")?.open === true`;
const level = () => page.eval(`parseInt(document.querySelector("dialog.image-viewer .zoom-level")?.textContent ?? "0", 10)`);
const pictures = () => page.eval(`[...document.querySelectorAll("img.page-picture")].map((i) => ({ alt: i.alt, src: i.src.slice(0, 5),
  comment: !!i.closest(".work-comment, .comment, [class*=comment]") }))`);
const clickAt = async (x, y) => {
  for (const type of ["mousePressed", "mouseReleased"]) {
    await page.cdp("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 });
  }
};
const openFirst = async () => {
  await page.eval(`document.querySelector("button.page-picture-open").click()`);
  await page.waitFor(open, 10_000);
  await sleep(600);
};

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#50")`);
  await page.waitFor(`document.querySelectorAll("img.page-picture").length >= 2`, 30_000).catch(() => {});
  await sleep(2000);
  const drawn = await pictures();
  console.log(`pictures: ${JSON.stringify(drawn)}`);
  ok("the body's image is drawn from a blob:", drawn.some((p) => p.alt.includes("cut off") && p.src === "blob:"));
  const placeholders = await page.eval(`[...document.querySelectorAll("span.image-placeholder")].map((s) => s.textContent.trim())`);
  ok(`the example.com image stays its alternative text: ${JSON.stringify(placeholders)}`, placeholders.some((t) => t.includes("From another site")));
  ok("the comment's image is drawn from a blob:", drawn.some((p) => p.alt.includes("phone") && p.src === "blob:"));
  await page.shot(`${out}/web-page.png`);

  await page.eval(`[...document.querySelectorAll("img.page-picture")].find((i) => i.alt.includes("phone"))?.scrollIntoView({ block: "center" })`);
  await sleep(500);
  await page.shot(`${out}/web-comment.png`);
  await page.eval(`scrollTo(0, 0); document.querySelector("main, .page, .work-page")?.scrollTo?.(0, 0)`);

  await openFirst();
  ok("a click opens dialog.image-viewer", await page.eval(open));
  const caption = await page.eval(`document.querySelector("dialog.image-viewer .caption")?.textContent`);
  ok(`the bar has the alternative text: ${caption}`, caption?.includes("cut off"));
  const fitted = await level();
  ok(`the image is fitted at ${fitted}%`, fitted > 0);
  await page.shot(`${out}/web-viewer.png`);

  await page.press("Zoom In");
  await sleep(300);
  await page.press("Zoom In");
  await sleep(500);
  const zoomed = await level();
  ok(`+ zooms in: ${fitted}% to ${zoomed}%`, zoomed > fitted);
  await page.shot(`${out}/web-viewer-zoomed.png`);

  await page.key("Escape");
  await sleep(500);
  ok("Esc closes the viewer", !(await page.eval(open)));

  await openFirst();
  await clickAt(5, 5);
  await sleep(500);
  ok("a click on the backdrop closes the viewer", !(await page.eval(open)));

  await openFirst();
  await page.press("Done");
  await sleep(500);
  ok("Done closes the viewer", !(await page.eval(open)));

  console.log(`console: ${JSON.stringify(page.console)}`);
  console.log(`errors: ${JSON.stringify(page.errors)}`);
  ok("no CSP violation", !page.errors.some((e) => /Content Security Policy|CSP/i.test(e)));
} finally {
  await chrome.close();
}
