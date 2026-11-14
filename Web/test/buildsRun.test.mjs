// Reports ▸ Planning ▸ Builds ▸ one run (#5179, spec 5166 board 3): the address, the Gantt rows, the step diff.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const b = await load("src/model/builds.ts");
const d = await load("src/model/buildsRun.ts");

const step = (name, number, started, ended) => ({ name, number, started, ended });
const job = (name, made, started, ended, steps = [], runner = "ubuntu-latest") => ({ name, made, started, ended, runner, steps, conclusion: "success" });
const run = (o) => ({ ref: "github:run:alexec/agents#2", id: 2, attempt: 1, workflow: "ci.yml", branch: "main", headSha: "3735339abc", made: 0,
  started: 150, turn: 150, ended: 650, jobs: [], ...o });

// The spec's case: go-darwin's Vet 16 s → 1.6 min and Test 3.9 → 5.0 min.
const after = run({ jobs: [
  job("go-darwin", 160, 163, 650, [step("Set up job", 1, 163, 165), step("Vet", 2, 165, 261), step("Test", 3, 261, 561), step("Post", 4, 561, 650)], "macos-latest"),
  job("lint", 150, 152, 300, [step("Set up job", 1, 152, 154), step("Lint", 2, 154, 300)]),
  job("skew", 160, 164, 200),
] });
const before = run({ ref: "github:run:alexec/agents#1", id: 1, headSha: "efd532a999", ended: 620, turn: 100, jobs: [
  job("go-darwin", 110, 113, 520, [step("Set up job", 1, 113, 115), step("Vet", 2, 115, 131), step("Test", 3, 131, 365), step("Post", 4, 365, 520)], "macos-latest"),
  job("lint", 100, 102, 280, [step("Set up job", 1, 102, 104), step("Lint", 2, 104, 280)]),
  job("packages", 100, 110, 140),
] });

test("the address keeps a run opened, the run to compare it with and the job picked", () => {
  const ask = { repo: "github:alexec/agents", range: "month", branch: "", p90: false,
    drill: { ref: "github:run:alexec/agents#2", against: "github:run:alexec/agents#1", job: "go-darwin" } };
  const q = b.buildsQuery(ask);
  assert.match(q, /drill=github:run:alexec\/agents%232&against=.*&of=go-darwin/);
  assert.deepEqual(b.parseBuildsQuery(q), { ...ask, workflow: undefined, job: undefined, change: undefined });
  // From a change: the change and the run share the job.
  const fromChange = { ...ask, change: { job: "go-darwin", ref: "github:run:alexec/agents#2" } };
  assert.deepEqual(b.parseBuildsQuery(b.buildsQuery(fromChange)), { ...fromChange, workflow: undefined, job: undefined });
});

test("the Gantt chart has a row a job in the order made, step ticks, long steps named, and the run before as an outline", () => {
  const g = d.gantt(after, before, "go-darwin");
  assert.equal(g.turn, 150);
  assert.equal(g.end, 650);
  assert.deepEqual(g.rows.map((r) => r.name), ["lint", "go-darwin", "skew"]);
  const go = g.rows[1];
  assert.equal(go.picked, true);
  assert.deepEqual(go.ticks, [165, 261, 561]);
  assert.deepEqual(go.named.map((s) => s.name), ["Vet", "Test", "Post"]);
  assert.deepEqual(go.before, { made: 110, ended: 520 });
  assert.equal(g.rows[2].before, undefined, "skew is not in the run before");
});

test("the steps that changed most: the picked job's first, by size; a job in one run only is named, not compared", () => {
  const { rows, only } = d.stepChanges(after, before, "go-darwin");
  assert.deepEqual(rows.slice(0, 4).map((r) => [r.job, r.step, r.change]), [
    ["go-darwin", "Vet", 80], ["go-darwin", "Test", 66], ["go-darwin", "Post", -66], ["go-darwin", "Set up job", 0]]);
  assert.deepEqual(rows.slice(4).map((r) => r.step), ["Lint", "Set up job"]);
  assert.deepEqual(only, [{ job: "skew", in: "this" }, { job: "packages", in: "before" }]);
  assert.deepEqual(d.onlyWords(only), ["Only in this run, not compared: skew.", "Only in the run before, not compared: packages."]);
});

test("a renamed step is matched by its number", () => {
  const a = run({ jobs: [job("go", 0, 1, 50, [step("Test (race)", 1, 1, 50)])] });
  const z = run({ jobs: [job("go", 0, 1, 40, [step("Test", 1, 1, 40)])] });
  assert.deepEqual(d.stepChanges(a, z, undefined).rows.map((r) => [r.step, r.change]), [["Test (race)", 10]]);
});

test("the words: the run's line, a change, the axis and the queue panel", () => {
  assert.equal(d.runLine(after, before, "8 Nov 16:51"),
    "ci on main, 8 Nov 16:51 · time to green 10.8 min (run 8.3 min, queue 2.5 min) · against efd532a, 10.3 min");
  assert.match(d.runLine(after, undefined, "8 Nov"), /no run before it to compare with$/);
  assert.equal(d.changeWords(83), "+83 s");
  assert.equal(d.changeWords(-1), "−1 s");
  assert.equal(d.changeWords(0), "±0 s");
  assert.equal(d.changeWords(150), "+2.5 min");
  assert.deepEqual(d.ganttTicks(650), [0, 120, 240, 360, 480, 600]);
  assert.equal(d.tickWords(120), "2 min");
  assert.equal(d.tickWords(0), "0 min");
  assert.equal(d.stepsHeading("go-darwin"), "Steps that changed most, against the run before: go-darwin first");
  const w = { run: { ref: "r", id: 1, attempt: 1, made: 0 }, job: "packages", wait: 1524, ran: 12 };
  assert.match(d.queuePanelWords(w, "8 Oct 09:12", "xcode-27"), /^On 8 Oct 09:12, packages waited 25.4 min for a runner \(xcode-27\), then ran for 12 s\./);
  assert.equal(d.ownWaitShort(after), true);
  assert.equal(d.attemptWords(1, 1), null);
  assert.match(d.attemptWords(1, 2), /^Attempt 1 of 2\./);
});
