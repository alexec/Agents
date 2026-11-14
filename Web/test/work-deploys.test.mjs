// Work ▸ Deploys (#5270), as WorkDeploysTests has it on the window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const d = await load("src/model/workDeploys.ts");
const nav = await load("src/model/nav.ts");

// The wire's dates are seconds since 2001 (protocol/dates.ts); 8 Nov 2025, 10:51 UTC.
const t0 = (Date.UTC(2025, 10, 8, 10, 51) - Date.UTC(2001, 0, 1)) / 1000;

function target(component, env, tier, { labels, live = [], next = [] } = {}) {
  const t = { component: { system: "github", id: `alexec/agents/${component}`, name: component }, environment: { system: "github", name: env, tier } };
  if (labels) t.labels = labels;
  const deploy = (name, sha, state) => {
    const version = { artifacts: [{ kind: "commit", system: "github", id: sha }] };
    if (name) version.name = name;
    return { system: "github", id: sha, ref: `github:deploy:alexec/agents#${sha}`, target: t, version, state, url: `https://example.test/${sha}` };
  };
  return {
    target: t,
    live: live.map(([name, sha, share, since]) => ({ deploy: deploy(name, sha, "succeeded"), ...name ? { release: `github:release:alexec/agents#${name}` } : {}, since, share })),
    next: next.map(([name, state]) => ({ deploy: deploy(name, "ccc", state) })),
  };
}

test("the columns go in tier order and the rows by name", () => {
  const grid = d.deployGrid([
    target("Remote", "app-store", "production", { live: [["v0.18.0", "aaa", 100, t0]] }),
    target("Remote", "testflight", "testing", { live: [["v0.18.0", "aaa", 100, t0]] }),
    target("Mac app", "github-releases", "production", { live: [["v0.18.0", "aaa", 100, t0]] }),
    target("Docs", "github-pages", "production", { live: [[undefined, "1357c99abc", 100, t0]] }),
  ]);
  assert.deepEqual(grid.columns.map((c) => c.name), ["testflight", "app-store", "github-pages", "github-releases"]);
  assert.deepEqual(grid.rows.map((r) => r.name), ["Docs", "Mac app", "Remote"]);
  assert.deepEqual(grid.rows[2].cells.map((c) => c.length), [1, 1, 0, 0]);
  assert.equal(d.versionWords(grid.rows[0].cells[2][0].live[0].deploy.version), "1357c99");
  assert.equal(d.tierChip("production"), "production");
  assert.equal(d.tierChip("testing"), undefined);
});

test("the words, as the window's", () => {
  assert.equal(d.sinceWords(t0, true), "since 8 Nov, 10:51");
  assert.equal(d.shareWords(100), undefined);
  assert.equal(d.shareWords(90), "90 %");
  assert.equal(d.shareWords(12.5), "12.5 %");
  const canary = target("Remote", "production", "production", { labels: { region: "eu" },
    live: [["v0.18.0", "aaa", 90, t0], ["v0.19.0", "bbb", 10, t0]], next: [["v0.20.0", "waiting"]] });
  assert.equal(d.labelsLine(canary.target), "region eu");
  assert.equal(d.nextWords(canary.next[0]), "next: v0.20.0, waiting");
  assert.equal(d.jobOf(canary), "https://example.test/ccc");
  assert.equal(d.cellLabel("Remote", "production", [canary], true),
    "Remote in production: region eu, v0.18.0 live at 90 % since 8 Nov, 10:51, v0.19.0 live at 10 % since 8 Nov, 10:51, next: v0.20.0, waiting");
  assert.equal(d.cellLabel("Docs", "testflight", []), "Docs in testflight: none");
});

test("two machines keep the newer target", () => {
  const old = target("Remote", "testflight", "testing", { live: [["v0.17.0", "aaa", 100, t0]] });
  const fresh = target("Remote", "testflight", "testing", { live: [["v0.18.0", "bbb", 100, t0 + 60]] });
  const docs = target("Docs", "github-pages", "production", { live: [[undefined, "ddd", 100, t0]] });
  assert.deepEqual(d.mergeTargets([[old, docs], [fresh]]).map((t) => t.live[0].deploy.version.name), ["v0.18.0", undefined]);
  assert.deepEqual(d.mergeTargets([[fresh], [old]]).map((t) => t.live[0].deploy.version.name), ["v0.18.0"]);
});

test("Deploys is a page of Work, after Releases and before Timeline", () => {
  const ids = nav.navPages.work.map((p) => p.id);
  assert.equal(ids.indexOf("deploys"), ids.indexOf("release") + 1);
  assert.equal(ids.indexOf("timeline"), ids.indexOf("deploys") + 1);
});
