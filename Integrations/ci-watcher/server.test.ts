// The CI watcher in its fake mode, on stdio, against a copy of fixtures/ci.json.
// Nothing here calls gh or GitHub.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, copyFileSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";

const here = dirname(fileURLToPath(import.meta.url));
const REPO = "alexec/Agents";
let scratch = "";
let fixture = "";
let server: ChildProcess | undefined;
const waiting = new Map<number, (message: any) => void>();

before(async () => {
  scratch = mkdtempSync(join(tmpdir(), "ci-watcher-test-"));
  fixture = join(scratch, "ci.json");
  copyFileSync(join(here, "fixtures", "ci.json"), fixture);
  server = spawn(process.execPath, [join(here, "server.ts")], {
    env: { ...process.env, CI_WATCHER_FAKE: fixture, PATH: "/nonexistent" },
    stdio: ["pipe", "pipe", "inherit"],
  });
  createInterface({ input: server.stdout! }).on("line", (line) => {
    const message = JSON.parse(line);
    waiting.get(message.id)?.(message);
    waiting.delete(message.id);
  });
});

after(() => {
  server?.kill();
  rmSync(scratch, { recursive: true, force: true });
});

// The fixture as it is now, changed by `change`, written back.
function edit(change: (data: any) => void) {
  const data = JSON.parse(readFileSync(fixture, "utf8"));
  change(data);
  writeFileSync(fixture, JSON.stringify(data, null, 2));
}
const repoData = (data: any) => data.repos[REPO];
const read = () => JSON.parse(readFileSync(fixture, "utf8"));

let nextID = 1;
function send(message: unknown) {
  server!.stdin!.write(JSON.stringify(message) + "\n");
}
function rpc(method: string, params: unknown = {}): Promise<any> {
  const id = nextID++;
  return new Promise((resolve) => {
    waiting.set(id, resolve);
    send({ jsonrpc: "2.0", id, method, params });
  });
}
async function ok(method: string, params: unknown = {}) {
  const body = await rpc(method, params);
  assert.equal(body.error, undefined, JSON.stringify(body.error));
  return body.result;
}
const poll = (name: string, args: unknown, cursor: string | null, maxEvents = 50) =>
  ok("events/poll", { name, arguments: args, cursor, maxEvents });
const now = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();
const cursorAt = (since: string) => Buffer.from(JSON.stringify({ since, ids: [] })).toString("base64url");

function failedRun(id: number, branch: string, updatedAt: string, attempt = 1, pr = 402) {
  return {
    id, attempt, name: "CI", url: `https://github.com/${REPO}/actions/runs/${id}`,
    event: "pull_request", status: "completed", conclusion: "failure",
    branch, headSha: `sha${id}`, pr, updatedAt,
    jobs: [
      { name: "test", url: `https://github.com/${REPO}/actions/runs/${id}/job/1`, conclusion: "failure", log: "boom" },
      { name: "check", url: `https://github.com/${REPO}/actions/runs/${id}/job/2`, conclusion: "success", log: "fine" },
    ],
  };
}

test("initialize gives the contract's capabilities", async () => {
  const result = await ok("initialize",
    { protocolVersion: "2026-07-28", capabilities: {}, clientInfo: { name: "t", version: "1" } });
  assert.equal(result.protocolVersion, "2026-07-28");
  assert.deepEqual(result.capabilities, {
    tools: {}, resources: {}, events: { listChanged: false },
    extensions: { "io.modelcontextprotocol/ui": {} },
  });
  assert.equal(result.serverInfo.name, "ci-watcher");
  const older = await ok("initialize", { protocolVersion: "2025-06-18", capabilities: {} });
  assert.equal(older.protocolVersion, "2025-06-18");
});

test("a notification is answered with nothing", async () => {
  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  // The next request's answer is the next line: nothing came for the notification.
  assert.deepEqual(await ok("ping"), {});
});

