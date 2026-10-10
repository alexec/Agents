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

test("an event trigger uses the catalogue meaning and includes its filters", () => {
  const trigger = { unrecognised: { name: "custom.build_green", keys: { branch: "main", attempt: 2 } } };
  assert.equal(w.triggerSummary(trigger), "An agent here publishes custom.build_green (attempt 2, branch main)");
  assert.equal(w.triggerSummary({ unrecognised: { name: "custom.build_green", keys: {} } }),
    "An agent here publishes custom.build_green");
  assert.equal(w.triggerSummary({ unrecognised: { name: "agent.finished", keys: {} } }),
    "An agent in this project ended a turn having done its work");
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
  const { isEnabled, ...fromBefore100 } = input;
  assert.equal(w.workflowStatus(fromBefore100).words, "Waiting for its trigger", "a host from before #100 sends no isEnabled: on");
});

test("a held trigger says it is cooling down, grey (#103)", () => {
  const held = cases("workflows/summaries.json").find((c) => c.name === "a cooldown, triggering, a trigger held");
  assert.equal(w.workflowStatus(held.input).words, "Cooling down, then it runs once");
  assert.equal(w.workflowStatus(held.input).tinted, false);
  assert.equal(w.cooldownWords(90 * 60), "1 hour 30 minutes");
});

// The workflow page's words (#98, #100), held to WorkflowTriggerWordsTests.swift's cases.
const event = (name, keys = {}) => ({ unrecognised: { name, keys } });
const schedule = { schedule: { _0: { minutes: [0], hours: [3, 3], days: ["sun"], startMinute: 0, endMinute: 0 } } };

test("each trigger listens where its events are", () => {
  assert.equal(w.listensIn({ agentFinished: {} }), "project");
  assert.equal(w.listensIn({ workflowCompleted: {} }), "project");
  assert.equal(w.listensIn(event("branch.moved")), "project");
  assert.equal(w.listensIn(event("mac.wake")), "mac");
  assert.equal(w.listensIn(event("machine.disk_low", { level: "critical" })), "mac");
  assert.equal(w.listensIn(event("machine.disk_ok")), "mac");
  assert.equal(w.listensIn(event("cost.limit_reached")), "either");
  assert.equal(w.listensIn(event("custom.build_green")), "project");
  assert.equal(w.listensIn(event("cost.*")), "either");
  assert.equal(w.listensIn(event("agent.*")), "project");
  assert.equal(w.listensIn(schedule), null);
  assert.equal(w.listensIn(event("x")), null);
  assert.equal(w.scopeLine(event("mac.wake"), "work", "this Mac"), "Anywhere on this Mac, so it runs in every project");
  assert.equal(w.scopeLine(schedule, "work", "this Mac"), "By the clock on this Mac");
});

test("filters are the file's own, including a workflow id", () => {
  assert.deepEqual(w.triggerFilters(event("branch.moved", { branch: "main" })), [["branch", "main"]]);
  assert.deepEqual(w.triggerFilters({ workflowCompleted: { id: "nightly" } }), [["workflow", "nightly"]]);
  assert.deepEqual(w.triggerFilters({ agentFinished: {} }), []);
});

test("a triggering run says which agent it resumes, or that there is none", () => {
  assert.equal(w.resumedAgent({ agentFinished: {} }), "Resumes the agent that finished");
  assert.equal(w.resumedAgent(event("custom.ready")), "Resumes the agent that published it");
  assert.match(w.resumedAgent(event("mac.wake")), /never runs/);
  assert.match(w.resumedAgent(schedule), /never runs/);
  assert.equal(w.resumedAgent(event("agent.started")), "Resumes the agent it is about");
});

test("what set a run off reads after Last ran", () => {
  assert.equal(w.causePhrase({ byHand: {} }), "by hand, with Run now");
  assert.equal(w.causePhrase({ trigger: { _0: schedule } }), "on its schedule");
  assert.equal(w.causePhrase({ trigger: { _0: event("branch.moved", { branch: "main" }) } }), "on branch.moved branch main");
  assert.equal(w.causePhrase({ trigger: { _0: { agentFinished: {} } } }), "when an agent finishes");
});

