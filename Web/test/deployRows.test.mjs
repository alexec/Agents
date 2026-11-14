// Deployed on a release's page and Live in on a pull request's (#5243, spec 5239-deploy-model boards 1 to 3).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const d = await load("src/model/deployRows.ts");

const now = new Date(2026, 10, 14, 12, 0);
// A WireDate: seconds since 2001 (protocol/dates.ts).
const local = (day, h, m) => new Date(2026, 10, day, h, m).getTime() / 1000 - 978307200;
const release = { kind: "release", ref: "github:release:alexec/agents#v0.18.0" };
const older = { kind: "release", ref: "github:release:alexec/agents#v0.17.0" };
const pr = { kind: "pr", ref: "github:alexec/agents#3983" };
const env = (name) => ({ kind: "environment", ref: `github:environment:alexec/agents#${name}` });
const dep = (id) => ({ kind: "deploy", ref: `github:deploy:alexec/agents#${id}` });
const link = (from, rel, to) => ({ from, to, rel, source: "forge", at: 0 });

function deploy(id, { name, state = "succeeded", started, finished, tier = "production", component, run = 500 }) {
  return {
    system: "github", id: String(id), state, rawState: state,
    target: { component: { system: "github", id: "alexec/agents", ...(component ? { name: component } : {}) },
      environment: { system: "github", name: "release", tier } },
    version: { artifacts: [{ kind: "commit", system: "github", id: "4566fb8e9abc" }], ...(name ? { name } : {}) },
    ...(started ? { started } : {}), ...(finished ? { finished } : {}),
    url: `https://github.com/alexec/Agents/actions/runs/${run}/job/9`,
  };
}

test("a release's Deployed: a row for each environment, its newest deploy there, in name order", () => {
  const g = {
    nodes: [],
    links: [
      link(dep(1), "deploys", release), link(dep(1), "part-of", env("testflight")),
      link(dep(2), "deploys", release), link(dep(2), "part-of", env("app-store")),
      link(dep(3), "deploys", release), link(dep(3), "part-of", env("testflight")),
    ],
    resolved: {
      [dep(1).ref]: { title: "v0.18.0 to testflight", state: "failed", deploy: deploy(1, { name: "v0.18.0", state: "failed", tier: "testing",
        started: local(8, 9, 0), finished: local(8, 9, 21) }) },
      [dep(2).ref]: { title: "v0.18.0 to app-store", state: "succeeded", deploy: deploy(2, { name: "v0.18.0", component: "Remote",
        started: local(8, 10, 22), finished: local(8, 10, 52) }) },
      [dep(3).ref]: { title: "v0.18.0 to testflight", state: "succeeded", deploy: deploy(3, { name: "v0.18.0", tier: "testing",
        started: local(8, 9, 54), finished: local(8, 10, 51) }) },
    },
  };
  const rows = d.deployedRows(release, g, now);
  assert.deepEqual(rows.map((r) => [r.environment, r.tier, r.component, r.state, r.line, r.more]), [
    ["app-store", "production", "Remote", "live", "Remote 0.18.0 · since 8 Nov, 10:52", "went out in 30 min"],
    ["testflight", undefined, undefined, "live", "v0.18.0 · since 8 Nov, 10:51", "went out in 57 min"],
  ]);
});

test("an older release's row says it was replaced, by what, and when it was live", () => {
  const g = {
    nodes: [],
    links: [
      link(dep(1), "deploys", older), link(dep(1), "part-of", env("app-store")),
      link(dep(2), "part-of", env("app-store")), link(env("app-store"), "live", dep(2)),
    ],
    resolved: {
      [dep(1).ref]: { title: "v0.17.0 to app-store", state: "replaced", deploy: deploy(1, { name: "v0.17.0", component: "Remote",
        started: local(7, 12, 0), finished: local(7, 12, 17) }) },
      [dep(2).ref]: { title: "v0.18.0 to app-store", state: "succeeded", deploy: deploy(2, { name: "v0.18.0",
        started: local(8, 10, 22), finished: local(8, 10, 52) }) },
    },
  };
  const [row] = d.deployedRows(older, g, now);
  assert.equal(row.state, "replaced");
  assert.equal(row.line, "Remote 0.17.0 · live 7 Nov, 12:17 to 8 Nov, 10:52");
  assert.equal(row.more, "replaced by v0.18.0");
});