test("events/list gives every event, poll only, with their schemas", async () => {
  const { events } = await ok("events/list");
  assert.deepEqual(events.map((e: any) => e.name).sort(),
    ["checks.failed", "issue.closed", "issue.commented", "issue.labelled", "issue.opened", "pr.closed", "pr.merged"]);
  for (const e of events) {
    assert.deepEqual(e.delivery, ["poll"]);
    assert.ok(e.description);
    assert.equal(e.inputSchema.type, "object");
    assert.deepEqual(e.inputSchema.required, []);
    assert.equal(e.inputSchema.properties.repo.type, "string");
    assert.equal(e.payloadSchema.type, "object");
  }
  for (const e of events.filter((e: any) => e.name.startsWith("issue."))) {
    assert.equal(e.inputSchema.properties.label.type, "string");
    assert.equal(e.inputSchema.properties.issue?.type, e.name === "issue.opened" ? undefined : "integer");
    assert.equal(e.payloadSchema.properties.issue.type, "object");
  }
  for (const e of events.filter((e: any) => !e.name.startsWith("issue."))) {
    assert.equal(e.inputSchema.properties.branch.type, "string");
    assert.equal(e.inputSchema.properties.pr.type, "integer");
    assert.ok(e.inputSchema.properties.pr.description);
  }
});

test("cursor null gives no events and a cursor", async () => {
  const result = await poll("checks.failed", { repo: REPO }, null);
  assert.deepEqual(result.events, []);
  assert.equal(typeof result.cursor, "string");
  assert.equal(result.truncated, false);
  assert.equal(result.hasMore, false);
  assert.equal(result.nextPollMs, 30000);
});

test("an appended failed run gives one checks.failed, and a second attempt a new id", async () => {
  const first = await poll("checks.failed", { repo: REPO }, null);
  edit((d) => repoData(d).runs.push(failedRun(9100, "agents/queue-helpers", now(5))));
  const raised = await poll("checks.failed", { repo: REPO }, first.cursor);
  assert.equal(raised.events.length, 1);
  const [event] = raised.events;
  assert.equal(event.eventId, `checks.failed:${REPO}:9100:1`);
  assert.equal(event.name, "checks.failed");
  assert.ok(Date.parse(event.timestamp));
  assert.deepEqual(event.data, {
    pr: { number: 402, title: "Queue helpers past the limit", branch: "agents/queue-helpers",
      url: `https://github.com/${REPO}/pull/402` },
    headSha: "sha9100",
    run: { id: 9100, attempt: 1, name: "CI", url: `https://github.com/${REPO}/actions/runs/9100` },
    failedJobs: [{ name: "test", url: `https://github.com/${REPO}/actions/runs/9100/job/1` }],
  });

  const quiet = await poll("checks.failed", { repo: REPO }, raised.cursor);
  assert.deepEqual(quiet.events, []);

  edit((d) => {
    const run = repoData(d).runs.find((r: any) => r.id === 9100);
    run.attempt = 2;
    run.updatedAt = now(1000);
  });
  const again = await poll("checks.failed", { repo: REPO }, quiet.cursor);
  assert.deepEqual(again.events.map((e: any) => e.eventId), [`checks.failed:${REPO}:9100:2`]);
});

test("pr.merged", async () => {
  const first = await poll("pr.merged", { repo: REPO }, null);
  edit((d) => {
    const pr = repoData(d).prs.find((p: any) => p.number === 401);
    Object.assign(pr, { state: "merged", mergedAt: now(5), mergeSha: "abc401", updatedAt: now(5) });
  });
  const raised = await poll("pr.merged", { repo: REPO }, first.cursor);
  assert.equal(raised.events.length, 1);
  const [event] = raised.events;
  assert.equal(event.eventId, `pr.merged:${REPO}:401`);
  assert.deepEqual(event.data.pr, { number: 401, title: "Make the sidebar fold faster",
    branch: "agents/fold-faster", url: `https://github.com/${REPO}/pull/401` });
  assert.equal(event.data.mergeSha, "abc401");
  assert.ok(Date.parse(event.data.mergedAt));
  const quiet = await poll("pr.merged", { repo: REPO }, raised.cursor);
  assert.deepEqual(quiet.events, []);
});

