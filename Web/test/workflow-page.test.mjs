// The workflow page's status card and attributes (#142), as WorkflowStatus.swift has them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const w = await load("src/model/workflows.ts");
const [{ input }] = cases("workflows/summaries.json");

test("the status card leads with what stops it and ends with the next run", () => {
  const waiting = w.workflowStatusLines({ ...input, isEnabled: false, offReason: "file", awaitingApproval: { digest: "x", isNew: true } });
  assert.deepEqual(waiting.map((l) => l.text), [
    "New — waiting for your OK", "Off — its file says enabled: false", "No next run",
  ]);
  assert.equal(waiting[0].tint, "attention");
  assert.equal(waiting.at(-1).detail, "Until what is above changes");
});

test("an archived one says so first and has no switch line", () => {
  const lines = w.workflowStatusLines({ ...input, isArchived: true });
  assert.equal(lines[0].text, "Archived — it will not run until it is brought back");
  assert.ok(!lines.some((l) => l.text.startsWith("On") || l.text.startsWith("Off")));
});

test("running links to the agent it ran", () => {
  const lines = w.workflowStatusLines({ ...input, isRunning: true, lastOutcome: { ran: { agentID: "A", at: 0 } } });
  assert.equal(lines.find((l) => l.text === "Running now").agentID, "A");
});

test("agent mode, labels and unknown keys are said in the window's words", () => {
  assert.equal(w.agentModeWords("standing"), "Sends each run to its standing agent");
  assert.equal(w.labelsNote({ ...input.workflow, mode: "new", settings: { options: {}, labels: ["a"] } }), "Each run's new agent gets these labels.");
  assert.deepEqual(w.unknownLines({ ...input.workflow, unknownFields: { notify: "slack", retry: { times: 2 } } }),
    ["notify: slack", 'retry: {"times":2}']);
});

// The page's menus (#162), as WorkflowSettings.swift and the window's WorkflowPage have them.
const ws = await load("src/model/workflowSettings.ts");
const select = (id, category, values) => ({ id, name: id, category, type: "select", currentValue: values[0], options: values.map((v) => ({ value: v, name: v.toUpperCase() })) });
const advertised = [select("mode", "mode", ["default", "plan"]), select("model", "model", ["opus", "haiku"]),
  select("effort", "thought_level", ["low", "high"]), { id: "fast", name: "Fast", type: "boolean", currentValue: false }];

test("the mode, model and effort have keys of their own; the rest go under options", () => {
  assert.equal(ws.modelOption(advertised).id, "model");
  assert.equal(ws.effortOption(advertised).id, "effort");
  assert.deepEqual(ws.otherOptions(advertised).map((o) => o.id), ["fast"]);
});

test("each menu's first choice leaves the key out, named for its menu", () => {
  const menu = ws.withDefault(advertised[1], "Model");
  assert.equal(menu.options[0].options[0].name, "Model: runtime default");
  assert.equal(menu.options[0].options[0].value, null);
  assert.deepEqual(menu.options[1].options.map((c) => c.value), ["opus", "haiku"]);
  const fast = ws.selectable(advertised[3]);
  assert.deepEqual(fast.options.map((c) => c.value), ["true", "false"]);
  assert.equal(ws.shown("yes", advertised[3]), "true");
});

test("a value the runtime does not offer is said, naming what it does", () => {
  const lines = ws.refusals({ permissionMode: "yolo", model: "opus", options: { fast: "on", colour: "red" }, labels: [] }, advertised, "Claude");
  assert.deepEqual(lines, [
    '"yolo" is not a permission mode Claude offers here — it offers default, plan',
    "colour: red — Claude does not offer this option here",
  ]);
});

test("the host list offers This Mac first and leaves out a relay (#317)", () => {
  assert.deepEqual(w.workflowHostChoices([
    { id: "box", name: "Zebra", machineID: "z" },
    { id: "relay", name: "Relay", machineID: "r", relay: true },
    { id: "mac", name: "Office", machineID: "mac-id" },
    { id: "gone", name: "No id" },
    { id: "again", name: "Also", machineID: "mac-id" },
  ]), [
    { machineID: "mac-id", name: "This Mac" },
    { machineID: "z", name: "Zebra" },
  ]);
  assert.equal(w.workflowRunsOn(undefined, "mac-id"), true);
  assert.equal(w.workflowRunsOn([], "mac-id"), true);
  assert.equal(w.workflowRunsOn(["other"], undefined), false);
  assert.equal(w.workflowRunsOn(["mac-id"], "mac-id"), true);
  assert.equal(w.workflowRunsOn(["other"], "mac-id"), false);
});

test("the cooldown is written as the file writes it", () => {
  assert.equal(ws.cooldownFileText(15 * 60), "15m");
  assert.equal(ws.cooldownFileText(90 * 60), "1h30m");
  assert.equal(ws.cooldownFileText(24 * 3600), "1d");
});