test("off says so in place of a next time, and in what is happening (#100)", () => {
  const summary = { workflow: { workflowID: "n", triggers: [schedule], mode: "new", prompt: "", settings: {}, unknownFields: {} },
    isArchived: false, isEnabled: false, isRunning: false, nextFireAtByTrigger: [] };
  assert.equal(w.nextLine(summary, 0), "Off — no next time");
  assert.equal(w.happening(summary), w.turnedOffSentence);
  const on = { ...summary, isEnabled: true, nextFireAtByTrigger: [] };
  assert.equal(w.nextLine(on, 0), "No next time");
  assert.equal(w.lastRanLine(on), "Has not run yet.");
  const refused = { ...on, lastOutcome: { refused: { _0: { missedWhileClosed: {} }, at: 0, repeats: 2 } } };
  assert.equal(w.happening(refused), "Missed 2 times — the app was closed");
});

test("off says why when it started off, as the Mac and the Remote do (#124)", () => {
  const summary = { workflow: { workflowID: "n", triggers: [schedule], mode: "new", prompt: "", settings: {}, unknownFields: {} },
    isArchived: false, isEnabled: false, isRunning: false, nextFireAtByTrigger: [] };
  const rest = ". None of its triggers run it until it is turned on. It doesn't count towards the workflows running, and Run now still runs it";
  assert.equal(w.happening({ ...summary, offReason: "writtenByAgent" }),
    "Off: written by an agent. Turn it on when you are ready" + rest);
  assert.equal(w.happening({ ...summary, offReason: "file" }),
    "Off: its file says enabled: false. Turn it on when you are ready" + rest);
  assert.equal(w.happening({ ...summary, offReason: "agent" }), "Off: an agent turned it off" + rest);
  assert.equal(w.happening({ ...summary, offReason: "person" }), w.turnedOffSentence);
  assert.equal(w.happening({ ...summary, offReason: "writtenByAgent", awaitingApproval: { isNew: true } }),
    "New — approve it on its page to let it run · Off: written by an agent. Turn it on when you are ready");
});

test("a waiting workflow past the three says why, with no Approve (#132)", () => {
  const summary = { workflow: { workflowID: "d", triggers: [schedule], mode: "new", prompt: "", settings: {}, unknownFields: {} },
    isArchived: false, isEnabled: false, isRunning: false, nextFireAtByTrigger: [],
    awaitingApproval: { digest: "x", isNew: true }, overLimit: "project" };
  assert.equal(w.waitsItsTurn(summary), true);
  assert.equal(w.happening(summary),
    "This project already has 3 workflows waiting for approval. Approve or remove one of the 3 workflows waiting for approval first");
  assert.equal(w.workflowStatus(summary).words, "Over the limit");
  assert.equal(w.waitsItsTurn({ ...summary, overLimit: undefined }), false);
});

test("a workflow denied on this host stays listed, runs nothing here, and can be approved back (#391)", () => {
  const summary = { workflow: { workflowID: "d", triggers: [schedule], mode: "new", prompt: "", settings: {}, unknownFields: {} },
    isArchived: false, isEnabled: true, isRunning: false, nextFireAtByTrigger: [],
    deniedHere: { digest: "x", isNew: true } };
  assert.equal(w.workflowStatus(summary).words, "Denied on this host");
  assert.equal(w.workflowNeedsAPerson(summary), false);
  assert.equal(w.isUnapproved(summary), true);
  assert.equal(w.canBeApproved(summary), true);
  assert.equal(w.canBeDenied(summary), false);
  assert.equal(w.happening(summary), "Denied on this host — it does not run here");
  assert.equal(w.nextLine(summary, 0), "No next time until you approve it");
  const waiting = { ...summary, deniedHere: undefined, awaitingApproval: { digest: "x", isNew: true }, overLimit: "project" };
  assert.equal(w.canBeDenied(waiting), true, "even one waiting its turn can be denied");
  assert.equal(w.canBeApproved(waiting), false);
  assert.equal(w.refusalMessage({ deniedHere: {} }), "it is denied on this host");
});