test("pr.closed: closed without merging, not merged", async () => {
  const args = { repo: REPO, pr: 408 };
  const [first, firstMerged] = await Promise.all(["pr.closed", "pr.merged"].map((n) => poll(n, args, null)));
  const closedAt = now(5);
  edit((d) => repoData(d).prs.push(openPR(408, "agents/pr-408", { state: "closed", closedAt, updatedAt: closedAt })));
  const raised = await poll("pr.closed", args, first.cursor);
  assert.deepEqual(raised.events.map((e: any) => e.eventId), [`pr.closed:${REPO}:408:${closedAt}`]);
  assert.equal(raised.events[0].data.pr.branch, "agents/pr-408");
  assert.equal(raised.events[0].data.closedAt, closedAt);
  const notMerged = await poll("pr.merged", args, firstMerged.cursor);
  assert.deepEqual(notMerged.events, []);
  const quiet = await poll("pr.closed", args, raised.cursor);
  assert.deepEqual(quiet.events, []);
});

test("repo left out is the project's", async () => {
  const first = await poll("pr.merged", {}, null);
  edit((d) => repoData(d).prs.push(openPR(407, "agents/pr-407", { state: "merged", mergedAt: now(5), mergeSha: "abc", updatedAt: now(5) })));
  const raised = await poll("pr.merged", { pr: 407 }, first.cursor);
  assert.deepEqual(raised.events.map((e: any) => e.eventId), [`pr.merged:${REPO}:407`]);
  const list = await ok("tools/call", { name: "list_prs", arguments: {} });
  assert.ok(list.structuredContent.prs.length > 0);
  edit((d) => { d.repos["someone/else"] = { prs: [], runs: [], issues: [] }; });
  const none = await rpc("events/poll", { name: "checks.failed", arguments: {}, cursor: null });
  assert.equal(none.error.code, -32602);
  assert.match(none.error.message, /repo is needed/);
  edit((d) => { delete d.repos["someone/else"]; });
});

test("branch narrows", async () => {
  const args = { repo: REPO, branch: "agents/narrow-me" };
  const first = await poll("checks.failed", args, null);
  edit((d) => repoData(d).runs.push(
    failedRun(9200, "agents/narrow-me", now(5)),
    failedRun(9201, "agents/someone-else", now(5))));
  const raised = await poll("checks.failed", args, first.cursor);
  assert.deepEqual(raised.events.map((e: any) => e.eventId), [`checks.failed:${REPO}:9200:1`]);
});

function openPR(number: number, branch: string, extra: object = {}) {
  return { number, title: `PR ${number}`, branch, url: `https://github.com/${REPO}/pull/${number}`,
    state: "open", updatedAt: now(), ...extra };
}

test("pr narrows checks.failed, and with branch both must hold", async () => {
  edit((d) => repoData(d).prs.push(openPR(403, "agents/pr-403"), openPR(404, "agents/pr-404")));
  const args = { repo: REPO, pr: 403 };
  const both = { repo: REPO, pr: 403, branch: "agents/pr-403" };
  const crossed = { repo: REPO, pr: 404, branch: "agents/pr-403" };
  const [first, firstBoth, firstCrossed] = await Promise.all(
    [args, both, crossed].map((a) => poll("checks.failed", a, null)));
  edit((d) => repoData(d).runs.push(
    failedRun(9400, "agents/pr-403", now(5), 1, 403),
    failedRun(9401, "agents/pr-404", now(5), 1, 404)));
  const raised = await poll("checks.failed", args, first.cursor);
  assert.deepEqual(raised.events.map((e: any) => e.eventId), [`checks.failed:${REPO}:9400:1`]);
  assert.equal(raised.events[0].data.pr.number, 403);
  const quiet = await poll("checks.failed", args, raised.cursor);
  assert.deepEqual(quiet.events, []);
  const narrowed = await poll("checks.failed", both, firstBoth.cursor);
  assert.deepEqual(narrowed.events.map((e: any) => e.eventId), [`checks.failed:${REPO}:9400:1`]);
  const none = await poll("checks.failed", crossed, firstCrossed.cursor);
  assert.deepEqual(none.events, []);
});