test("waiting, going out, failed, cancelled and rollback rows", () => {
  const rows = (resolved) => d.deployedRows(release, {
    nodes: [], links: [link(dep(1), "deploys", release), link(dep(1), "part-of", env("app-store"))], resolved: { [dep(1).ref]: resolved },
  }, now);
  const at = local(14, 11, 32);
  const [waiting] = rows({ title: "", state: "waiting", deploy: deploy(1, { name: "v0.18.0", state: "waiting", started: at, run: 77 }) });
  assert.deepEqual([waiting.state, waiting.line, waiting.gate], ["waiting", "v0.18.0 · waiting for approval for 28 min", "alexec/Agents/77"]);
  const [running] = rows({ title: "", state: "running", deploy: deploy(1, { name: "v0.18.0", state: "running", started: at }) });
  assert.equal(running.line, "v0.18.0 · going out for 28 min");
  const [failed] = rows({ title: "", state: "failed", deploy: deploy(1, { name: "v0.18.0", state: "failed", started: at, finished: at + 21 * 60 }) });
  assert.deepEqual([failed.line, failed.more, failed.url], ["v0.18.0 · failed after 21 min", "the job’s log ↗",
    "https://github.com/alexec/Agents/actions/runs/500/job/9"]);
  const [cancelled] = rows({ title: "", state: "cancelled", deploy: deploy(1, { name: "v0.18.0", state: "cancelled", started: at, finished: at + 40 }) });
  assert.equal(cancelled.line, "v0.18.0 · cancelled after 40 s");
  const [rollback] = rows({ title: "", state: "succeeded", labels: ["rollback", "share:10"],
    deploy: deploy(1, { name: "v0.18.0", started: local(14, 14, 0), finished: local(14, 14, 5) }) });
  assert.deepEqual([rollback.state, rollback.line, rollback.more], ["rollback", "v0.18.0 · since 14:05", "went out in 5 min · 10 % of the traffic"]);
});

test("a pull request is live where its release went, and stays live there when a newer one replaces it", () => {
  const merged = new Date(2026, 10, 7, 17, 3);
  const g = {
    nodes: [],
    links: [
      link(pr, "part-of", release),
      link(dep(1), "deploys", release), link(dep(1), "part-of", env("app-store")),
      link(dep(2), "brings", pr), link(dep(2), "part-of", env("github-pages")),
    ],
    resolved: {
      [dep(1).ref]: { title: "v0.18.0 to app-store", state: "replaced", deploy: deploy(1, { name: "v0.18.0", component: "Remote",
        started: local(8, 10, 22), finished: local(8, 10, 51) }) },
      [dep(2).ref]: { title: "1357c99 to github-pages", state: "succeeded", deploy: { ...deploy(2, { started: local(7, 17, 3), finished: local(7, 17, 3) + 42 }),
        version: { artifacts: [{ kind: "commit", system: "github", id: "1357c99aaaa" }] } } },
    },
  };
  const rows = d.liveInRows(pr, g, now, merged);
  assert.deepEqual(rows.map((r) => [r.environment, r.state, r.line, r.more]), [
    ["app-store", "live", "Remote 0.18.0 · 17 h 48 min after merge", "since 8 Nov, 10:51, with v0.18.0"],
    ["github-pages", "live", "1357c99 · 42 s after merge", "since 7 Nov, 17:03, with 1357c99"],
  ]);
  assert.deepEqual(d.liveInRows(pr, { nodes: [], links: [] }, now, merged), []);
});

test("words", () => {
  assert.deepEqual([d.spanWords(42), d.spanWords(28 * 60), d.spanWords(17 * 3600 + 48 * 60), d.spanWords(3 * 86400)], ["42 s", "28 min", "17 h 48 min", "3 d"]);
  assert.equal(d.targetsWords(1), "1 target");
  assert.equal(d.gateKey("https://gitlab.com/x/y/-/jobs/1"), undefined);
});
