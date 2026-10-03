// The #156 walk: the icon's violet as the page's accent, in light and dark. Pairs, then shoots
// the pairing card's prominent button, a session (a link, Send, a sidebar row with the focus
// ring) and a workflow page (its Enabled switch, Run now), each in both schemes.
//
//   node Web/test/walk/accent.mjs <WEB_URL> <browser code> <out dir> <session title> <workflow name>

import { setTimeout as sleep } from "node:timers/promises";
import { launch } from "./cdp.mjs";

const [webURL, code, out, session, workflow] = process.argv.slice(2);
const chrome = await launch({ profile: `/tmp/156-accent-chrome-${process.pid}` });
const js = JSON.stringify;

try {
  const page = await chrome.page(webURL, { width: 1280, height: 820 });
  const scheme = (value) => page.raw("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value }] });
  const both = async (name) => {
    for (const value of ["light", "dark"]) {
      await scheme(value);
      await sleep(300);
      await page.shot(`${out}/web-${name}-${value}.png`);
    }
  };

  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await both("pairing");
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".sidebar .row.project")`, 20_000);
  await sleep(800);

  const find = (text) => `[...document.querySelectorAll(".sidebar button, .sidebar summary")].find((b) => b.innerText.includes(${js(text)}))`;
  await page.eval(`document.querySelectorAll('.sidebar .disclosure[aria-expanded="false"]').forEach((b) => b.click())`);
  await sleep(800);

  // The session: its link and Send, then a sidebar row reached by the keyboard for the ring.
  await page.waitFor(`!!${find(session)}`, 20_000);
  await page.eval(`${find(session)}.click()`);
  await sleep(1200);
  await page.eval(`${find(session)}.focus({ focusVisible: true })`);
  await page.raw("Input.dispatchKeyEvent", { type: "keyDown", key: "Shift", code: "ShiftLeft" });
  await page.raw("Input.dispatchKeyEvent", { type: "keyUp", key: "Shift", code: "ShiftLeft" });
  await both("session");

  await page.waitFor(`!!${find(workflow)}`, 20_000);
  await page.eval(`${find(workflow)}.click()`);
  await sleep(1200);
  await both("workflow");
  console.log("accent:", await page.eval(`getComputedStyle(document.documentElement).getPropertyValue("--accent")`));
  if (page.errors.length) console.log("errors:", page.errors.join("\n"));
} finally {
  await chrome.close();
}