test("pr and branch narrow pr.merged", async () => {
  const byPR = { repo: REPO, pr: 405 };
  const byBranch = { repo: REPO, branch: "agents/pr-406" };
  const crossed = { repo: REPO, pr: 405, branch: "agents/pr-406" };
  const [first, firstBranch, firstCrossed] = await Promise.all(
    [byPR, byBranch, crossed].map((a) => poll("pr.merged", a, null)));
  const merged = { state: "merged", mergedAt: now(5), mergeSha: "abc", updatedAt: now(5) };
  edit((d) => repoData(d).prs.push(openPR(405, "agents/pr-405", merged), openPR(406, "agents/pr-406", merged)));
  const raised = await poll("pr.merged", byPR, first.cursor);
  assert.deepEqual(raised.events.map((e: any) => e.eventId), [`pr.merged:${REPO}:405`]);
  const branched = await poll("pr.merged", byBranch, firstBranch.cursor);
  assert.deepEqual(branched.events.map((e: any) => e.eventId), [`pr.merged:${REPO}:406`]);
  const none = await poll("pr.merged", crossed, firstCrossed.cursor);
  assert.deepEqual(none.events, []);
});

const issueAt = (d: any, number: number) => repoData(d).issues.find((i: any) => i.number === number);
function newIssue(number: number, labels: string[], createdAt: string) {
  return { number, title: `Issue ${number}`, author: "someone", labels, url: `https://github.com/${REPO}/issues/${number}`,
    state: "open", createdAt, updatedAt: createdAt, comments: [], events: [] };
}

test("issue.opened, narrowed by label", async () => {
  const [first, firstBug] = await Promise.all([{ repo: REPO }, { repo: REPO, label: "bug" }].map((a) => poll("issue.opened", a, null)));
  edit((d) => repoData(d).issues.push(newIssue(420, ["bug"], now(5)), newIssue(421, [], now(5))));
  const raised = await poll("issue.opened", { repo: REPO }, first.cursor);
  assert.deepEqual(raised.events.map((e: any) => e.eventId), [`issue.opened:${REPO}:420`, `issue.opened:${REPO}:421`]);
  assert.deepEqual(raised.events[0].data.issue, { number: 420, title: "Issue 420", author: "someone", labels: ["bug"],
    url: `https://github.com/${REPO}/issues/420` });
  assert.ok(Date.parse(raised.events[0].data.openedAt));
  const bugs = await poll("issue.opened", { repo: REPO, label: "bug" }, firstBug.cursor);
  assert.deepEqual(bugs.events.map((e: any) => e.data.issue.number), [420]);
  const quiet = await poll("issue.opened", { repo: REPO }, raised.cursor);
  assert.deepEqual(quiet.events, []);
});

test("issue.labelled matches the label added, issue.closed gives its reason", async () => {
  const [labelled, closed, other] = await Promise.all([
    poll("issue.labelled", { repo: REPO, label: "expedite" }, null),
    poll("issue.closed", { repo: REPO, issue: 411 }, null),
    poll("issue.closed", { repo: REPO, issue: 410 }, null),
  ]);
  edit((d) => {
    const i = issueAt(d, 411);
    i.labels.push("expedite");
    i.events.push({ id: 8100, event: "labeled", label: "expedite", actor: "alexec", createdAt: now(5) },
      { id: 8101, event: "labeled", label: "enhancement", actor: "alexec", createdAt: now(5) },
      { id: 8102, event: "closed", reason: "not_planned", actor: "alexec", createdAt: now(6) });
    i.state = "closed";
  });
  const raisedLabel = await poll("issue.labelled", { repo: REPO, label: "expedite" }, labelled.cursor);
  assert.deepEqual(raisedLabel.events.map((e: any) => e.eventId), [`issue.labelled:${REPO}:8100`]);
  assert.equal(raisedLabel.events[0].data.label, "expedite");
  assert.equal(raisedLabel.events[0].data.by, "alexec");
  const raisedClosed = await poll("issue.closed", { repo: REPO, issue: 411 }, closed.cursor);
  assert.deepEqual(raisedClosed.events.map((e: any) => e.eventId), [`issue.closed:${REPO}:8102`]);
  assert.equal(raisedClosed.events[0].data.reason, "not_planned");
  assert.deepEqual((await poll("issue.closed", { repo: REPO, issue: 410 }, other.cursor)).events, []);
});

