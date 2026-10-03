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

test("the settings are shown read-only with the runtime's defaults named", () => {
  const rows = w.settingRows({ ...input.workflow, settings: { permissionMode: "plan", options: { fast: "true" }, labels: [] } }, () => "Claude");
  assert.deepEqual(rows, [["Runtime", "Claude (default)"], ["Permission mode", "plan"], ["Model", "Runtime default"],
    ["Effort", "Runtime default"], ["fast", "true"]]);
});