// Filters in words (#574): the key and its values, held to EventPatternFinerTests.swift's
// summaries, with the page using catalogue meanings as the Mac does.
test("an event trigger's filters are said in the Mac's words, lists included", () => {
  const say = (name, keys) => w.triggerSummary(event(name, keys));
  assert.equal(say("branch.moved", { branch: ["main", "develop"] }),
    "A branch moved: the default branch, or one an agent works on (branch main or develop)");
  assert.equal(say("person.away", { why: "locked" }), "You locked the screen or stepped away for 5 minutes (why locked)");
  assert.equal(say("person.*", { why: "idle" }), "Anything about persons (why idle)");
});

test("a list is a capsule joined by | and a cause joined by |", () => {
  const t = event("branch.moved", { branch: ["main", "develop"] });
  assert.deepEqual(w.triggerFilters(t), [["branch", "main | develop"]]);
  assert.equal(w.causePhrase({ trigger: { _0: t } }), "on branch.moved branch main|develop");
  // A value that is neither one value nor a list is not dropped into a wider trigger's words.
  assert.deepEqual(w.triggerFilters(event("branch.moved", { branch: { is: "main" } })), []);
});

test("the page says the switch is a line in the workflow's file, in the window's words (#125)", () => {
  assert.equal(w.switchesSentence({ workflow: { workflowID: "nightly" } }),
    "Enabled and Archive are saved in .agents/workflows/nightly.md, a file in this project you may commit");
});

const dates = await load("src/protocol/dates.ts");
const at = (text) => dates.toWireDate(new Date(text));

test("a server's event trigger's lines say what the Mac's say (#383)", () => {
  const now = new Date("2026-10-06T12:05:30Z");
  assert.equal(w.mcpTriggerWords({ name: "checks.failed", server: "ci", state: "active",
    lastPolledAt: at("2026-10-06T12:05:10Z"), lastEventAt: at("2026-10-06T11:40:30Z") }, now).text,
    "ci · checks.failed: Checked 20 s ago · last event 25 min ago");
  assert.equal(w.mcpTriggerWords({ name: "checks.failed", server: "ci", state: "active",
    lastPolledAt: at("2026-10-06T12:05:10Z") }, now).text, "ci · checks.failed: Checked 20 s ago · no events yet");
  assert.equal(w.mcpTriggerWords({ name: "checks.failed", server: "ci", state: "pending" }, now).text,
    "ci · checks.failed: Connecting to ci…");
  const retrying = w.mcpTriggerWords({ name: "checks.failed", server: "ci", state: "retrying", retryAt: at("2026-10-06T12:06:10Z"),
    failure: { code: "unreachable", message: "Can't reach ci: no", since: at("2026-10-06T12:01:00Z") } }, now);
  assert.match(retrying.text, /^ci · checks\.failed: Can't reach ci since .+ · trying again in 40 s$/);
  assert.equal(retrying.tint, "attention");
  const stopped = w.mcpTriggerWords({ name: "brnch.moved", state: "stopped",
    failure: { code: "serverNotFound", message: "No server here offers brnch.moved.", since: at("2026-10-06T12:01:00Z") } }, now);
  assert.deepEqual(stopped, { text: "brnch.moved: No server here offers brnch.moved.", tint: "failure" });
  assert.match(w.mcpMissedWords({ name: "x.y", state: "active", missedSince: at("2026-10-06T09:14:00Z") }), /^Events may have been missed since /);
  assert.equal(w.mcpMissedWords({ name: "x.y", state: "active" }), null);
  const [{ input }] = cases("workflows/summaries.json");
  const lines = w.workflowStatusLines({ ...input, mcpTriggers: [{ name: "checks.failed", server: "b", state: "stopped",
    failure: { code: "badArguments", message: "b's checks.failed takes project; not repo.", since: at("2026-10-06T12:01:00Z") } }] });
  assert.ok(lines.some((line) => line.text === "b's checks.failed takes project; not repo." && line.tint === "failure"));
});
