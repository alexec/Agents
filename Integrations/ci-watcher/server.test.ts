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

function failedRun(id: number, branch: string, updatedAt: string, attempt = 1) {
  return {
    id, attempt, name: "CI", url: `https://github.com/${REPO}/actions/runs/${id}`,
    event: "pull_request", status: "completed", conclusion: "failure",
    branch, headSha: `sha${id}`, pr: 402, updatedAt,
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

test("events/list gives both events, poll only, with their schemas", async () => {
  const { events } = await ok("events/list");
  assert.deepEqual(events.map((e: any) => e.name).sort(), ["checks.failed", "pr.merged"]);
  for (const e of events) {
    assert.deepEqual(e.delivery, ["poll"]);
    assert.ok(e.description);
    assert.equal(e.inputSchema.type, "object");
    assert.deepEqual(e.inputSchema.required, ["repo"]);
    assert.equal(e.inputSchema.properties.repo.type, "string");
    assert.equal(e.payloadSchema.type, "object");
  }
  const checks = events.find((e: any) => e.name === "checks.failed");
  assert.equal(checks.inputSchema.properties.branch.type, "string");
  const merged = events.find((e: any) => e.name === "pr.merged");
  assert.equal(merged.inputSchema.properties.branch, undefined);
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

test("branch narrows", async () => {
  const args = { repo: REPO, branch: "agents/narrow-me" };
  const first = await poll("checks.failed", args, null);
  edit((d) => repoData(d).runs.push(
    failedRun(9200, "agents/narrow-me", now(5)),
    failedRun(9201, "agents/someone-else", now(5))));
  const raised = await poll("checks.failed", args, first.cursor);
  assert.deepEqual(raised.events.map((e: any) => e.eventId), [`checks.failed:${REPO}:9200:1`]);
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
  const missing = await rpc("events/poll", { name: "checks.failed", arguments: {}, cursor: null });
  assert.equal(missing.error.code, -32602);
  assert.match(missing.error.message, /repo/);
  const extra = await rpc("events/poll", { name: "pr.merged", arguments: { repo: REPO, branch: "x" }, cursor: null });
  assert.equal(extra.error.code, -32602);
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
  assert.deepEqual(Object.keys(byName).sort(), ["comment_on_pr", "failed_log", "list_prs", "rerun_failed"]);
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
    assert.ok(t.inputSchema.required.includes("repo"));
  }
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

test("list_prs feeds the board, which resources/read serves", async () => {
  const { tools } = await ok("tools/list");
  const list = tools.find((t: any) => t.name === "list_prs");
  assert.equal(list._meta.ui.resourceUri, "ui://ci/board");
  assert.equal(list._meta["ui/resourceUri"], "ui://ci/board");
  for (const t of tools.filter((t: any) => t.name !== "list_prs")) assert.equal(t._meta.ui.resourceUri, undefined);

  const { resources } = await ok("resources/list");
  assert.equal(resources.length, 1);
  assert.equal(resources[0].uri, "ui://ci/board");
  assert.equal(resources[0].mimeType, "text/html;profile=mcp-app");

  const { contents } = await ok("resources/read", { uri: "ui://ci/board" });
  assert.equal(contents.length, 1);
  const [page] = contents;
  assert.equal(page.uri, "ui://ci/board");
  assert.equal(page.mimeType, "text/html;profile=mcp-app");
  assert.deepEqual(page._meta.ui.csp, {});
  assert.equal(page.text, readFileSync(join(here, "board.html"), "utf8"));
  for (const word of ["ui/initialize", "ui/notifications/initialized", "ui/notifications/tool-result",
    "rerun_failed", "list_prs", "ui/open-link"]) assert.ok(page.text.includes(word), word);
  assert.doesNotMatch(page.text, /fetch\(|XMLHttpRequest|WebSocket|<script src|<link /, "the board has no network");

  const missing = await rpc("resources/read", { uri: "ui://ci/nope" });
  assert.equal(missing.error.code, -32002);
});

test("a line that is not JSON is a parse error, and the server goes on", async () => {
  const answered = new Promise<any>((resolve) => waiting.set(null as any, resolve));
  server!.stdin!.write("not json\n");
  assert.equal((await answered).error.code, -32700);
  assert.deepEqual(await ok("ping"), {});
});