test("issue.commented gives the comment, its body cut to 4000 characters", async () => {
  const first = await poll("issue.commented", { repo: REPO, label: "bug" }, null);
  edit((d) => {
    issueAt(d, 410).comments.push({ id: 7100, author: "someone", url: `https://github.com/${REPO}/issues/410#issuecomment-7100`,
      body: "x".repeat(5000), createdAt: now(5) });
    issueAt(d, 411).comments.push({ id: 7101, author: "someone", url: "u", body: "not a bug", createdAt: now(5) });
  });
  const raised = await poll("issue.commented", { repo: REPO, label: "bug" }, first.cursor);
  assert.deepEqual(raised.events.map((e: any) => e.eventId), [`issue.commented:${REPO}:7100`]);
  const { comment, issue } = raised.events[0].data;
  assert.equal(issue.number, 410);
  assert.equal(comment.author, "someone");
  assert.equal(comment.body.length, 4001);
  assert.ok(comment.body.endsWith("…"));
});

test("ties at one updated_at aren't lost", async () => {
  const args = { repo: REPO, branch: "agents/ties" };
  const first = await poll("checks.failed", args, null);
  const at = now(5);
  edit((d) => repoData(d).runs.push(failedRun(9301, "agents/ties", at), failedRun(9302, "agents/ties", at),
    failedRun(9303, "agents/ties", at)));
  const one = await poll("checks.failed", args, first.cursor, 1);
  assert.equal(one.events.length, 1);
  assert.equal(one.hasMore, true);
  const two = await poll("checks.failed", args, one.cursor, 1);
  assert.equal(two.events.length, 1);
  const rest = await poll("checks.failed", args, two.cursor, 5);
  assert.equal(rest.events.length, 1);
  assert.equal(rest.hasMore, false);
  const ids = [one, two, rest].map((r) => r.events[0].eventId).sort();
  assert.deepEqual(ids, [9301, 9302, 9303].map((id) => `checks.failed:${REPO}:${id}:1`));
  const quiet = await poll("checks.failed", args, rest.cursor);
  assert.deepEqual(quiet.events, []);
});

test("a cursor older than 90 days is truncated", async () => {
  const old = cursorAt(new Date(Date.now() - 91 * 86400_000).toISOString());
  const result = await poll("pr.merged", { repo: REPO }, old);
  assert.equal(result.truncated, true);
});

test("bad arguments are -32602, an unknown event -32011", async () => {
  const extra = await rpc("events/poll", { name: "pr.merged", arguments: { repo: REPO, sha: "x" }, cursor: null });
  assert.equal(extra.error.code, -32602);
  for (const name of ["checks.failed", "pr.merged"]) {
    for (const pr of ["551", 0, -1, 1.5]) {
      const wrong = await rpc("events/poll", { name, arguments: { repo: REPO, pr }, cursor: null });
      assert.equal(wrong.error.code, -32602);
      assert.equal(wrong.error.message, "pr must be a positive integer");
    }
  }
  const shape = await rpc("events/poll", { name: "checks.failed", arguments: { repo: "not a repo" }, cursor: null });
  assert.equal(shape.error.code, -32602);
  const cursor = await rpc("events/poll", { name: "checks.failed", arguments: { repo: REPO }, cursor: "%%%" });
  assert.equal(cursor.error.code, -32602);
  const unknown = await rpc("events/poll", { name: "checks.passed", arguments: { repo: REPO }, cursor: null });
  assert.equal(unknown.error.code, -32011);
  const method = await rpc("events/nope");
  assert.equal(method.error.code, -32601);
});

