// The host's half of a view's conversation (#187, MCP Apps SEP-1865): JSON-RPC 2.0 over
// postMessage. The web page's copy of AgentsKitCore/AppViews/AppViewBridge.swift, which the Mac
// and the phone use; docs/explanation/views.md says what each message does in Agents, and the
// two are kept to it. Pure, so test/appViews.test.mjs reads every row.
import type { Agent, AppViewCall, AppViewPolicy, JSONValue, UUID, ViewPin } from "../../protocol/generated";
import { folderKey, folderPath } from "../../model/groups";
import type { Hunk } from "../../model/fileDiff";

export const protocolVersion = "2026-01-26";
export const displayModes = ["inline", "fullscreen"] as const;
/** Our extension of MCP Apps (#834): a view asks for the new-agent form, filled in. */
export const startAgentMethod = "agents/start-agent";
/** Our extension of MCP Apps (#837): a view asks to send words to the session on a branch. */
export const messageAgentMethod = "agents/message-agent";
/** Our extension of MCP Apps (#1341): a view asks the page to draw a diff in its own diff (#1472). */
export const openDiffMethod = "agents/open-diff";
/** The error code of an agents/message-agent that no session in the view's folder works on. */
export const noAgentCode = -32001;

type Id = string | number;
type Message = { jsonrpc?: unknown; id?: unknown; method?: unknown; params?: unknown; result?: unknown; error?: unknown };

/** What a view asked for, read. */
export type Ask =
  | { kind: "initialize"; id: Id }
  | { kind: "initialized" }
  | { kind: "ping"; id: Id }
  | { kind: "callTool"; id: Id; name: string; arguments?: JSONValue | undefined }
  | { kind: "readResource"; id: Id; uri: string }
  | { kind: "openLink"; id: Id; url: string }
  | { kind: "message"; id: Id; text: string }
  /** Our extension (#834): open the new-agent form, filled in. Never a start. */
  | { kind: "startAgent"; id: Id; start: Start }
  /** Our extension (#837): send words to the session on a branch, once the person says Send. */
  | { kind: "messageAgent"; id: Id; message: AgentMessage }
  /** Our extension (#1341): draw these files' hunks in the page's own diff. */
  | { kind: "openDiff"; id: Id; diff: Diff }
  | { kind: "updateContext"; id: Id; content?: JSONValue | undefined; structuredContent?: JSONValue | undefined }
  | { kind: "displayMode"; id: Id; mode: string }
  | { kind: "sizeChanged"; width?: number | undefined; height?: number | undefined }
  | { kind: "log"; level?: string | undefined; data?: JSONValue | undefined }
  | { kind: "answered"; id: Id }
  | { kind: "unknown"; id: Id; method: string }
  | { kind: "malformed"; id: Id; reason: string }
  | { kind: "ignored" };

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isId = (v: unknown): v is Id => typeof v === "string" || typeof v === "number";
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : undefined);

