// The daily summary's control (#3351): the web page says what the window's and the Remote's
// DailySummaryControls.swift says, offers every half hour, and sits on Settings ▸ Workflows.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { load } from "./load.mjs";

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
// The store and its slices (#5384).
const readStore = () => [read("Web/src/model/store.ts"), ...readdirSync(new URL("../src/model/store/", import.meta.url)).map((name) => read(`Web/src/model/store/${name}`))].join("\n");
const w = await load("src/model/dailySummaryWords.ts");

test("the control's words are the window's and the Remote's", () => {
  const swift = read("Shared/UI/DailySummaryControls.swift").replace(/"\s*\+\s*"/g, "");
  assert.ok(swift.includes(w.dailySummaryHint), w.dailySummaryHint);
  assert.ok(swift.includes(w.checksHint), w.checksHint);
  const model = read("Packages/AgentsKit/Sources/AgentsKitCore/Model/DailySummarySettings.swift");
  for (const { mode, label } of w.dailySummaryModes) {
    assert.ok(model.includes(`case .${mode}: "${label}"`), label);
  }
  assert.ok(model.includes(`checksEveryChoices = [${w.checksEveryChoices.join(", ")}]`));
  assert.ok(model.includes('"Every \\(hours) hours"'));
  assert.equal(w.checksEveryLabel(4), "Every 4 hours");
});

test("every half hour is offered, and a hand-set time too", () => {
  assert.equal(w.dailySummaryTimes.length, 48);
  assert.equal(w.dailySummaryTimes[0], "00:00");
  assert.equal(w.dailySummaryTimes[17], "08:30");
  assert.ok(w.dailySummaryChoices("08:00") === w.dailySummaryTimes);
  assert.ok(w.dailySummaryChoices("08:15").includes("08:15"));
});

test("Settings ▸ Workflows draws it, and dailySummary/changed keeps it", () => {
  assert.ok(read("Web/src/views/AgentConfigEditor.tsx").includes('kind === "workflows" && <DailySummaryControl'));
  const store = readStore();
  assert.ok(store.includes('case "dailySummary/changed":'));
  assert.ok(store.includes('"dailySummary/setSettings"'));
});
