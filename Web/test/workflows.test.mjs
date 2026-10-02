// A workflow's row, as Swift has it (research R7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";
import { cases } from "./fixtures.mjs";

const w = await load("src/model/workflows.ts");
const names = { grok: "Grok" };

for (const { name, input, expected } of cases("workflows/summaries.json")) {
  test(`workflow: ${name}`, () => {
    assert.deepEqual({
      summary: w.workflowSummary(input.workflow, (id) => names[id]),
      canFire: w.canFire(input.workflow),
      needsAPerson: w.workflowNeedsAPerson(input),
    }, expected);
  });
}

test("an event trigger is said by its name and filters, the page having no catalogue", () => {
  const trigger = { unrecognised: { name: "ci.finished", keys: { branch: "main", attempt: 2 } } };
  assert.equal(w.triggerSummary(trigger), "When ci.finished (attempt 2, branch main)");
  assert.equal(w.canFire({ triggers: [trigger], mode: "new", settings: { options: {}, labels: [] } }), true);
});

test("the status mark follows WorkflowStatusIcon's order", () => {
  const [{ input }] = cases("workflows/summaries.json");
  assert.equal(w.workflowStatus(input).words, "Waiting for its trigger");
  assert.equal(w.workflowStatus({ ...input, isRunning: true }).words, "Running");
  assert.equal(w.workflowStatus({ ...input, isArchived: true }).words, "Archived");
  assert.equal(w.workflowStatus({ ...input, awaitingApproval: { digest: "x", isNew: true } }).words, "Waiting for your OK");
  assert.equal(w.workflowStatus({ ...input, isEnabled: false }).words, "Turned off");
  assert.equal(w.workflowStatus({ ...input, isEnabled: false }).tinted, false);
  assert.equal(w.workflowStatus({ ...input, isEnabled: false, isArchived: true }).words, "Archived");
});
