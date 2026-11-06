// The outer loop's line on a Work page (#3588), as PipelineTests has it on the window: from an issue
// to its deploy and health, and back.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const p = await load("src/model/pipeline.ts");

const issue = { kind: "issue", ref: "github:alexec/Agents#10" };
const pr = { kind: "pr", ref: "github:alexec/Agents#12" };
const release = { kind: "release", ref: "github:alexec/Agents/release/v1.2.0" };
const run = { kind: "ci-run", ref: "github:alexec/Agents/actions/run/987" };
const build = { kind: "deploy", ref: "testflight:com.example.app/42" };
const crash = { kind: "health", ref: "sentry:acme/4321" };
const bug = { kind: "issue", ref: "github:alexec/Agents#20" };
const link = (from, rel, to) => ({ from, to, rel, source: "forge", at: 0 });
const graph = {
  nodes: [issue, pr, release, run, build, crash, bug],
  links: [
    link(pr, "fixes", issue), link(pr, "part-of", release), link(run, "builds", release),
    link(release, "deployed-as", build), link(crash, "seen-in", release), link(crash, "seen-in", build),
    link(bug, "reports", crash),
  ],
};
const words = (steps) => steps.map((s) => s.words);

test("an issue reaches its release, CI run, build and the Sentry issue seen in it, each with a link out", () => {
  const steps = p.pipelineSteps(issue, graph);
  assert.deepEqual(words(steps), ["Release v1.2.0", "CI run", "TestFlight 42", "Sentry issue 4321"]);
  assert.deepEqual(steps.map((s) => s.url), [
    "https://github.com/alexec/Agents/releases/tag/v1.2.0",
    "https://github.com/alexec/Agents/actions/runs/987",
    "https://appstoreconnect.apple.com/apps",
    "https://sentry.io/organizations/acme/issues/4321/",
  ]);
});

test("a PR reaches the same stages", () => {
  assert.deepEqual(words(p.pipelineSteps(pr, graph)), ["Release v1.2.0", "CI run", "TestFlight 42", "Sentry issue 4321"]);
});

test("a bug from Sentry leads back to the release, its PRs and the issues they fix", () => {
  assert.deepEqual(words(p.pipelineSteps(bug, graph)), ["From Sentry issue 4321", "seen in v1.2.0", "TestFlight 42", "PR #12", "#10"]);
});

test("a release says what it came from and where it went", () => {
  assert.deepEqual(words(p.pipelineSteps(release, graph)), ["PR #12", "#10", "CI run", "TestFlight 42", "Sentry issue 4321"]);
});

test("nothing in reach is no line", () => {
  assert.deepEqual(p.pipelineSteps(issue, { nodes: [issue], links: [] }), []);
});

test("many of a kind name the first three and count the rest", () => {
  const crashes = [1, 2, 3, 4, 5].map((i) => ({ kind: "health", ref: `sentry:acme/${i}` }));
  const steps = p.pipelineSteps(pr, { nodes: [], links: [link(pr, "part-of", release), ...crashes.map((c) => link(c, "seen-in", release))] });
  assert.deepEqual(words(steps), ["Release v1.2.0", "Sentry issue 1", "Sentry issue 2", "Sentry issue 3", "2 more"]);
  assert.equal(steps.at(-1).url, undefined);
});

test("a GitLab pipeline has its page", () => {
  assert.equal(p.stageUrl({ kind: "ci-run", ref: "gitlab:group/app/pipelines/55" }), "https://gitlab.com/group/app/-/pipelines/55");
});

test("a Cloud Run revision is named and has its service's revisions", () => {
  const rev = { kind: "deploy", ref: "cloudrun:acme-prod/us-central1/web/web-42" };
  const steps = p.pipelineSteps(pr, { nodes: [], links: [link(pr, "part-of", release), link(release, "deployed-as", rev)] });
  assert.deepEqual(words(steps), ["Release v1.2.0", "Cloud Run web-42"]);
  assert.equal(steps.at(-1).url, "https://console.cloud.google.com/run/detail/us-central1/web/revisions?project=acme-prod");
  assert.equal(p.stageUrl({ kind: "deploy", ref: "cloudrun:acme-prod/web/web-42" }), undefined);
});
