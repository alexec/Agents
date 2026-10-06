// The host's half of a view's conversation (#187, MCP Apps SEP-1865): JSON-RPC 2.0 over
// postMessage. The web page's copy of AgentsKitCore/AppViews/AppViewBridge.swift, which the Mac
// and the phone use; docs/explanation/views.md says what each message does in Agents, and the
// two are kept to it. Pure, so test/appViews.test.mjs reads every row.
import type { AppViewCall, AppViewPolicy, JSONValue } from "../../protocol/generated";

export const protocolVersion = "2026-01-26";
export const displayModes = ["inline", "fullscreen"] as const;

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
    case "ui/update-model-context":
      return { kind: "updateContext", id, content: params.content as JSONValue, structuredContent: params.structuredContent as JSONValue };
    case "ui/request-display-mode":
      return { kind: "displayMode", id, mode: typeof params.mode === "string" ? params.mode : "" };
    default:
      return { kind: "unknown", id, method };
  }
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
    toolInfo: { tool: { name: c.tool } },
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
 *  again, so an open Dashboard can change. A cancellation is not followed by a result. */
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

/** A view's name in the chat, from its tool. */
export function viewTitle(tool: string): string {
  if (tool === "show_test_view") return "Test view";
  if (tool === "read_dashboard") return "Dashboard";
  return tool.replaceAll("_", " ");
}