export function read(raw: unknown): Ask {
  if (!isObject(raw)) return { kind: "ignored" };
  const message = raw as Message;
  if (message.jsonrpc !== "2.0") return { kind: "ignored" };
  const params = isObject(message.params) ? message.params : {};
  if (typeof message.method !== "string") {
    if (isId(message.id) && ("result" in message || "error" in message)) return { kind: "answered", id: message.id };
    return { kind: "ignored" };
  }
  const method = message.method;
  if (!isId(message.id)) {
    switch (method) {
      case "ui/notifications/initialized": return { kind: "initialized" };
      case "ui/notifications/size-changed": return { kind: "sizeChanged", width: num(params.width), height: num(params.height) };
      case "notifications/message":
        return { kind: "log", level: typeof params.level === "string" ? params.level : undefined, data: params.data as JSONValue };
      default: return { kind: "ignored" };
    }
  }
  const id = message.id;
  switch (method) {
    case "ui/initialize":
    case "initialize":
      return { kind: "initialize", id };
    case "ping":
      return { kind: "ping", id };
    case "tools/call":
      if (typeof params.name !== "string" || !params.name) return { kind: "malformed", id, reason: "tools/call needs a name." };
      return { kind: "callTool", id, name: params.name, arguments: params.arguments as JSONValue };
    case "resources/read":
      if (typeof params.uri !== "string" || !params.uri) return { kind: "malformed", id, reason: "resources/read needs a uri." };
      return { kind: "readResource", id, uri: params.uri };
    case "ui/open-link": {
      let scheme = "";
      try { scheme = new URL(String(params.url)).protocol; } catch { /* not a URL */ }
      if (!["http:", "https:", "mailto:"].includes(scheme)) {
        return { kind: "malformed", id, reason: "Only an http, https or mailto link can be opened." };
      }
      return { kind: "openLink", id, url: String(params.url) };
    }
    case "ui/message": {
      const blocks = Array.isArray(params.content) ? params.content : params.content === undefined ? [] : [params.content];
      const text = blocks.flatMap((b) => (isObject(b) && b.type === "text" && typeof b.text === "string" ? [b.text] : []))
        .join("\n").trim();
      if (!text) return { kind: "malformed", id, reason: "ui/message needs text content." };
      return { kind: "message", id, text };
    }
    case startAgentMethod: {
      const read = readStart(params);
      return "refused" in read ? { kind: "malformed", id, reason: read.refused } : { kind: "startAgent", id, start: read.start };
    }
    case messageAgentMethod: {
      const read = readAgentMessage(params);
      return "refused" in read ? { kind: "malformed", id, reason: read.refused } : { kind: "messageAgent", id, message: read.message };
    }
    case openDiffMethod: {
      const read = readDiff(params);
      return "refused" in read ? { kind: "malformed", id, reason: read.refused } : { kind: "openDiff", id, diff: read.diff };
    }
    case "ui/update-model-context":
      return { kind: "updateContext", id, content: params.content as JSONValue, structuredContent: params.structuredContent as JSONValue };
    case "ui/request-display-mode":
      return { kind: "displayMode", id, mode: typeof params.mode === "string" ? params.mode : "" };
    default:
      return { kind: "unknown", id, method };
  }
}

/** What a view asked the page to draw in its own diff (#1341, `agents/open-diff`): AppViewDiff.
 *  A pull request's files, each as its hunks, as GitHub gives them. */
export interface DiffFile {
  path: string;
  previousPath?: string | undefined;
  /** added, removed, modified, renamed …, as GitHub says. */
  change: string;
  additions: number;
  deletions: number;
  hunks: Hunk[];
  /** Why it has no hunks, when it has none. */
  note?: string | undefined;
}
export interface Diff {
  title: string;
  /** Where the same diff is on the web, such as the pull request's Files page. */
  url?: string | undefined;
  files: DiffFile[];
  /** Whether the view cut it: some files are listed with no hunks. */
  cut: boolean;
  /** The file to show first, when the view named one. */
  path?: string | undefined;
}
/** The most lines a diff may have, all files together, and the most files. */
export const diffLineLimit = 20000;
export const diffFileLimit = 3000;

const count = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? Math.max(0, Math.floor(v)) : 0);

/** Read from the message's parameters, or why not (AppViewDiff.read). */
export function readDiff(params: Record<string, unknown>): { diff: Diff } | { refused: string } {
  if (!Array.isArray(params.files)) return { refused: "agents/open-diff needs files." };
  if (params.files.length > diffFileLimit) return { refused: `A diff has at most ${diffFileLimit} files.` };
  let lines = 0;
  const files: DiffFile[] = [];
  for (const f of params.files) {
    if (!isObject(f) || typeof f.path !== "string" || !f.path) return { refused: "Each file of a diff needs a path." };
    const hunks: Hunk[] = [];
    for (const h of Array.isArray(f.hunks) ? f.hunks : []) {
      if (!isObject(h)) continue;
      const hunk: Hunk = { oldStart: Math.max(1, count(h.oldStart)), newStart: Math.max(1, count(h.newStart)), lines: [] };
      for (const l of Array.isArray(h.lines) ? h.lines : []) {
        if (!isObject(l) || !["context", "added", "removed"].includes(String(l.kind)) || typeof l.text !== "string") {
          return { refused: "Each line of a diff is context, added or removed, with its text." };
        }
        hunk.lines.push({ kind: l.kind as Hunk["lines"][number]["kind"], text: l.text });
      }
      lines += hunk.lines.length;
      hunks.push(hunk);
    }
    if (lines > diffLineLimit) return { refused: `A diff has at most ${diffLineLimit} lines.` };
    files.push({ path: f.path, previousPath: typeof f.previousPath === "string" ? f.previousPath : undefined,
      change: typeof f.change === "string" ? f.change : "modified", additions: count(f.additions), deletions: count(f.deletions),
      hunks, note: typeof f.note === "string" ? f.note : undefined });
  }
  const title = typeof params.title === "string" ? params.title.trim().slice(0, 200) : "";
  let url: string | undefined;
  try {
    const u = new URL(String(params.url));
    if (u.protocol === "https:" || u.protocol === "http:") url = u.href;
  } catch { /* not a URL */ }
  return { diff: { title: title || "Changes", url, files, cut: params.cut === true,
    path: typeof params.path === "string" ? params.path : undefined } };
}

