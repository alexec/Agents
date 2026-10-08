// The #229 walk, on a scratch root whose host has a scratch personal home: New Chat in the +
// menu opens the chat project's new-session form; archived, it says so and Unarchive brings it
// back; a chat's Changes says the folder is not a Git repository. Screenshots go to <out dir>.
//
//   node Web/test/walk/chat229.mjs <WEB_URL> <browser code> <out dir> [archive command]
//
// With an archive command (a shell line that archives the chat project, such as an `rpc.py`
// call), New Chat is pressed again after it and must offer Unarchive, which must bring it back.
//
// The host's chat project must already have one finished session (any runtime), for Changes.

import { setTimeout as sleep } from "node:timers/promises";
import { execSync } from "node:child_process";
import { launch } from "./cdp.mjs";

const [webURL, code, out, archive] = process.argv.slice(2);
let failed = 0;
const say = (line) => console.log(line);
const check = (ok, line) => { if (!ok) failed += 1; say(`${ok ? "ok  " : "FAIL"} ${line}`); };

const chrome = await launch({ profile: `/tmp/chat229-chrome-${process.pid}` });
const page = await chrome.page(webURL, { width: 1280, height: 820 });
try {
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.project")`, 20_000);
  await sleep(800);
  check((await page.text(".sidebar")).includes("chat"), "the sidebar lists the chat project");

  // New Chat from the + menu.
  await page.press("New project");
  await page.waitFor(`document.querySelector("[role=menu][aria-label='New project']")`);
  say(`menu: ${JSON.stringify(await page.text("[role=menu][aria-label='New project']"))}`);
  await page.shot(`${out}/web-1-menu.png`);
  await page.press("New Chat");
  await sleep(1200);
  const hash = decodeURIComponent(await page.eval("location.hash"));
  check(hash.includes(".agents/chat"), `New Chat opens the chat project: ${hash}`);
  check(!(await page.eval(`document.body.innerText`)).includes("New worktree"), "no worktree choice");
  await page.shot(`${out}/web-2-newchat.png`);

  // A finished chat's Changes: not a Git repository.
  await page.eval(`document.querySelectorAll('.sidebar .disclosure[aria-expanded="false"]').forEach((b) => b.click())`);
  await sleep(600);
  const session = `[...document.querySelectorAll(".sidebar .row.session, .sidebar .session")][0]`;
  const hasSession = await page.eval(`!!${session}`);
  if (hasSession) {
    await page.eval(`${session}.click()`);
    await sleep(1200);
    // The files pane, by its route (`/f/1`), as Chat.tsx opens it; then its Changes tab.
    await page.eval(`location.hash = location.hash.replace(/\\/f\\/1$/, "") + "/f/1"`);
    await sleep(1000);
    const changes = `[...document.querySelectorAll("aside.files [role=tab]")].find((b) => b.innerText.trim() === "Changes")`;
    if (await page.eval(`!!${changes}`)) {
      await page.eval(`${changes}.click()`);
      await page.waitFor(`document.body.innerText.includes("Git repository") || document.body.innerText.includes("Nothing has changed")`, 10_000);
      check((await page.eval(`document.body.innerText`)).includes("This folder is not a Git repository."),
        "Changes says the folder is not a Git repository");
      await page.shot(`${out}/web-3-changes.png`);
    } else {
      check(false, "no Changes control found on the session page");
    }
  } else {
    check(false, "no session found under chat to open Changes on");
  }

  // Archived: New Chat says so, and Unarchive brings it back and opens it.
  if (archive) {
    execSync(archive, { stdio: "ignore" });
    await sleep(1500);
    await page.press("New project");
    await page.waitFor(`document.querySelector("[role=menu][aria-label='New project']")`);
    await page.press("New Chat");
    await page.waitFor(`document.querySelector("dialog.sheet[open]")`, 10_000);
    const said = await page.text("dialog.sheet");
    check(said.includes("The chat project on this Mac is archived."), `archived: ${JSON.stringify(said)}`);
    await page.shot(`${out}/web-4-archived.png`);
    await page.press("Unarchive");
    await sleep(1500);
    const back = decodeURIComponent(await page.eval("location.hash"));
    check(back.includes(".agents/chat") && !(await page.eval(`!!document.querySelector("dialog.sheet[open]")`)),
      `Unarchive brings it back and opens it: ${back}`);
    await page.shot(`${out}/web-5-unarchived.png`);
  }
} finally {
  await chrome.close();
}
say(failed ? `${failed} failed` : "all ok");
process.exit(failed ? 1 : 0);