test("tools/list annotations and visibility", async () => {
  const { tools } = await ok("tools/list");
  const byName = Object.fromEntries(tools.map((t: any) => [t.name, t]));
  assert.deepEqual(Object.keys(byName).sort(), ["comment_on_pr", "failed_log", "list_issues", "list_prs", "rerun_failed"]);
  assert.equal(byName.list_issues.annotations.readOnlyHint, true);
  assert.deepEqual(byName.list_issues._meta.ui.visibility, ["model", "app"]);
  assert.equal(byName.list_prs.annotations.readOnlyHint, true);
  assert.deepEqual(byName.list_prs._meta.ui.visibility, ["model", "app"]);
  assert.equal(byName.failed_log.annotations.readOnlyHint, true);
  assert.deepEqual(byName.failed_log._meta.ui.visibility, ["model"]);
  assert.equal(byName.rerun_failed.annotations?.readOnlyHint, undefined);
  assert.deepEqual(byName.rerun_failed._meta.ui.visibility, ["model", "app"]);
  assert.equal(byName.comment_on_pr.annotations?.readOnlyHint, undefined);
  assert.deepEqual(byName.comment_on_pr._meta.ui.visibility, ["model"]);
  for (const t of tools) {
    assert.equal(t.inputSchema.type, "object");
    assert.ok(!t.inputSchema.required.includes("repo"));
    assert.equal(t.inputSchema.properties.repo.type, "string");
  }
});

test("list_prs marks a PR that conflicts with its base", async () => {
  edit((d) => repoData(d).prs.push(openPR(712, "agents/stale", { checks: "none", conflicts: true })));
  const prs = (await ok("tools/call", { name: "list_prs", arguments: { repo: REPO } })).structuredContent.prs;
  assert.equal(prs.find((p: any) => p.number === 712).conflicts, true);
  assert.ok(!("conflicts" in prs.find((p: any) => p.number === 402)), "one that merges cleanly says nothing");
  edit((d) => { repoData(d).prs = repoData(d).prs.filter((p: any) => p.number !== 712); });
});

