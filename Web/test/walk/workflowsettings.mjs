// The workflow page's settings walk (#162): each setting changed from the page, and the file read
// after each, on a run-app root with one workflow, Nightly sweep (agent: new, Claude remembered
// in its folder so the menus have choices). A refusal is shown by making the file unreadable and
// changing the model: the daemon's sentence beside the controls, the menu back where the file is.
//
//   node Web/test/walk/workflowsettings.mjs <WEB_URL> <browser code> <workflow file> <out dir>
import { chmodSync, readFileSync } from "node:fs";
import { launch } from "./cdp.mjs";

const [webURL, code, file, out] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const front = () => readFileSync(file, "utf8").split("\n---")[0];
const chrome = await launch({ profile: `/tmp/162-workflowsettings-chrome-${process.pid}` });
try {
  const page = await chrome.page(webURL, { width: 1440, height: 1100 });
  await page.waitFor(`document.querySelector("textarea")`);
  await page.focus("textarea");
  await page.type(code);
  await page.press("Connect");
  await page.waitFor(`document.querySelector(".project-fold .row.project")`, 30_000);
  await page.eval(`document.querySelector(".project-fold .disclosure[aria-expanded=false]")?.click()`);
  await page.waitFor(`document.querySelector(".row.workflow")`, 30_000);
  await page.eval(`document.querySelector(".row.workflow .pick").click()`);
  await page.waitFor(`document.querySelector(".workflow-page h1")?.textContent === "Nightly sweep"`, 10_000);
  await page.waitFor(`document.querySelector(".workflow-page select[aria-label='Model']")`, 10_000);
  await sleep(400);
  console.log(`before:\n${front()}`);
  await page.shot(`${out}/web-before.png`);

  // A menu's choice by its visible name, sent as the person's pick is.
  const choose = async (menu, name) => {
    const ok = await page.eval(`(() => {
      const s = document.querySelector(${JSON.stringify(`.workflow-page select[aria-label="${menu}"]`)});
      const o = s && [...s.options].find((o) => o.textContent === ${JSON.stringify(name)});
      if (!o) return [...(s?.options ?? [])].map((o) => o.textContent).join(" | ");
      s.value = o.value; s.dispatchEvent(new Event("change", { bubbles: true })); return true;
    })()`);
    if (ok !== true) throw new Error(`${menu}: no ${name} in ${ok}`);
  };
  const waitFile = async (needle, gone = false) => {
    for (let i = 0; i < 50; i++) {
      if (front().includes(needle) !== gone) return;
      await sleep(100);
    }
    throw new Error(`the file never ${gone ? "lost" : "got"} ${needle}:\n${front()}`);
  };

  const steps = [
    ["Runtime", process.env.RUNTIME_NAME ?? "Codex", `runtime: ${process.env.RUNTIME_ID ?? "codex"}`],
    ["Runtime", "Default (Claude)", "runtime:", true],
  ];
  for (const [menu, name, needle, gone] of steps) {
    await choose(menu, name);
    await waitFile(needle, gone);
    console.log(`${menu} → ${name}: ok`);
  }
  await page.waitFor(`document.querySelector(".workflow-page select[aria-label='Model']")`, 10_000);
  const pick = async (menu, index) => {
    const name = await page.eval(`[...document.querySelector(${JSON.stringify(`.workflow-page select[aria-label="${menu}"]`)}).options][${index}].textContent`);
    await choose(menu, name);
    return name;
  };
  for (const [menu, key] of [["Permission mode", "permission-mode:"], ["Model", "model:"], ["Effort", "effort:"]]) {
    const name = await pick(menu, 2);
    await waitFile(key);
    console.log(`${menu} → ${name}: ${front().split("\n").find((l) => l.startsWith(key))}`);
  }
  const others = await page.eval(`[...document.querySelectorAll(".workflow-page .menus-right select")].map((s) => s.getAttribute("aria-label")).filter((n) => !["Model", "Effort"].includes(n))`);
  for (const menu of others) {
    const name = await pick(menu, 1);
    await waitFile("options:");
    console.log(`${menu} → ${name}: ${front().split("options:")[1]?.split("\n").slice(0, 3).join(" ")}`);
  }

  await choose("Cooldown", "Cooldown: 1 hour");
  await waitFile("cooldown: 1h");
  console.log("Cooldown → 1 hour: ok");

  await page.focus(".workflow-page .label-field");
  await page.type("nightly,");
  await waitFile("nightly");
  await page.eval(`document.querySelector(".workflow-page .chip.label button[aria-label='Remove the label review']").click()`);
  await waitFile("review", true);
  console.log(`labels: ${front().split("\n").find((l) => l.startsWith("labels"))}`);
  await sleep(400);
  console.log(`after:\n${front()}`);
  await page.shot(`${out}/web-after.png`);

  // A refusal, said beside the controls: the file made unreadable, then a change asked for.
  chmodSync(file, 0o000);
  try {
    await pick("Model", 0);
    await page.waitFor(`document.querySelector(".workflow-page [role=alert]")`, 10_000);
    console.log(`refused: ${await page.eval(`document.querySelector(".workflow-page [role=alert]").innerText`)}`);
    console.log(`model menu after the refusal: ${await page.eval(`document.querySelector(".workflow-page .pill.select:has(select[aria-label='Model'])").innerText.trim()`)}`);
    await page.shot(`${out}/web-refused.png`);
  } finally {
    chmodSync(file, 0o644);
  }
  console.log(`settings menus: ${JSON.stringify(await page.eval(`[...document.querySelectorAll(".workflow-page .pill.select")].map((p) => p.innerText.trim())`))}`);
} finally {
  await chrome.close();
}