/** What a view filled the new-agent form with (#834, `agents/start-agent`): AppViewStart. The
 *  form opens in the view's folder, and the person starts the agent, or doesn't. */
export interface Start {
  /** The prompt, as the person will see it in the field. */
  prompt: string;
  /** Labels set on the form, such as `#834`. */
  labels: string[];
  /** A new worktree's name, made with WorktreeChoice's named; unset leaves the form's place. */
  worktree?: string | undefined;
  /** A branch already there, for a new worktree on it (WorktreeChoice's branch, #837). It wins over `worktree`. */
  branch?: string | undefined;
}

/** The most a view may put in the field, in characters. */
export const startPromptLimit = 8000;
/** A session's own label rules (SessionLabelPolicy), so the form never holds a label its start would refuse. */
export const startLabelLimit = 5;
export const startLabelLength = 24;

/** Characters as Swift counts them. */
const characters = (text: string) => [...new Intl.Segmenter().segment(text)].map((s) => s.segment);

/** Read from the message's parameters, or why not (AppViewStart.read). */
export function readStart(params: Record<string, unknown>): { start: Start } | { refused: string } {
  const prompt = typeof params.prompt === "string" ? params.prompt.trim() : "";
  if (!prompt) return { refused: "agents/start-agent needs a prompt." };
  if (characters(prompt).length > startPromptLimit) return { refused: `The prompt is longer than ${startPromptLimit} characters.` };
  const labels: string[] = [];
  for (const value of Array.isArray(params.labels) ? params.labels : []) {
    const label = typeof value === "string" ? value.trim() : "";
    if (!label || characters(label).length > startLabelLength) {
      return { refused: `Each label is text of 1 to ${startLabelLength} characters.` };
    }
    if (!labels.some((l) => l.toLowerCase() === label.toLowerCase())) labels.push(label);
  }
  if (labels.length > startLabelLimit) return { refused: "A session can have at most five labels." };
  const worktree = typeof params.worktree === "string" ? characters(params.worktree.trim()).slice(0, 100).join("") : "";
  const branch = typeof params.branch === "string" ? params.branch.trim() : "";
  if (characters(branch).length > branchLimit) return { refused: `The branch is longer than ${branchLimit} characters.` };
  return { start: { prompt, labels, ...(worktree ? { worktree } : {}), ...(branch ? { branch } : {}) } };
}

/** What a view asked to send to the session on a branch (#837, `agents/message-agent`): AppViewAgentMessage. */
export interface AgentMessage {
  /** The branch the session's worktree is on, such as a pull request's. */
  branch: string;
  /** The words, as the person will see them before Send. */
  text: string;
}

export const branchLimit = 255;

/** Read from the message's parameters, or why not (AppViewAgentMessage.read). */
export function readAgentMessage(params: Record<string, unknown>): { message: AgentMessage } | { refused: string } {
  const branch = typeof params.branch === "string" ? params.branch.trim() : "";
  if (!branch) return { refused: "agents/message-agent needs a branch." };
  if (characters(branch).length > branchLimit) return { refused: `The branch is longer than ${branchLimit} characters.` };
  const text = typeof params.text === "string" ? params.text.trim() : "";
  if (!text) return { refused: "agents/message-agent needs text." };
  if (characters(text).length > startPromptLimit) return { refused: `The text is longer than ${startPromptLimit} characters.` };
  return { message: { branch, text } };
}

