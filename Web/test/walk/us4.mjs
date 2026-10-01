// The US4 walk (071 quickstart §7, first half; T066): a real Claude turn edits two files and
// shows a Markdown page it then writes, watched in headless Chrome; the page is typed on; and a
// hostile .html and .svg are opened while CDP listens for any console call or network request.
//
//   node Web/test/walk/us4.mjs <WEB_URL> <ROOT> <device code> <out dir> <rpc.py>

import { execFileSync, spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, root, deviceCode, out, rpcPath] = process.argv.slice(2);
const notes = [];
const say = (line) => { notes.push(line); console.log(line); };
const rpc = (...args) => JSON.parse(execFileSync(rpcPath, [root, "call", ...args], { encoding: "utf8" }));
const work = `${root}/work`;

const chrome = await launch({ profile: `/tmp/071-us4-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1600, height: 1000 });
await page.waitFor(`document.querySelector("textarea")`);
await page.focus("textarea");
await page.type(deviceCode);
await page.press("Connect");
await page.waitFor(`document.querySelector(".projects .row")`);

const prompt = [
  "Do these steps in order, each with your own file tools, and nothing else:",
  "1. Add the line 'Edited by the agent.' at the end of README.md.",
  "2. Create notes.txt containing two lines: first, second.",
  `3. Create plan.md with a '# Plan' heading and one short paragraph.`,
  `4. Call the show_file tool from the agents MCP server on ${work}/plan.md.`,
  "5. Then add three more short paragraphs to plan.md, one edit per paragraph.",
  "Then say done.",
].join("\n");
const turn = spawn(rpcPath, [root, "start", "claude", work, prompt, "300"], { stdio: ["ignore", "pipe", "pipe"] });
let agentID = null;
turn.stdout.on("data", (chunk) => {
  const found = /agentID: "([0-9A-F-]{36})"/.exec(String(chunk));
  if (found) agentID = found[1];
});
while (!agentID) await sleep(200);
say(`started ${agentID}`);

await page.eval(`[...document.querySelectorAll(".projects .row")].find((r) => r.textContent.startsWith("work"))?.click()`);
await page.waitFor(`document.querySelector(".group[aria-label=Working] .session")`, 60_000);
await page.eval(`document.querySelector(".group[aria-label=Working] .session").click()`);

// 1. The page opens beside the chat on its own, and follows each write.
await page.waitFor(`document.querySelector(".files .live-page")`, 240_000);
const openedAt = Date.now();
say(`agent/showFile: the pane opened on its own, on the ${await page.eval(`document.querySelector(".files .tab.chosen").textContent`)} tab`);
const seen = [];
let finished = null;
for (let i = 0; i < 300 && !finished; i++) {
  const text = await page.eval(`document.querySelector(".files .live-page .page")?.innerText ?? ""`);
  if (text && text !== seen[seen.length - 1]) seen.push(text);
  const agent = rpc("agents/list", JSON.stringify({ includeArchived: false })).find((a) => a.id === agentID);
  if (agent.state !== "running" && agent.state !== "starting" && agent.state !== "waitingOnUser") finished = agent;
  await sleep(500);
}
await sleep(1500);
const finalText = await page.eval(`document.querySelector(".files .live-page .page")?.innerText ?? ""`);
if (finalText !== seen[seen.length - 1]) seen.push(finalText);
const onDisk = readFileSync(`${work}/plan.md`, "utf8");
say(`turn ended: ${finished?.state}${finished?.report ? `, ${finished.report.outcome}: ${finished.report.message}` : ""}`);
say(`the page went through ${seen.length} versions in ${((Date.now() - openedAt) / 1000).toFixed(0)} s; paragraphs drawn now ${await page.eval(`document.querySelectorAll(".files .passage").length`)}, on disk ${onDisk.split(/\n\s*\n/).filter((p) => p.trim()).length}`);
await page.shot(`${out}/us4-1-page.png`);

// 2. Typed on: the last passage, edited in the browser, reaches the file.
const typed = " Typed in the browser.";
await page.eval(`[...document.querySelectorAll(".files .passage")].pop().click()`);
await page.waitFor(`document.querySelector(".files .passage-editor")`);
await page.eval(`(() => { const t = document.querySelector(".files .passage-editor"); t.focus(); t.setSelectionRange(t.value.length, t.value.length); })()`);
await page.type(typed);
await page.shot(`${out}/us4-2-typing.png`);
for (let i = 0; i < 40 && !readFileSync(`${work}/plan.md`, "utf8").includes(typed.trim()); i++) await sleep(250);
const reached = readFileSync(`${work}/plan.md`, "utf8").includes(typed.trim());
say(`typed on the page: reached plan.md on the host: ${reached}`);
await page.eval(`document.querySelector(".files .passage-editor")?.blur()`);
await sleep(800);
say(`after editing, the page still has ${await page.eval(`document.querySelectorAll(".files .passage").length`)} passages and the file ends: ${JSON.stringify(readFileSync(`${work}/plan.md`, "utf8").trim().split("\n").pop())}`);

// 3. Changes: both files with their diffs.
const tab = (name) => page.eval(`[...document.querySelectorAll(".files [role=tab]")].find((t) => t.textContent === ${JSON.stringify(name)}).click()`);
await tab("Changes");
await page.waitFor(`document.querySelector(".changed-files li")`, 15_000);
const changed = await page.eval(`[...document.querySelectorAll(".changed-files .row")].map((r) => r.innerText.replace(/\\n/g, " · "))`);
say(`changes: ${JSON.stringify(changed)}`);
await page.eval(`[...document.querySelectorAll(".changed-files .row")].find((r) => r.textContent.includes("README"))?.click()`);
await page.waitFor(`document.querySelector(".diff-line")`, 15_000);
say(`README.md's diff: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".diff-line.added, .diff-line.removed")].map((l) => l.textContent.trim())`))}`);
await page.shot(`${out}/us4-3-changes.png`);

// 4. Files: an .html and an .svg with scripts, opened while CDP listens.
const consoleBefore = page.console.length;
const requestsBefore = page.requests.length;
await tab("Files");
await page.waitFor(`[...document.querySelectorAll(".entries .row")].some((r) => r.textContent.includes("page.html"))`, 15_000);
await page.eval(`[...document.querySelectorAll(".entries .row")].find((r) => r.textContent.includes("page.html")).click()`);
await page.waitFor(`document.querySelector(".file-text")`, 15_000);
say(`page.html: ${JSON.stringify(await page.eval(`document.querySelector(".file .quiet")?.textContent`))}; source shown: ${await page.eval(`document.querySelector(".file-text").textContent.includes("<script>")`)}`);
await page.shot(`${out}/us4-4-html.png`);
await page.eval(`[...document.querySelectorAll(".crumbs button")].find((b) => b.textContent.startsWith("‹"))?.click()`);
await page.waitFor(`[...document.querySelectorAll(".entries .row")].some((r) => r.textContent.includes("picture.svg"))`, 15_000);
await page.eval(`[...document.querySelectorAll(".entries .row")].find((r) => r.textContent.includes("picture.svg")).click()`);
await page.waitFor(`document.querySelector(".file img.picture")?.complete`, 15_000);
const img = await page.eval(`(() => { const i = document.querySelector(".file img.picture"); return { src: i.src.slice(0, 5), width: i.naturalWidth, height: i.naturalHeight }; })()`);
say(`picture.svg: drawn as <img> from ${img.src}, ${img.width}×${img.height}`);
await sleep(2000);
await page.shot(`${out}/us4-5-svg.png`);
const consoleAfter = page.console.slice(consoleBefore).filter((c) => !c.startsWith("agents: "));
const requestsAfter = page.requests.slice(requestsBefore).filter((u) => !u.startsWith(webURL) && !u.startsWith("blob:") && !u.startsWith("ws:"));
say(`while they were open: console calls ${JSON.stringify(consoleAfter)}, requests off the page's origin ${JSON.stringify(requestsAfter)}`);
say(`page errors: ${JSON.stringify(page.errors.filter((e) => !e.includes("ERR_CONNECTION_REFUSED")))}`);

writeFileSync(`${out}/notes.txt`, notes.join("\n") + "\n");
turn.kill();
await chrome.close();
