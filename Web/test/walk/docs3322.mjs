// Start Agent on a doc and the Docs section on Work's pages (#3322), on a run-app root whose folder is
// on the fixture GitHub (forge3322-github.py, AGENTS_TEST_GITHUB_URL) and holds specs/gift-cards/spec.md.
// A doc's page has Start Agent ▾ with its three starts; Build this opens the new-session form in the
// doc's folder, its prompt the doc's ref and its label doc:<short form>. With [issue], issue #50's page
// has a Docs section: the spec its body names, then the docs like its title. Screenshots into <out dir>.
//
//   node Web/test/walk/docs3322.mjs <WEB_URL> <browser code> <out dir> [issue]

import { hostname } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, issue] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/run-docs3322-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 860 });
const ok = (what, cond) => { console.log(`${cond ? "PASS" : "FAIL"} ${what}`); if (!cond) process.exitCode = 1; };
const has = (text) => `document.body.textContent.includes(${JSON.stringify(text)})`;
const text = (sel) => page.eval(`[...document.querySelectorAll(${JSON.stringify(sel)})].map((e) => e.textContent.trim())`);
// The repo is public: this Mac's own name leaves the page before each shot.
const scrub = () => page.eval(`(() => { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n; (n = w.nextNode());) n.nodeValue = n.nodeValue.split(${JSON.stringify(hostname())}).join("scratch-mac"); })()`);
const shot = async (name) => { await scrub(); await page.shot(`${out}/${name}.png`); };
const spec = "github:example/shop/doc/specs/gift-cards/spec.md";

try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".nav-item")`, 30_000);

  if (issue) {
    await page.eval(`location.hash = "#/work/issue/" + encodeURIComponent("github:example/shop#50")`);
    await page.waitFor(`document.querySelector(".work-docs .work-doc-row")`, 30_000);
    await sleep(1500);
    const rows = await text(".work-docs .work-doc-row");
    ok(`the Docs section names the spec first: ${rows.join(" | ")}`, rows[0]?.startsWith("specs/gift-cards/spec.md"));
    ok("then the docs like its title", rows.length > 1 && (await page.eval(has("Like it"))));
    await page.eval(`document.querySelector(".work-docs").scrollIntoView({ block: "center" })`);
    await shot("web-work-docs");
    await page.eval(`document.querySelector(".work-docs .work-doc-row").click()`);
    await page.waitFor(`location.hash.startsWith("#/docs/") && ${has("Start Agent")}`, 20_000);
    ok("a row opens the doc's page", decodeURIComponent((await page.eval("location.hash")).slice(7)) === spec);
  } else {
    await page.eval(`location.hash = "#/docs/" + encodeURIComponent(${JSON.stringify(spec)})`);
  }

  await page.waitFor(`${has("Start Agent")} && ${has("A refund puts the money back")}`, 30_000);
  await sleep(1000);
  await shot("web-doc-page");
  await page.press("Start Agent ▾");
  await page.waitFor(`document.querySelector(".context-menu")`);
  const items = await text(".context-menu [role=menuitem]");
  ok(`the menu has the three starts: ${items.join(" | ")}`, items.join("|") === "Build this|Review this|Ask about this");
  await shot("web-start-menu");
  await page.eval(`[...document.querySelectorAll(".context-menu [role=menuitem]")].find((b) => b.textContent === "Build this").click()`);
  await page.waitFor(`[...document.querySelectorAll("textarea")].some((t) => t.value.includes(${JSON.stringify(spec)}))`, 20_000);
  ok("Build this fills the prompt with the doc's ref", true);
  await sleep(800);
  ok("and labels the session doc:gift-cards/spec.md", await page.eval(has("doc:gift-cards/spec.md")));
  await shot("web-build-this");
} finally {
  await chrome.close();
}
