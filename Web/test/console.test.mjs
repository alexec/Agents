// What was the Console and Reports (#1804), each page in its section since #2141: their words and figures.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/console.ts");

test("Reports' pages are listed in Reports, in their order", async () => {
  const n = await load("src/model/nav.ts");
  assert.deepEqual(n.navPages.reports.slice(0, c.reportSections.length).map((p) => p.id), c.reportSections.map((s) => s.id));
});

const machine = (over = {}, host = {}) => ({
  host: { id: "H1", name: "Bea's Mac", platform: "macOS arm64", version: "0.9.0", state: "online", reach: "dialOut", ...host },
  ownerName: "Bea", bot: false, ...over,
});

test("Machines: out of date is missing, needing an update or older than the control plane", () => {
  assert.equal(c.compareVersions("0.8.2", "0.9.0"), -1);
  assert.equal(c.compareVersions("0.10.0", "0.9.0"), 1);
  assert.equal(c.compareVersions("0.9", "0.9.0"), 0);
  assert.equal(c.compareVersions("dev", "0.9.0"), 0);
  assert.equal(c.outOfDate(machine({}, { version: "0.8.0" }), "0.9.0"), true);
  assert.equal(c.outOfDate(machine({}, { state: "needsUpdate" }), "0.9.0"), true);
  assert.equal(c.outOfDate(machine({}, { missing: ["host.wire/2"] }), undefined), true);
  assert.equal(c.outOfDate(machine(), "0.9.0"), false);
});

test("Machines: filters, the summary and each row's words", () => {
  const list = [machine(), machine({ ownerName: "Nightly", bot: true }, { id: "H2", state: "offline", version: "0.8.0" }),
    machine({ ownerName: "", running: 3 }, { id: "H3", workspace: { providerName: "DigitalOcean" } })];
  assert.deepEqual(c.fleetShown(list, "offline", "0.9.0").map((m) => m.host.id), ["H2"]);
  assert.deepEqual(c.fleetShown(list, "outOfDate", "0.9.0").map((m) => m.host.id), ["H2"]);
  assert.equal(c.fleetShown(list, "all", "0.9.0").length, 3);
  assert.equal(c.fleetSummary(list, "0.9.0"), "3 machines · 2 online · 1 out of date");
  assert.deepEqual(list.map(c.ownerWords), ["Bea", "Nightly (bot)", "Nobody"]);
  assert.deepEqual(list.map(c.kindWords), ["macOS arm64", "macOS arm64", "DigitalOcean"]);
  assert.deepEqual(list.map(c.runningWords), ["—", "—", "3"]);
});

test("Report Policy: budgets as typed, and who may lead a group", () => {
  assert.equal(c.budgetValue("250"), 250);
  assert.equal(c.budgetValue(" $1,200.50 "), 1200.5);
  assert.equal(c.budgetValue(""), 0);
  assert.equal(c.budgetValue("ten"), null);
  assert.equal(c.budgetValue("1.234"), null);
  assert.equal(c.budgetInput(250), "250");
  assert.equal(c.budgetInput(99.5), "99.50");
  const people = [{ id: "a", kind: "person" }, { id: "b", kind: "person" }, { id: "bot", kind: "bot" }];
  assert.deepEqual(c.leadCandidates({ everyone: true, members: [] }, people).map((p) => p.id), ["a", "b"]);
  assert.deepEqual(c.leadCandidates({ everyone: false, members: ["b", "bot"] }, people).map((p) => p.id), ["b"]);
});

test("Requests: a channel identity's words", () => {
  assert.equal(c.linkWords({ identity: "U1", channel: "Slack", name: "Sam", email: "sam@acme.dev", forName: "Sam" }),
    "Sam (sam@acme.dev) on Slack wants to be linked to Sam");
  assert.equal(c.linkWords({ identity: "U1", channel: "Discord" }), "U1 on Discord wants to be linked");
});

test("Team Workflows: a bot's machines, spend and runs in words", () => {
  const bot = (over = {}) => ({ user: "b", name: "review-bot", spentTodayUSD: 4.2, capped: false, machines: 3, online: 2, workflows: [], live: [], ...over });
  assert.equal(c.machineWords(bot()), "2 of 3 machines online");
  assert.equal(c.machineWords(bot({ machines: 1, online: 1 })), "1 of 1 machine online");
  assert.equal(c.machineWords(bot({ machines: 0 })), "No machines");
  assert.equal(c.spendWords(bot({ caps: { dailyUSD: 50 } })), "$4.20 today of $50 a day");
  assert.equal(c.spendWords(bot()), "$4.20 today");
  assert.equal(c.spendWords(bot({ capped: true })), "At its cap until midnight UTC");
  assert.equal(c.runsWords(1), "1 run");
  assert.equal(c.runsWords(3), "3 runs");
});

test("Live Now (#2019, M9) says each agent's state and cost, and adds up the board", () => {
  const a = (agent, host, state, cost, extra = {}) => ({ host, hostName: host, owner: "p", ownerName: "Bea", bot: false, agent, runtime: "claude", state,
    costToDate: cost, ...extra });
  assert.equal(c.liveStateWords(a("A", "H", "waitingOnUser")), "Waiting for its person");
  assert.equal(c.liveStateWords(a("A", "H", "running", undefined, { waitsOnOthers: true })), "Waiting on others");
  assert.equal(c.liveStateWords(a("A", "H", "starting")), "Starting");
  assert.equal(c.liveStateWords(a("A", "H", "running")), "Working");
  assert.equal(c.liveCostWords(undefined), "Nothing yet");
  assert.match(c.liveCostWords({ USD: 4.2 }), /4\.20/);
  const board = { agents: [a("A", "H1", "running", { USD: 5 }), a("B", "H1", "running", { USD: 2.5 }), a("C", "H2", "running")] };
  assert.match(c.liveSummary(board), /^3 agents on 2 machines · .*7\.50 so far$/);
  assert.equal(c.liveSummary({ agents: [a("C", "H2", "running")] }), "1 agent on 1 machine");
  assert.deepEqual(c.liveMachines(board).map((m) => [m.host, m.agents.length]), [["H1", 2], ["H2", 1]]);
});

test("the Requests count has the people SCIM removed (#2436)", () => {
  assert.equal(c.waitingCount({ joins: 0, links: 0, capped: 0, governance: 0, removals: 2 }), 2);
  assert.equal(c.waitingCount({ joins: 1, links: 1, capped: 1, governance: 1, removals: 1 }), 5);
});

test("Live Now tells two agents apart by a short id, and Stop… names the one it stops (#2435)", () => {
  const a = { host: "H1", hostName: "Bea's Mac", owner: "p", ownerName: "Bea", bot: false, agent: "0f3c9a21-7d4e-4b8a-9c1d-2e5f6a7b8c9d",
    runtime: "claude", state: "running" };
  assert.equal(c.liveShortID(a), "0f3c9a21");
  assert.equal(c.liveStopLabel(a, "Claude"), "Stop Claude 0f3c9a21 on Bea's Mac");
  assert.match(c.liveStopQuestion(a, "Claude"), /^Stop Claude 0f3c9a21 on Bea's Mac \(Bea\)\? .*Bea reads that an admin stopped it\.$/);
});
