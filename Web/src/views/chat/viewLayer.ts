// The views drawn in one chat on the web page (#187, MCP Apps). Each is the spec's sandbox proxy:
// an iframe of /sandbox.html at the loopback address, 127.0.0.1, another origin than the page's
// own at localhost on the same port, which holds the view in a sandboxed frame of its own. The
// page talks to the proxy; the proxy to the view.
//
// The frames live in a layer of their own inside the transcript's scroll area, positioned over a
// slot in their row, rather than in the row: a frame taken out of the page is gone at once, so a
// row that unmounted could never wait for the view to answer ui/resource-teardown, and moving a
// frame reloads it, so full screen would start the view again. Here the row only holds the
// place; the layer keeps the frame, moves it, and takes it down when the view has answered.
import { signal } from "@preact/signals";
import type { AppViewCall, AppViewPolicy, JSONValue, ViewResource } from "../../protocol/generated";
import { encodeDomains } from "../../sandbox/policy";
import {
  type Context, contextChanges, error as rpcError, Feed, initializeResult, notification, policyWire, read, request,
  result, viewTitle,
} from "./appViewBridge";

export interface ViewActions {
  agentID: string;
  project?: string;
  openDashboardTarget?(kind: string, id: string): void;
  call(method: "views/read" | "views/call" | "views/log" | "views/context", params: Record<string, unknown>): Promise<unknown>;
  /** A ui/message the person said yes to, sent as their prompt. */
  send(text: string): Promise<boolean>;
}

export const maxInlineHeight = 640;
const teardownWait = 2000;

const describe = (e: unknown) => (e instanceof Error ? e.message : String(e));
const dark = () => typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: dark)").matches;

/** One view: its frame, its conversation, and what the row draws around it. */
export class HostedView {
  readonly height = signal(96);
  readonly phase = signal<"loading" | "ready" | "failed" | "gone">("loading");
  readonly failure = signal("");
  readonly askedMessage = signal<string | null>(null);
  readonly contextLine = signal<string | null>(null);
  readonly title: string;
  /** The project's Dashboard fills the page: no "Back to the chat" bar (#188). */
  readonly fillsPage: boolean;
  readonly box: HTMLDivElement;
  private frame: HTMLIFrameElement | null = null;
  private feed = new Feed();
  private policy: AppViewPolicy = { connectDomains: [], resourceDomains: [], frameDomains: [], baseUriDomains: [], refused: [] };
  private resource: ViewResource | null = null;
  private context: Context;
  private messageID: string | number | null = null;
  private teardown: { id: string; done: () => void } | null = null;
  private next = 1;
  slot: HTMLElement | null = null;

  constructor(public call: AppViewCall, public actions: ViewActions, private layer: ViewLayer) {
    this.title = viewTitle(call.tool);
    this.fillsPage = call.resourceUri === "ui://agents/dashboard";
    this.box = document.createElement("div");
    this.box.className = "view-box";
    this.box.hidden = true;
    if (!this.fillsPage) {
      const bar = document.createElement("div");
      bar.className = "view-bar";
      const name = document.createElement("strong");
      name.textContent = this.title;
      const back = document.createElement("button");
      back.textContent = "Back to the chat";
      back.onclick = () => this.layer.setFullscreen(null);
      bar.append(name, back);
      this.box.append(bar);
    }
    this.context = {
      theme: dark() ? "dark" : "light", displayMode: "inline", width: 600, maxHeight: maxInlineHeight,
      locale: navigator.language || "en", timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
      touch: typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches,
      hover: typeof matchMedia === "function" && matchMedia("(hover: hover)").matches,
      variables: {}, tool: call.tool,
    };
    void this.load();
  }

  get proxyOrigin(): string { return `http://127.0.0.1:${location.port}`; }
  owns(source: MessageEventSource | null): boolean { return !!this.frame && source === this.frame.contentWindow; }

  private async load(): Promise<void> {
    try {
      this.resource = await this.actions.call("views/read", { agentID: this.actions.agentID, uri: this.call.resourceUri }) as ViewResource;
    } catch (e) {
      this.failure.value = `This view could not be read from the server: ${describe(e)}`;
      this.phase.value = "failed";
      return;
    }
    if (this.phase.value === "gone") return;
    this.policy = this.resource.policy;
    this.context = { ...this.context, variables: this.resource.variables };
    const frame = document.createElement("iframe");
    // The spec's two, and nothing else: the proxy is another origin, so allow-same-origin gives
    // it its own, never the page's.
    frame.setAttribute("sandbox", "allow-scripts allow-same-origin");
    frame.setAttribute("referrerpolicy", "no-referrer");
    frame.setAttribute("allow", "");
    frame.title = this.title;
    frame.src = `${this.proxyOrigin}/sandbox.html?csp=${encodeDomains(this.policy)}`;
    this.frame = frame;
    this.box.append(frame);
    this.phase.value = "ready";
  }

  private post(message: unknown): void {
    if (this.phase.value === "gone") return;
    this.frame?.contentWindow?.postMessage(message, this.proxyOrigin);
  }