/** The session it goes to (AppViewAgentMessage.recipient): in `folder`, on the branch, not archived,
 *  the latest active first. Its id and what the person sees it called, or null. */
export function recipient(agents: Agent[], message: AgentMessage, folder: string): { id: string; name: string } | null {
  const found = agents
    .filter((a) => !a.archivedAt && a.worktree?.branch === message.branch && folderPath(a) === folderKey(folder))
    .sort((a, b) => b.lastActivityAt - a.lastActivityAt)[0];
  if (!found) return null;
  return { id: found.id, name: found.title?.trim() || found.worktree?.name || "the agent" };
}

export const result = (id: Id, value: unknown = {}) => ({ jsonrpc: "2.0", id, result: value });
export const error = (id: Id, code: number, message: string) => ({ jsonrpc: "2.0", id, error: { code, message } });
export const notification = (method: string, params: unknown = {}) => ({ jsonrpc: "2.0", method, params });
export const request = (id: Id, method: string, params: unknown = {}) => ({ jsonrpc: "2.0", id, method, params });

/** What the host tells a view about where it is drawn (hostContext). */
export interface Context {
  theme: "light" | "dark";
  displayMode: "inline" | "fullscreen";
  width: number;
  height?: number | undefined;
  maxHeight?: number | undefined;
  locale: string;
  timeZone: string;
  touch: boolean;
  hover: boolean;
  variables: Record<string, string>;
  tool: string;
}

export function contextWire(c: Context): Record<string, unknown> {
  const dimensions: Record<string, number> = { width: Math.round(c.width) };
  if (c.height !== undefined) dimensions.height = Math.round(c.height);
  else if (c.maxHeight !== undefined) dimensions.maxHeight = Math.round(c.maxHeight);
  return {
    theme: c.theme,
    platform: "web",
    displayMode: c.displayMode,
    availableDisplayModes: [...displayModes],
    containerDimensions: dimensions,
    locale: c.locale,
    timeZone: c.timeZone,
    userAgent: "agents",
    deviceCapabilities: { touch: c.touch, hover: c.hover },
    safeAreaInsets: { top: 0, right: 0, bottom: 0, left: 0 },
    styles: { variables: c.variables },
    // An MCP Tool needs an inputSchema: the ext-apps SDK refuses ui/initialize without one (#191).
    toolInfo: { tool: { name: c.tool, inputSchema: { type: "object" } } },
  };
}

/** The fields that differ, for ui/notifications/host-context-changed; null when none do. */
export function contextChanges(now: Context, before: Context): Record<string, unknown> | null {
  const a = contextWire(now), b = contextWire(before);
  const changed: Record<string, unknown> = {};
  for (const key of Object.keys(a)) if (JSON.stringify(a[key]) !== JSON.stringify(b[key])) changed[key] = a[key];
  return Object.keys(changed).length ? changed : null;
}

export function initializeResult(context: Context, policy: AppViewPolicy) {
  return {
    protocolVersion,
    hostInfo: { name: "agents", version: "1.0.0" },
    hostCapabilities: {
      openLinks: {}, serverTools: {}, serverResources: {}, logging: {},
      sandbox: { permissions: {}, csp: policyWire(policy) },
    },
    hostContext: contextWire(context),
  };
}

/** The csp the spec's messages carry: what is allowed. */
export function policyWire(policy: AppViewPolicy): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  if (policy.connectDomains.length) out.connectDomains = policy.connectDomains;
  if (policy.resourceDomains.length) out.resourceDomains = policy.resourceDomains;
  if (policy.frameDomains.length) out.frameDomains = policy.frameDomains;
  if (policy.baseUriDomains.length) out.baseUriDomains = policy.baseUriDomains;
  return out;
}

/** What the host owes a view about its call, in order (AppViewFeed). A later result is said
 *  again, so a view left open can change. A cancellation is not followed by a result. */
