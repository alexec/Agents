// Optimistic updates, the rest (#4814): approvals leave at once and come back on failure,
// preferences keep a change drawn until the Mac answers and put it back when it did not go, and a
// prompt is drawn as the person's bubble at once, until the host's own entry lands.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("test/optimistic4814-entry.ts");

function fakeLink(answer) {
  const asked = [];
  let notify = () => {};
  return { asked, notify: (method, params, host) => notify(method, params, host),
    onNotification: (f) => { notify = f; }, onState: () => {},
    call: async (method, params, host) => { asked.push({ method, params, host }); return answer(method, params); } };
}

/** A promise and the hands that settle it, for a call the test answers later. */
function later() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

const folder = "file:///tmp/work/";
const approval = (key = "server", more = {}) => ({ kind: "mcpServer", key, title: key, actions: ["approve", "deny"], ...more });
const summary = (approvals) => ({ folder: { folder, name: "work" }, approvals });
const approvalsShown = (store) => (store.folders.value.mac ?? [])[0]?.approvals?.map((a) => a.key);

test("an approval leaves at once, stays gone while a folder/changed still lists it, and is gone once answered", async () => {
  const call = later();
  const store = new m.Store(fakeLink((method) => (method === "approvals/answer" ? call.promise : [])));
  store.upsertFolder(summary([approval(), approval("other")]), "mac");
  const going = store.answerApproval("mac", folder, approval(), "approve", undefined);
  assert.deepEqual(approvalsShown(store), ["other"]);
  // The host's list from before the answer still has it: not drawn again.
  store.upsertFolder(summary([approval(), approval("other")]), "mac");
  assert.deepEqual(approvalsShown(store), ["other"]);
  // The Review page still finds it, to say a refusal in place.
  assert.equal(store.approvalShown("mac", folder, "mcpServer:server")?.key, "server");
  call.resolve(summary([approval("other")]));
  await going;
  assert.deepEqual(approvalsShown(store), ["other"]);
  assert.equal(store.approvalShown("mac", folder, "mcpServer:server"), undefined);
});

test("a refused answer brings the approval back and says what failed", async () => {
  const store = new m.Store(fakeLink((method) => {
    if (method === "approvals/answer") throw new m.CallFailed(-32000, "The server changed since you read it.");
    return [];
  }));
  const said = [];
  store.say = (line) => said.push(line);
  store.upsertFolder(summary([approval()]), "mac");
  await store.settleApproval("mac", folder, approval(), "approve");
  assert.deepEqual(approvalsShown(store), ["server"]);
  assert.equal(said.length, 1);
  assert.match(said[0], /^Could not approve — /);
});

test("a failed answer leaves out an approval the host settled meanwhile", async () => {
  const call = later();
  const store = new m.Store(fakeLink((method) => (method === "approvals/answer" ? call.promise : [])));
  store.say = () => {};
  store.upsertFolder(summary([approval()]), "mac");
  const going = store.settleApproval("mac", folder, approval(), "deny");
  // Answered elsewhere: the host's list no longer has it.
  store.upsertFolder(summary([]), "mac");
  call.reject(new m.CallFailed(-32000, "Already answered."));
  await going;
  assert.deepEqual(approvalsShown(store), []);
});

test("the failure lines say the action", () => {
  assert.equal(m.approvalFailure("requestChanges", "The host is away."), "Could not request changes — the host is away.");
  assert.equal(m.approvalFailure("dismiss", ""), "Could not dismiss.");
});

test("a preference stays drawn while it is on its way, and goes back and is said when it did not go", async () => {
  const call = later();
  const store = new m.Store(fakeLink((method) => (method === "preferences/set" ? call.promise : {})));
  const said = [];
  store.say = (line) => said.push(line);
  m.preferencesSaid({ showsUsage: true });
  m.setPreferences({ showsUsage: false });
  assert.equal(m.preferences.value.showsUsage, false);
  // Another change heard from the Mac meanwhile keeps this page's drawn over it.
  m.preferencesSaid({ showsUsage: true, showsActivity: false });
  assert.deepEqual(m.preferences.value, { showsUsage: false, showsActivity: false });
  call.reject(new m.CallFailed(-32000, "Your Mac did not answer."));
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(m.preferences.value, { showsUsage: true, showsActivity: false });
  assert.deepEqual(said, ["Could not save the setting — your Mac did not answer."]);
});

test("a preference the Mac took is its answer", async () => {
  const store = new m.Store(fakeLink((method) => (method === "preferences/set" ? { showsUsage: false } : {})));
  store.say = () => assert.fail("nothing to say");
  m.preferencesSaid({ showsUsage: true });
  m.setPreferences({ showsUsage: false });
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(m.preferences.value, { showsUsage: false });
  m.preferencesSaid({ showsUsage: true });
  assert.deepEqual(m.preferences.value, { showsUsage: true });
});

const agent = (more = {}) => ({ id: "A", runtimeID: "claude", cwd: folder, title: "T", state: "finished",
  lastActivityAt: 1, labels: [], queuedPrompts: [], ...more });
const prompt = (text, from) => ({ id: `e-${text}`, at: 1, kind: { userMessage: { _0: text, ...(from ? { from } : {}) } } });
const reply = { id: "r", at: 2, kind: { agentMessage: { text: "ok" } } };

test("only a prompt that will not queue is drawn as a bubble", () => {
  assert.equal(m.willQueue(agent()), false);
  assert.equal(m.willQueue(agent({ state: "running" })), true);
  assert.equal(m.willQueue(agent({ state: "queued" })), true);
  assert.equal(m.willQueue(agent({ queuedPrompts: [{ id: "q", text: "x", attachments: [] }] })), true);
});

test("the host's entry for the prompt takes its bubble away; any entry takes an answered one", () => {
  const going = [{ id: "1", text: "fix it", answered: false }, { id: "2", text: "and this", answered: true }];
  assert.deepEqual(m.landed(going, prompt(" fix it ")).map((s) => s.id), ["2"]);
  assert.deepEqual(m.landed(going, reply).map((s) => s.id), ["1"]);
  // Words the app sent are not the person's prompt.
  assert.deepEqual(m.landed(going, prompt("fix it", "app")).map((s) => s.id), ["1"]);
});

test("a prompt shows as a bubble at once, until its entry lands; one that did not go is taken away", async () => {
  const call = later();
  const link = fakeLink((method) => (method === "agents/prompt" ? call.promise : []));
  const store = new m.Store(link);
  store.say = () => {};
  store.replaceAgents([agent()], "mac");
  store.watch("mac", "A");
  const going = store.prompt("mac", "A", "fix it", []);
  assert.deepEqual(store.sendingTo("mac", "A").map((s) => s.text), ["fix it"]);
  call.resolve(null);
  assert.equal(await going, true);
  assert.deepEqual(store.sendingTo("mac", "A").map((s) => s.answered), [true]);
  link.notify("agent/entry", { agentID: "A", entry: prompt("fix it"), index: 0 }, "mac");
  assert.deepEqual(store.sendingTo("mac", "A"), []);

  const failing = new m.Store(fakeLink((method) => {
    if (method === "agents/prompt") throw new m.CallFailed(-32000, "Your Mac did not answer.");
    return [];
  }));
  failing.say = () => {};
  failing.replaceAgents([agent()], "mac");
  failing.watch("mac", "A");
  assert.equal(await failing.prompt("mac", "A", "fix it", []), false);
  assert.deepEqual(failing.sendingTo("mac", "A"), []);
});