  /** The call as it now stands: its result or its cancellation goes to the view. */
  update(call: AppViewCall): void {
    if (JSON.stringify(call) === JSON.stringify(this.call)) return;
    this.call = call;
    for (const message of this.feed.due(call)) this.post(message);
  }

  /** The space it has and the look: told to the view when either changes. */
  place(width: number, height: number | undefined): void {
    const next: Context = {
      ...this.context, width, theme: dark() ? "dark" : "light",
      displayMode: height === undefined ? "inline" : "fullscreen",
      height, maxHeight: height === undefined ? maxInlineHeight : undefined,
    };
    const changes = contextChanges(next, this.context);
    this.context = next;
    if (changes && this.feed.initialized) this.post(notification("ui/notifications/host-context-changed", changes));
  }

  answerMessage(send: boolean): void {
    const text = this.askedMessage.value, id = this.messageID;
    if (text === null || id === null) return;
    this.askedMessage.value = null;
    this.messageID = null;
    if (!send) { this.post(rpcError(id, -32000, "The person did not send it.")); return; }
    void this.actions.send(text).then((sent) => this.post(sent ? result(id) : rpcError(id, -32000, "It could not be sent.")));
  }

  dropContext(): void {
    this.contextLine.value = null;
    void this.actions.call("views/context", { agentID: this.actions.agentID, viewID: this.call.id, uri: this.call.resourceUri })
      .catch(() => {});
  }

  /** Tell the view it is going, wait a moment for its answer, and take it down. */
  async tearDown(reason: string): Promise<void> {
    if (this.phase.value === "gone") return;
    if (this.feed.initialized) {
      const id = `teardown-${this.next++}`;
      await new Promise<void>((done) => {
        this.teardown = { id, done };
        this.post(request(id, "ui/resource-teardown", { reason }));
        setTimeout(() => this.finishTeardown(), teardownWait);
      });
    }
    this.phase.value = "gone";
    this.box.remove();
  }

  private finishTeardown(): void {
    const pending = this.teardown;
    this.teardown = null;
    pending?.done();
  }

  /** One message from the proxy. */
  received(data: unknown): void {
    if ((data as { method?: unknown })?.method === "ui/notifications/sandbox-proxy-ready") {
      if (this.resource) {
        this.post(notification("ui/notifications/sandbox-resource-ready",
          { html: this.resource.html, csp: policyWire(this.policy), permissions: {} }));
      }
      return;
    }
    const ask = read(data);
    switch (ask.kind) {
      case "initialize":
        this.post(result(ask.id, initializeResult(this.context, this.policy)));
        break;
      case "initialized":
        for (const message of this.feed.viewInitialized(this.call)) this.post(message);
        break;
      case "ping":
        this.post(result(ask.id));
        break;
      case "callTool":
        this.relay(ask.id, "views/call", { agentID: this.actions.agentID, viewID: this.call.id, name: ask.name,
          ...(this.actions.project ? { project: this.actions.project } : {}),
          ...(ask.arguments === undefined ? {} : { arguments: ask.arguments }) }, (value) => {
          const open = (value as { structuredContent?: { open?: { kind?: string; id?: string } } })?.structuredContent?.open;
          if (open?.kind && open.id) this.actions.openDashboardTarget?.(open.kind, open.id);
          return value;
        });
        break;
      case "readResource":
        void this.actions.call("views/read", { agentID: this.actions.agentID, uri: ask.uri })
          .then((r) => {
            const resource = r as ViewResource;
            this.post(result(ask.id, { contents: [{ uri: resource.uri, mimeType: resource.mimeType, text: resource.html }] }));
          })
          .catch((e) => this.post(rpcError(ask.id, -32000, describe(e))));
        break;
      case "openLink":
        window.open(ask.url, "_blank", "noopener,noreferrer");
        this.post(result(ask.id));
        break;
      case "message":
        // Never sent on the view's say-so: the person is asked, under the view.
        if (this.messageID !== null) this.post(rpcError(this.messageID, -32000, "Another message replaced it."));
        this.messageID = ask.id;
        this.askedMessage.value = ask.text;
        break;
      case "updateContext": {
        const words = Array.isArray(ask.content)
          ? (ask.content as { text?: unknown }[]).flatMap((b) => (typeof b?.text === "string" ? [b.text] : [])).join(" ")
          : "";
        this.contextLine.value = words || (ask.structuredContent !== undefined ? "what the view last showed" : null);
        this.relay(ask.id, "views/context", { agentID: this.actions.agentID, viewID: this.call.id, uri: this.call.resourceUri,
          ...(ask.content === undefined ? {} : { content: ask.content }),
          ...(ask.structuredContent === undefined ? {} : { structuredContent: ask.structuredContent }) }, () => ({}));
        break;
      }
      case "displayMode":
        if (ask.mode === "inline" || ask.mode === "fullscreen") this.layer.setFullscreen(ask.mode === "fullscreen" ? this.call.id : null);
        this.post(result(ask.id, { mode: this.layer.fullscreen.value === this.call.id ? "fullscreen" : "inline" }));
        break;
      case "sizeChanged":
        if (ask.height && ask.height > 0) {
          this.height.value = Math.min(maxInlineHeight, Math.max(32, Math.ceil(ask.height)));
          queueMicrotask(() => this.layer.sync());
        }
        break;
      case "log":
        void this.actions.call("views/log", { agentID: this.actions.agentID, viewID: this.call.id,
          ...(ask.level ? { level: ask.level } : {}), ...(ask.data === undefined ? {} : { data: ask.data as JSONValue }) })
          .catch(() => {});
        break;
      case "answered":
        if (this.teardown?.id === ask.id) this.finishTeardown();
        break;
      case "unknown":
        this.post(rpcError(ask.id, -32601, `${ask.method} is not something this host does.`));
        break;
      case "malformed":
        this.post(rpcError(ask.id, -32602, ask.reason));
        break;
      case "ignored":
        break;
    }
  }