export class Feed {
  initialized = false;
  private sentInput = false;
  private sentEnd = false;
  /** The result last given to the view. Unset when a cancellation ended the call. */
  private sentResult: unknown = undefined;

  viewInitialized(call: AppViewCall): unknown[] {
    this.initialized = true;
    return this.due(call);
  }

  due(call: AppViewCall): unknown[] {
    if (!this.initialized) return [];
    const out: unknown[] = [];
    if (!this.sentInput) {
      this.sentInput = true;
      out.push(notification("ui/notifications/tool-input", { arguments: call.arguments ?? {} }));
    }
    if (call.state === "done") {
      const result = call.result ?? { content: [] };
      if (!this.sentEnd) {
        this.sentEnd = true;
        this.sentResult = result;
        out.push(notification("ui/notifications/tool-result", result));
      } else if (this.sentResult !== undefined && JSON.stringify(this.sentResult) !== JSON.stringify(result)) {
        this.sentResult = result;
        out.push(notification("ui/notifications/tool-result", result));
      }
    } else if (!this.sentEnd && call.state === "cancelled") {
      this.sentEnd = true;
      out.push(notification("ui/notifications/tool-cancelled", { reason: call.reason ?? "The turn was stopped." }));
    }
    return out;
  }
}

/** A view's name in the chat, from its tool, with whose it is for a person's own server (#191). */
export function viewTitle(tool: string, server?: string): string {
  if (tool === "show_test_view") return "Test view";
  const name = tool.replaceAll("_", " ");
  return server && server !== appServer ? `${name} · ${server}` : name;
}

// MARK: Third-party servers (#191)

/** The app's own server, which views/* names by leaving the server out. */
export const appServer = "agents";

/** What a person's own server's view waits on: their Show, for this version of it. */
export interface ViewAsk { server: string; uri: string; hash: string; isNew: boolean }

/** The daemon's "needs Show" (viewNeedsShow), read from a failed views/read. */
export function needsShow(code: number, data: unknown): ViewAsk | null {
  if (code !== -32063 || !data || typeof data !== "object") return null;
  const ask = data as Partial<ViewAsk>;
  return typeof ask.server === "string" && typeof ask.uri === "string" && typeof ask.hash === "string"
    ? { server: ask.server, uri: ask.uri, hash: ask.hash, isNew: ask.isNew !== false } : null;
}

/** The server field of a views/* request: none for the app's own. */
export function serverParam(server: string | undefined): { server?: string } {
  return server && server !== appServer ? { server } : {};
}

// MARK: Pins (#189)

/** Whether a view's caption offers Pin: the host said its call can feed a pin, and it has. */
export function canPin(call: AppViewCall): boolean {
  return call.pinnable === true && call.state === "done";
}

/** The pin a call would make: its view, and the call that feeds it. */
export function viewPin(call: AppViewCall): ViewPin {
  return { server: call.server, uri: call.resourceUri, tool: call.tool, ...(call.arguments === undefined ? {} : { arguments: call.arguments }) };
}

/** A pinned view's call, made by the host since no model made it: running until the feeding
 *  call answers, then done with its answer, so the view hears tool-input and then tool-result. */
export function pinnedViewCall(id: UUID, view: ViewPin, answer?: JSONValue): AppViewCall {
  return {
    id, server: view.server, tool: view.tool, resourceUri: view.uri,
    ...(view.arguments === undefined ? {} : { arguments: view.arguments }),
    state: answer === undefined ? "running" : "done",
    ...(answer === undefined ? {} : { result: answer }),
  };
}

/** The host's feeding call for a pinned view: views/call, marked as the host's own. */
export function feedParams(id: UUID, folder: string, view: ViewPin): Record<string, unknown> {
  return {
    agentID: id, viewID: id, name: view.tool, folder: folder, feed: true, ...serverParam(view.server),
    ...(view.arguments === undefined ? {} : { arguments: view.arguments }),
  };
}

/** What a view on a folder's page is told when it asks to reach an agent: there is none. */
export const noAgentWords = "A view on a folder's page has no agent to tell.";
