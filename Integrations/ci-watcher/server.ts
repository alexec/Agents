// The CI watcher MCP server (#383): this repo's pull requests' CI as events, tools and a
// view, over plain JSON-RPC on http at 127.0.0.1. The contract is
// specs/383-mcp-integrations/contracts/ci-watcher-server.md.
//
//   node server.ts [--port 8795]          gh as the signed-in person
//   CI_WATCHER_FAKE=<file> node server.ts reads and writes <file> instead
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { GhError, fakeGitHub, realGitHub, type GitHub, type RunRef } from "./github.ts";

const here = dirname(fileURLToPath(import.meta.url));
const VERSION = "0.1.0";
const PROTOCOL_VERSIONS = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"];
const NEXT_POLL_MS = 30_000;
const MAX_EVENTS = 100;
/** GitHub lists Actions runs this far back; a cursor older than that may have missed some. */
const HISTORY_MS = 90 * 86400_000;
const MAX_BODY = 1024 * 1024;
const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

// MARK: JSON-RPC errors

class RpcError extends Error {
  code: number;
  data?: unknown;
  constructor(code: number, message: string, data?: unknown) {
    super(message);
    this.code = code;
    this.data = data;
  }
}
const invalidParams = (message: string) => new RpcError(-32602, message);

/** A gh failure as the events draft's error codes. */
function eventsError(error: unknown): RpcError {
  if (error instanceof GhError) {
    switch (error.kind) {
      case "notSignedIn": return new RpcError(-32012, error.message, { reason: "gh not signed in" });
      case "rateLimited": return new RpcError(-32013, error.message, { retryAfterMs: error.retryAfterMs });
      case "notFound": return invalidParams(`${error.message}: check repo`);
      default: return new RpcError(-32603, error.message);
    }
  }
  return new RpcError(-32603, error instanceof Error ? error.message : String(error));
}

// MARK: Arguments

type Schema = { type: "object"; properties: Record<string, any>; required: string[]; additionalProperties: false };

const repoProperty = { type: "string", pattern: REPO.source, description: "The GitHub repo, owner/name." };

/** Checks `args` against the small schemas below: required keys, no others, types and the repo's shape. */
function check(schema: Schema, args: unknown): Record<string, any> {
  if (args === undefined || args === null) args = {};
  if (typeof args !== "object" || Array.isArray(args)) throw invalidParams("arguments must be an object");
  const given = args as Record<string, any>;
  for (const key of schema.required) if (given[key] === undefined) throw invalidParams(`missing ${key}`);
  for (const [key, value] of Object.entries(given)) {
    const property = schema.properties[key];
    if (!property) throw invalidParams(`unknown argument ${key}; takes ${Object.keys(schema.properties).join(", ")}`);
    const ok = property.type === "integer" ? Number.isInteger(value) && value > 0 : typeof value === property.type;
    if (!ok) throw invalidParams(`${key} must be ${property.type === "integer" ? "a positive integer" : `a ${property.type}`}`);
    if (property.pattern && !new RegExp(property.pattern).test(value)) throw invalidParams(`${key} must look like owner/name`);
    if (property.maxLength && value.length > property.maxLength) throw invalidParams(`${key} is over ${property.maxLength} characters`);
  }
  return given;
}

const schema = (properties: Record<string, any>, required: string[]): Schema =>
  ({ type: "object", properties, required, additionalProperties: false });

// MARK: Events

const prSchema = {
  type: "object",
  properties: { number: { type: "integer" }, title: { type: "string" }, branch: { type: "string" }, url: { type: "string" } },
};

const EVENTS = [
  {
    name: "checks.failed",
    title: "Checks failed",
    description: "A pull request's checks finished with a failure: one event per run and attempt, so a rerun that fails again is a new one.",
    delivery: ["poll"],
    inputSchema: schema({ repo: repoProperty, branch: { type: "string", description: "Only this PR branch." } }, ["repo"]),
    payloadSchema: {
      type: "object",
      properties: {
        pr: prSchema, headSha: { type: "string" },
        run: { type: "object", properties: { id: { type: "integer" }, attempt: { type: "integer" }, name: { type: "string" }, url: { type: "string" } } },
        failedJobs: { type: "array", items: { type: "object", properties: { name: { type: "string" }, url: { type: "string" } } } },
      },
    },
  },
  {
    name: "pr.merged",
    title: "Pull request merged",
    description: "A pull request was merged.",
    delivery: ["poll"],
    inputSchema: schema({ repo: repoProperty }, ["repo"]),
    payloadSchema: {
      type: "object",
      properties: { pr: prSchema, mergedAt: { type: "string" }, mergeSha: { type: "string" } },
    },
  },
];