  private relay(id: string | number, method: "views/call" | "views/context", params: Record<string, unknown>,
    answer: (value: unknown) => unknown = (v) => v): void {
    this.actions.call(method, params)
      .then((value) => this.post(result(id, answer(value))))
      .catch((e) => this.post(rpcError(id, -32000, describe(e))));
  }
}

/** Every view open in one chat. */
export class ViewLayer {
  readonly fullscreen = signal<string | null>(null);
  private views = new Map<string, HostedView>();
  /** Views being taken down, still heard until they have answered. */
  private closing = new Set<HostedView>();
  /** The layer's own element, inside the scroll area, and the chat it covers when full screen. */
  element: HTMLElement | null = null;
  chat: HTMLElement | null = null;
  scroller: HTMLElement | null = null;
  private listening = false;

  private onMessage = (event: MessageEvent) => {
    for (const view of [...this.views.values(), ...this.closing]) {
      if (view.owns(event.source) && event.origin === view.proxyOrigin) { view.received(event.data); return; }
    }
  };
  private onScheme = () => this.sync();

  view(call: AppViewCall, actions: ViewActions): HostedView {
    if (!this.listening && typeof window !== "undefined") {
      window.addEventListener("message", this.onMessage);
      window.addEventListener("resize", this.onScheme);
      matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", this.onScheme);
      this.listening = true;
    }
    let view = this.views.get(call.id);
    if (!view) {
      view = new HostedView(call, actions, this);
      this.views.set(call.id, view);
      this.element?.append(view.box);
    } else {
      // Never another chat's: a row still drawn for a moment after the chat changed must not
      // hand a closing view the next chat's calls.
      if (actions.agentID === view.actions.agentID) view.actions = actions;
      view.update(call);
    }
    return view;
  }

  attach(id: string, slot: HTMLElement): void {
    const view = this.views.get(id);
    if (!view) return;
    view.slot = slot;
    if (this.element && view.box.parentElement !== this.element) this.element.append(view.box);
    this.sync();
  }

  detach(id: string, slot: HTMLElement): void {
    const view = this.views.get(id);
    if (view?.slot === slot) { view.slot = null; this.sync(); }
  }

  setFullscreen(id: string | null): void {
    this.fullscreen.value = id;
    this.sync();
  }

  /** Every frame over its slot, or over the chat when full screen. */
  sync(): void {
    const scroller = this.scroller;
    if (!scroller) return;
    const base = scroller.getBoundingClientRect();
    for (const [id, view] of this.views) {
      const box = view.box;
      if (this.fullscreen.value === id && this.chat) {
        const rect = this.chat.getBoundingClientRect();
        box.hidden = false;
        box.classList.add("full");
        Object.assign(box.style, { position: "fixed", top: `${rect.top}px`, left: `${rect.left}px`,
          width: `${rect.width}px`, height: `${rect.height}px` });
        view.place(rect.width, rect.height - (view.fillsPage ? 0 : 41));
        continue;
      }
      box.classList.remove("full");
      const slot = view.slot;
      if (!slot || !slot.isConnected || view.phase.value !== "ready") { box.hidden = true; continue; }
      const rect = slot.getBoundingClientRect();
      box.hidden = false;
      Object.assign(box.style, { position: "absolute", top: `${rect.top - base.top + scroller.scrollTop}px`,
        left: `${rect.left - base.left + scroller.scrollLeft}px`, width: `${rect.width}px`, height: `${rect.height}px` });
      view.place(rect.width, undefined);
    }
  }

  /** Every view, told and then taken down: the chat is closing or changing. */
  async tearDownAll(reason: string): Promise<void> {
    const all = [...this.views.values()];
    this.views.clear();
    for (const view of all) { view.box.hidden = true; this.closing.add(view); }
    this.fullscreen.value = null;
    await Promise.all(all.map(async (view) => { await view.tearDown(reason); this.closing.delete(view); }));
  }

  stop(): void {
    if (!this.listening) return;
    window.removeEventListener("message", this.onMessage);
    window.removeEventListener("resize", this.onScheme);
    matchMedia?.("(prefers-color-scheme: dark)").removeEventListener?.("change", this.onScheme);
    this.listening = false;
  }
}