test("each tool's result shape", async () => {
  const list = await ok("tools/call", { name: "list_prs", arguments: { repo: REPO } });
  assert.notEqual(list.isError, true);
  const prs = list.structuredContent.prs;
  assert.deepEqual(prs.find((p: any) => p.number === 402), {
    number: 402, title: "Queue helpers past the limit", branch: "agents/queue-helpers",
    url: `https://github.com/${REPO}/pull/402`, checks: "failing", failedRunId: 9001,
  });
  for (const p of prs) assert.ok(["passing", "failing", "running", "none"].includes(p.checks));
  assert.ok(!prs.some((p: any) => p.number === 400), "a merged PR is not open");
  assert.deepEqual(JSON.parse(list.content[0].text), list.structuredContent);

  const log = await ok("tools/call", { name: "failed_log", arguments: { repo: REPO, runId: 9001 } });
  const text = log.content[0].text;
  assert.match(text, /HelperLimitTests/);
  assert.match(text, /cannot be built/);
  assert.doesNotMatch(text, /All checks passed/);
  const one = await ok("tools/call", { name: "failed_log", arguments: { repo: REPO, runId: 9001, job: "packages" } });
  assert.doesNotMatch(one.content[0].text, /HelperLimitTests/);

  const rerun = await ok("tools/call", { name: "rerun_failed", arguments: { repo: REPO, runId: 9001 } });
  assert.deepEqual(rerun.structuredContent, { rerun: true, url: `https://github.com/${REPO}/actions/runs/9001` });
  assert.equal(read().reruns.at(-1).runId, 9001);
  const after = await ok("tools/call", { name: "list_prs", arguments: { repo: REPO } });
  assert.equal(after.structuredContent.prs.find((p: any) => p.number === 402).checks, "running");

  const comment = await ok("tools/call", { name: "comment_on_pr", arguments: { repo: REPO, number: 402, body: "Fixed the test." } });
  assert.match(comment.structuredContent.url, /pull\/402#issuecomment-/);
  assert.equal(read().comments.at(-1).body, "Fixed the test.");

  const issues = await ok("tools/call", { name: "list_issues", arguments: { repo: REPO } });
  assert.notEqual(issues.isError, true);
  const open = issues.structuredContent.issues;
  assert.ok(!open.some((i: any) => i.number === 409), "a closed issue is not open");
  assert.deepEqual(open.find((i: any) => i.number === 410), {
    number: 410, title: "The sidebar flickers on wake", author: "alexec", labels: ["bug"],
    url: `https://github.com/${REPO}/issues/410`, comments: open.find((i: any) => i.number === 410).comments,
    updatedAt: "2026-10-01T11:00:00Z",
  });
  assert.ok(open.find((i: any) => i.number === 410).comments >= 1);
  const bugs = await ok("tools/call", { name: "list_issues", arguments: { repo: REPO, label: "bug" } });
  assert.ok(bugs.structuredContent.issues.every((i: any) => i.labels.includes("bug")));

  const bad = await ok("tools/call", { name: "failed_log", arguments: { repo: REPO } });
  assert.equal(bad.isError, true);
  const unknown = await rpc("tools/call", { name: "nope", arguments: {} });
  assert.equal(unknown.error.code, -32602);
});

test("gh not signed in, and a rate limit", async () => {
  edit((d) => { d.gh = "notSignedIn"; });
  try {
    const poll = await rpc("events/poll", { name: "checks.failed", arguments: { repo: REPO }, cursor: cursorAt(now()) });
    assert.equal(poll.error.code, -32012);
    assert.equal(poll.error.data.reason, "gh not signed in");
    const tool = await ok("tools/call", { name: "list_prs", arguments: { repo: REPO } });
    assert.equal(tool.isError, true);
    assert.match(tool.content[0].text, /gh not signed in/);

    edit((d) => { d.gh = { rateLimitedForMs: 60000 }; });
    const limited = await rpc("events/poll", { name: "pr.merged", arguments: { repo: REPO }, cursor: cursorAt(now()) });
    assert.equal(limited.error.code, -32013);
    assert.ok(limited.error.data.retryAfterMs > 50000 && limited.error.data.retryAfterMs <= 60000);
  } finally {
    edit((d) => { delete d.gh; });
  }
});

for (const [tool, uri, file, words] of [
  ["list_prs", "ui://ci/board", "board.html", ["rerun_failed", "list_prs"]],
  ["list_issues", "ui://ci/issues", "issues.html", ["list_issues"]],
] as const) {
  test(`${tool} feeds ${uri}, which resources/read serves`, async () => {
    const { tools } = await ok("tools/list");
    const fed = tools.find((t: any) => t.name === tool);
    assert.equal(fed._meta.ui.resourceUri, uri);
    assert.equal(fed._meta["ui/resourceUri"], uri);
    for (const t of tools.filter((t: any) => !["list_prs", "list_issues"].includes(t.name))) assert.equal(t._meta.ui.resourceUri, undefined);

    const { resources } = await ok("resources/list");
    assert.deepEqual(resources.map((r: any) => r.uri), ["ui://ci/board", "ui://ci/issues"]);
    const listed = resources.find((r: any) => r.uri === uri);
    assert.equal(listed.mimeType, "text/html;profile=mcp-app");
    assert.equal(listed.file, undefined);

    const { contents } = await ok("resources/read", { uri });
    assert.equal(contents.length, 1);
    const [page] = contents;
    assert.equal(page.uri, uri);
    assert.equal(page.mimeType, "text/html;profile=mcp-app");
    assert.deepEqual(page._meta.ui.csp, {});
    assert.equal(page.text, readFileSync(join(here, file), "utf8"));
    for (const word of ["ui/initialize", "ui/notifications/initialized", "ui/notifications/tool-result", "ui/open-link", ...words]) {
      assert.ok(page.text.includes(word), word);
    }
    assert.doesNotMatch(page.text, /fetch\(|XMLHttpRequest|WebSocket|<script src|<link /, "the view has no network");

    const missing = await rpc("resources/read", { uri: "ui://ci/nope" });
    assert.equal(missing.error.code, -32002);
  });
}

test("a line that is not JSON is a parse error, and the server goes on", async () => {
  const answered = new Promise<any>((resolve) => waiting.set(null as any, resolve));
  server!.stdin!.write("not json\n");
  assert.equal((await answered).error.code, -32700);
  assert.deepEqual(await ok("ping"), {});
});