interface Cursor { since: string; ids: string[] }
const encodeCursor = (c: Cursor) => Buffer.from(JSON.stringify(c)).toString("base64url");
function decodeCursor(text: unknown): Cursor {
  try {
    const c = JSON.parse(Buffer.from(String(text), "base64url").toString("utf8"));
    if (typeof c.since === "string" && !Number.isNaN(Date.parse(c.since)) && Array.isArray(c.ids)) {
      return { since: new Date(c.since).toISOString(), ids: c.ids.map(String) };
    }
  } catch {}
  throw invalidParams("cursor is not one this server gave");
}

interface Candidate { eventId: string; time: string; data: () => Promise<unknown | null> }

async function candidates(gh: GitHub, name: string, args: Record<string, any>, since: string) {
  const repo: string = args.repo;
  if (name === "checks.failed") {
    const { runs, truncated } = await gh.failedRuns(repo, args.branch, since);
    const list = runs.map((ref: RunRef): Candidate => ({
      eventId: `checks.failed:${repo}:${ref.id}:${ref.attempt}`,
      time: new Date(ref.updatedAt).toISOString(),
      data: () => gh.runDetails(repo, ref),
    }));
    return { list, truncated };
  }
  const { prs, truncated } = await gh.mergedPRs(repo, since);
  const list = prs.map((m): Candidate => ({
    eventId: `pr.merged:${repo}:${m.pr.number}`,
    time: new Date(m.mergedAt).toISOString(),
    data: async () => m,
  }));
  return { list, truncated };
}

/**
 * The cursor is `{since, ids}`: a high-water time, and the ids already raised at exactly
 * that time, so events that share one `updated_at` are neither lost nor raised twice (R10).
 */
async function poll(gh: GitHub, params: any) {
  const event = EVENTS.find((e) => e.name === params?.name);
  if (!event) throw new RpcError(-32011, `no event ${params?.name}; this server offers ${EVENTS.map((e) => e.name).join(", ")}`);
  const args = check(event.inputSchema, params.arguments);
  const maxEvents = Math.min(MAX_EVENTS, Math.max(1, Number.isInteger(params.maxEvents) ? params.maxEvents : 50));
  if (params.cursor === null || params.cursor === undefined) {
    return { events: [], cursor: encodeCursor({ since: new Date().toISOString(), ids: [] }),
      truncated: false, hasMore: false, nextPollMs: NEXT_POLL_MS };
  }
  const cursor = decodeCursor(params.cursor);
  const seen = new Set(cursor.ids);
  let found;
  try {
    found = await candidates(gh, event.name, args, cursor.since);
  } catch (error) {
    throw eventsError(error);
  }
  const fresh = found.list
    .filter((c) => c.time >= cursor.since && !(c.time === cursor.since && seen.has(c.eventId)))
    .sort((a, b) => (a.time === b.time ? (a.eventId < b.eventId ? -1 : 1) : a.time < b.time ? -1 : 1));
  const taken = fresh.slice(0, maxEvents);
  const since = taken.length ? taken[taken.length - 1].time : cursor.since;
  const ids = new Set(since === cursor.since ? cursor.ids : []);
  for (const c of taken) if (c.time === since) ids.add(c.eventId);

  const events = [];
  for (const c of taken) {
    let data;
    try {
      data = await c.data();
    } catch (error) {
      throw eventsError(error);
    }
    // A run that belongs to no pull request isn't a PR's checks; the cursor still moves past it.
    if (data !== null) events.push({ eventId: c.eventId, name: event.name, timestamp: c.time, data });
  }
  return {
    events,
    cursor: encodeCursor({ since, ids: [...ids] }),
    truncated: found.truncated || Date.parse(cursor.since) < Date.now() - HISTORY_MS,
    hasMore: fresh.length > taken.length,
    nextPollMs: NEXT_POLL_MS,
  };
}

// MARK: Tools

const TOOLS = [
  {
    name: "list_prs",
    title: "List pull requests",
    description: "The repo's open pull requests, each with its checks: passing, failing, running or none. A failing one has the failed run's id for failed_log and rerun_failed.",
    inputSchema: schema({ repo: repoProperty }, ["repo"]),
    annotations: { readOnlyHint: true },
    _meta: { ui: { resourceUri: "ui://ci/board", visibility: ["model", "app"] }, "ui/resourceUri": "ui://ci/board" },
  },
  {
    name: "failed_log",
    title: "Read a failed run's log",
    description: "The last 300 lines of each failed job's log in an Actions run, or of one job by name.",
    inputSchema: schema({
      repo: repoProperty, runId: { type: "integer", description: "The Actions run's id." },
      job: { type: "string", description: "Only the job with this name." },
    }, ["repo", "runId"]),
    annotations: { readOnlyHint: true },
    _meta: { ui: { visibility: ["model"] } },
  },
  {
    name: "rerun_failed",
    title: "Rerun failed jobs",
    description: "Reruns an Actions run's failed jobs. Use it for a failure that is known to be flaky, not to hide a real one.",
    inputSchema: schema({ repo: repoProperty, runId: { type: "integer", description: "The Actions run's id." } }, ["repo", "runId"]),
    _meta: { ui: { visibility: ["model", "app"] } },
  },
  {
    name: "comment_on_pr",
    title: "Comment on a pull request",
    description: "Adds a comment to a pull request, as the signed-in person. Say what you changed or why it needs a person.",
    inputSchema: schema({
      repo: repoProperty, number: { type: "integer", description: "The pull request's number." },
      body: { type: "string", maxLength: 65536, description: "The comment, in Markdown." },
    }, ["repo", "number", "body"]),
    _meta: { ui: { visibility: ["model"] } },
  },
];

async function callTool(gh: GitHub, params: any) {
  const tool = TOOLS.find((t) => t.name === params?.name);
  if (!tool) throw invalidParams(`no tool ${params?.name}`);
  try {
    const a = check(tool.inputSchema, params.arguments);
    if (tool.name === "failed_log") {
      return { content: [{ type: "text", text: await gh.failedLog(a.repo, a.runId, a.job) }] };
    }
    const result = tool.name === "list_prs" ? { prs: await gh.listPRs(a.repo) }
      : tool.name === "rerun_failed" ? await gh.rerunFailed(a.repo, a.runId)
      : await gh.commentOnPR(a.repo, a.number, a.body);
    return { content: [{ type: "text", text: JSON.stringify(result) }], structuredContent: result };
  } catch (error) {
    const message = error instanceof GhError && error.kind === "rateLimited"
      ? `${error.message}; try again in ${Math.ceil((error.retryAfterMs ?? 60_000) / 1000)}s`
      : error instanceof Error ? error.message : String(error);
    return { content: [{ type: "text", text: message }], isError: true };
  }
}

// MARK: Resources

const BOARD_URI = "ui://ci/board";
const BOARD_MIME = "text/html;profile=mcp-app";
// No network at all: an empty csp, so the host draws it under its strictest policy.
const BOARD_META = { ui: { csp: {}, prefersBorder: true } };
const board = {
  uri: BOARD_URI, name: "board", title: "Pull requests",
  description: "The repo's open pull requests and their checks, with Rerun on a failing one. Fed by list_prs.",
  mimeType: BOARD_MIME, _meta: BOARD_META,
};

async function readResource(params: any) {
  if (params?.uri !== BOARD_URI) throw new RpcError(-32002, `no resource ${params?.uri}`);
  const text = await readFile(join(here, "board.html"), "utf8");
  return { contents: [{ uri: BOARD_URI, mimeType: BOARD_MIME, text, _meta: BOARD_META }] };
}

// MARK: Dispatch

async function handle(gh: GitHub, method: string, params: any): Promise<unknown> {
  switch (method) {
    case "initialize": {
      const asked = params?.protocolVersion;
      return {
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: {}, resources: {}, events: { listChanged: false },
          extensions: { "io.modelcontextprotocol/ui": {} } },
        serverInfo: { name: "ci-watcher", title: "CI watcher", version: VERSION },
        instructions: "This repo's pull requests and their CI. Events: checks.failed, pr.merged. Tools read logs, rerun failed jobs and comment, as the signed-in gh user.",
      };
    }
    case "ping": return {};
    case "tools/list": return { tools: TOOLS };
    case "tools/call": return callTool(gh, params);
    case "resources/list": return { resources: [board] };
    case "resources/templates/list": return { resourceTemplates: [] };
    case "resources/read": return readResource(params);
    case "events/list": return { events: EVENTS };
    case "events/poll": return poll(gh, params);
    default: throw new RpcError(-32601, `no method ${method}`);
  }
}

async function answer(gh: GitHub, message: any) {
  if (!message || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    // A response from the client, or something that isn't a request: nothing to answer.
    return message?.id !== undefined && message?.method === undefined && (message.result !== undefined || message.error !== undefined)
      ? undefined
      : { jsonrpc: "2.0", id: message?.id ?? null, error: { code: -32600, message: "not a JSON-RPC 2.0 request" } };
  }
  const isNotification = message.id === undefined;
  try {
    const result = await handle(gh, message.method, message.params);
    return isNotification ? undefined : { jsonrpc: "2.0", id: message.id, result };
  } catch (error) {
    if (isNotification) return undefined;
    const e = error instanceof RpcError ? error : new RpcError(-32603, error instanceof Error ? error.message : String(error));
    if (!(error instanceof RpcError)) console.error(`ci-watcher: ${message.method} failed: ${e.message}`);
    return { jsonrpc: "2.0", id: message.id, error: { code: e.code, message: e.message, ...(e.data === undefined ? {} : { data: e.data }) } };
  }
}

// MARK: http

/** No Origin (not a browser), or a page on 127.0.0.1 itself. */
function originAllowed(origin: string | undefined) {
  return origin === undefined || /^http:\/\/127\.0\.0\.1(:\d+)?$/.test(origin);
}

function send(res: ServerResponse, status: number, body?: unknown, headers: Record<string, string> = {}) {
  const text = body === undefined ? "" : JSON.stringify(body);
  res.writeHead(status, { ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers });
  res.end(text);
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY) { reject(new Error("too large")); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

export function start(gh: GitHub, port: number, fake: string | undefined) {
  const server = createServer(async (req, res) => {
    if (!originAllowed(req.headers.origin)) return send(res, 403, { error: "Origin not allowed" });
    const path = (req.url ?? "/").split("?")[0];
    if (path === "/health" && req.method === "GET") {
      return send(res, 200, { ok: true, name: "ci-watcher", version: VERSION, fake: fake !== undefined });
    }
    if (path !== "/mcp") return send(res, 404, { error: "not found" });
    // The server keeps no session state, so any session id is good, and ending one is a no-op.
    if (req.method === "DELETE") return send(res, 204);
    if (req.method !== "POST") return send(res, 405, { error: "POST JSON-RPC to /mcp" }, { allow: "POST, DELETE" });

    let parsed: any;
    try {
      parsed = JSON.parse(await readBody(req));
    } catch {
      return send(res, 400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
    }
    const batch = Array.isArray(parsed);
    const answers = (await Promise.all((batch ? parsed : [parsed]).map((m: any) => answer(gh, m)))).filter((a) => a !== undefined);
    const initializing = (batch ? parsed : [parsed]).some((m: any) => m?.method === "initialize");
    const headers: Record<string, string> = initializing
      ? { "mcp-session-id": randomUUID() }
      : typeof req.headers["mcp-session-id"] === "string" ? { "mcp-session-id": req.headers["mcp-session-id"] } : {};
    if (answers.length === 0) return send(res, 202, undefined, headers);
    send(res, 200, batch ? answers : answers[0], headers);
  });
  server.listen(port, "127.0.0.1", () => {
    const address = server.address();
    const actual = typeof address === "object" && address ? address.port : port;
    console.log(`ci-watcher listening on http://127.0.0.1:${actual}/mcp${fake ? ` (fake: ${fake})` : ""}`);
  });
  return server;
}

function fakePath(): string | undefined {
  const given = process.env.CI_WATCHER_FAKE;
  if (!given) return undefined;
  const fromCwd = resolve(given);
  return existsSync(fromCwd) ? fromCwd : resolve(here, given);
}

if (import.meta.main) {
  const i = process.argv.indexOf("--port");
  const port = i > 0 ? Number(process.argv[i + 1]) : 8795;
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    console.error("usage: node server.ts [--port 8795]");
    process.exit(2);
  }
  const fake = fakePath();
  if (fake && !existsSync(fake)) {
    console.error(`ci-watcher: no such file ${fake}`);
    process.exit(2);
  }
  start(fake ? fakeGitHub(fake) : realGitHub(), port, fake);
}
