// The views drawn in one chat on the web page (#187, MCP Apps). Each is the spec's sandbox proxy:
// an iframe of /sandbox.html at another origin than the page's (viewsOrigin: the loopback address,
// 127.0.0.1, on this Mac; the views' second name on the control plane's domain, #1484), which
// holds the view in a sandboxed frame of its own. The page talks to the proxy; the proxy to the
// view.
//
// The frames live in a layer of their own inside the transcript's scroll area, positioned over a
// slot in their row, rather than in the row: a frame taken out of the page is gone at once, so a
// row that unmounted could never wait for the view to answer ui/resource-teardown, and moving a
// frame reloads it, so full screen would start the view again. Here the row only holds the
// place; the layer keeps the frame, moves it, and takes it down when the view has answered.
import { signal } from "@preact/signals";
import type { AppViewCall, AppViewPolicy, JSONValue, ViewResource } from "../../protocol/generated";
import { encodeDomains } from "../../sandbox/policy";
import { CallFailed } from "../../wire/link";
import { onThisMac, viewsOrigin } from "../../place";
import {
  canPin, type Context, needsShow, serverParam, type ViewAsk, contextChanges, error as rpcError, Feed, initializeResult, noAgentWords, notification, policyWire,
  type AgentMessage, type Diff, noAgentCode, openDiffMethod, read, request, result, type Start, startAgentMethod, viewTitle,
} from "./appViewBridge";

export interface ViewActions {
  agentID: string;
  /** Set for a view in a folder's place (a pin): there is no agent to reach. */
  folder?: string;
  call(method: "views/read" | "views/call" | "views/log" | "views/context" | "views/show", params: Record<string, unknown>): Promise<unknown>;
  /** A ui/message the person said yes to, sent as their prompt. */
  send(text: string): Promise<boolean>;
  /** Pins the call's view to the chat's folder (#189); answers whether it was pinned. */
  pin?(call: AppViewCall): Promise<boolean>;
  /** Opens the new-agent form in the view's folder, filled in (#834). Why it was not, or null.
   *  The person starts the agent; a view never does. */
  startAgent?(start: Start): string | null;
  /** The session a view's agents/message-agent goes to (#837): on the branch, in the view's
   *  folder, or null when there is none. */
  recipient?(message: AgentMessage): { id: string; name: string } | null;
  /** An agents/message-agent the person said yes to, sent to that session as their prompt. */
  sendTo?(id: string, text: string): Promise<boolean>;
}

export const maxInlineHeight = 640;
const teardownWait = 2000;

const describe = (e: unknown) => (e instanceof Error ? e.message : String(e));
const dark = () => typeof matchMedia === "function" && matchMedia("(prefers-color-scheme: dark)").matches;

/** One view: its frame, its conversation, and what the row draws around it. */
export class HostedView {
  readonly height = signal(96);
  readonly phase = signal<"loading" | "asking" | "ready" | "failed" | "gone">("loading");
  /** A person's own server's view, waiting on Show or Don't Show (#191). */
  readonly ask = signal<ViewAsk | null>(null);
  readonly failure = signal("");
  /** A failure that reading again could help: drawn with Try Again (#978). */
  readonly canRetry = signal(false);
  readonly askedMessage = signal<string | null>(null);
  /** For an agents/message-agent (#837): the session it goes to, not this chat's. */
  readonly askedRecipient = signal<{ id: string; name: string } | null>(null);
  readonly contextLine = signal<string | null>(null);
  /** Pinned from here (#189): the caption says so instead of offering Pin. */
  readonly pinned = signal(false);
  readonly title: string;
  /** A view in a folder's place (a pin) fills the page: no "Back to the chat" bar (#188). */
  readonly fillsPage: boolean;
  private pinButton: HTMLButtonElement | null = null;
  private pinnedLabel: HTMLSpanElement | null = null;
  readonly box: HTMLDivElement;
  private frame: HTMLIFrameElement | null = null;
  private feed = new Feed();
  private policy: AppViewPolicy = { connectDomains: [], resourceDomains: [], frameDomains: [], baseUriDomains: [], refused: [] };
  private resource: ViewResource | null = null;
  private context: Context;
  private messageID: string | number | null = null;
  private teardown: { id: string; done: () => void } | null = null;
  private next = 1;
  /** The read running now; an answer for an older one is dropped (#978). */
  private attempt = 0;
  slot: HTMLElement | null = null;

  constructor(public call: AppViewCall, public actions: ViewActions, private layer: ViewLayer) {
    this.title = viewTitle(call.tool, call.server);
    this.fillsPage = !!actions.folder;
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
      const pin = document.createElement("button");
      pin.textContent = "Pin";
      pin.title = "Pin this view under the folder";
      pin.onclick = () => void this.pin();
      const pinned = document.createElement("span");
      pinned.textContent = "Pinned";
      this.pinButton = pin;
      this.pinnedLabel = pinned;
      bar.append(name, pin, pinned, back);
      this.box.append(bar);
      this.drawBar();
    }
    this.context = {
      theme: dark() ? "dark" : "light", displayMode: "inline", width: 600, maxHeight: maxInlineHeight,
      locale: navigator.language || "en", timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
      touch: typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches,
      hover: typeof matchMedia === "function" && matchMedia("(hover: hover)").matches,
      variables: {}, tool: call.tool,
    };
    void this.load(++this.attempt);
  }

  /** The sandbox proxy's origin, once the view knows it: "" before. */
  proxyOrigin = "";
  private closed(): boolean { return this.phase.value === "gone"; }
  owns(source: MessageEventSource | null): boolean { return !!this.frame && source === this.frame.contentWindow; }

  /**
   * Try Again, or the link back: a view still loading, or whose read failed, is read afresh, as a
   * read in flight when the link dropped may never be answered (#978). A drawn view, one asking
   * Show, and a closed one are left.
   */
  retry(): void {
    if (this.phase.value !== "loading" && !(this.phase.value === "failed" && this.canRetry.value)) return;
    this.phase.value = "loading";
    this.canRetry.value = false;
    void this.load(++this.attempt);
  }

  private async load(mine: number): Promise<void> {
    // A control plane on its own domain with no second name for the proxy (#1484): nothing
    // of a view is read or drawn there.
    const proxy = await viewsOrigin();
    if (mine !== this.attempt || this.closed()) return;
    if (!proxy) {
      this.failure.value = "Views are not drawn on this page: its control plane has no views name. The Agents apps draw them.";
      this.phase.value = "failed";
      return;
    }
    this.proxyOrigin = proxy;
    let resource: ViewResource;
    try {
      resource = await this.actions.call("views/read", { agentID: this.actions.agentID, uri: this.call.resourceUri,
        ...this.where() }) as ViewResource;
    } catch (e) {
      if (mine !== this.attempt || this.phase.value === "gone") return;
      // Nothing of it is drawn until the person says Show.
      const ask = e instanceof CallFailed ? needsShow(e.code, e.data) : null;
      if (ask) {
        this.ask.value = ask;
        this.phase.value = "asking";
        return;
      }
      this.failure.value = `This view could not be read from the server: ${describe(e)}`;
      this.canRetry.value = true;
      this.phase.value = "failed";
      return;
    }
    if (mine !== this.attempt || this.phase.value === "gone") return;
    this.resource = resource;
    this.policy = this.resource.policy;
    this.context = { ...this.context, variables: this.resource.variables };
    const frame = document.createElement("iframe");
    // The spec's two, and nothing else: the proxy is another origin, so allow-same-origin gives
    // it its own, never the page's.
    frame.setAttribute("sandbox", "allow-scripts allow-same-origin");
    frame.setAttribute("referrerpolicy", "no-referrer");
    frame.setAttribute("allow", "");
    frame.title = this.title;
    // On the domain, the proxy is told the page's origin, which the control plane frames it for.
    const host = onThisMac() ? "" : `&host=${encodeURIComponent(location.origin)}`;
    frame.src = `${this.proxyOrigin}/sandbox.html?csp=${encodeDomains(this.policy)}${host}`;
    this.frame = frame;
    this.box.append(frame);
    this.phase.value = "ready";
  }

  /** The server and folder to name in views/*: none for the app's own server in a chat. */
  private where(): Record<string, unknown> {
    return { ...serverParam(this.call.server), ...(this.actions.folder ? { folder: this.actions.folder } : {}) };
  }

  /** The person's Show or Don't Show for a person's own server's view (#191). */
  async answerShow(show: boolean): Promise<void> {
    const ask = this.ask.value;
    if (!ask) return;
    this.ask.value = null;
    this.phase.value = "loading";
    const mine = ++this.attempt;
    try {
      await this.actions.call("views/show", { agentID: this.actions.agentID, server: ask.server, uri: ask.uri, hash: ask.hash, show,
        ...(this.actions.folder ? { folder: this.actions.folder } : {}) });
    } catch (e) {
      this.failure.value = `That could not be kept: ${describe(e)}`;
      this.phase.value = "failed";
      return;
    }
    if (mine !== this.attempt || this.phase.peek() === "gone") return;
    if (show) {
      await this.load(mine);
    } else {
      this.failure.value = `Not shown. Ask Again is on ${ask.server}'s row in the folder's Connectors.`;
      this.phase.value = "failed";
    }
  }

  private post(message: unknown): void {
    if (this.phase.value === "gone") return;
    this.frame?.contentWindow?.postMessage(message, this.proxyOrigin);
  }

  /** The call as it now stands: its result or its cancellation goes to the view. */
  update(call: AppViewCall): void {
    if (JSON.stringify(call) === JSON.stringify(this.call)) return;
    this.call = call;
    this.drawBar();
    for (const message of this.feed.due(call)) this.post(message);
  }

  /** Pin, in the caption's menu, inline or full screen (#189). */
  async pin(): Promise<void> {
    if (!this.actions.pin || !canPin(this.call) || this.pinned.value) return;
    if (await this.actions.pin(this.call)) this.pinned.value = true;
    this.drawBar();
  }

  /** The full screen bar's Pin, offered as the inline caption offers it. */
  private drawBar(): void {
    if (this.pinButton) this.pinButton.hidden = !this.actions.pin || !canPin(this.call) || this.pinned.value;
    if (this.pinnedLabel) this.pinnedLabel.hidden = !this.pinned.value;
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
    const to = this.askedRecipient.value;
    this.askedMessage.value = null;
    this.askedRecipient.value = null;
    this.messageID = null;
    if (!send) { this.post(rpcError(id, -32000, "The person did not send it.")); return; }
    const sending = to && this.actions.sendTo ? this.actions.sendTo(to.id, text) : this.actions.send(text);
    void sending.then((sent) => this.post(sent ? result(id) : rpcError(id, -32000, "It could not be sent.")));
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
          ...this.where(),
          ...(ask.arguments === undefined ? {} : { arguments: ask.arguments }) });
        break;
      case "readResource":
        // The same server's only: the one whose view it is.
        void this.actions.call("views/read", { agentID: this.actions.agentID, uri: ask.uri, ...this.where() })
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
        if (this.actions.folder) { this.refuse(ask.id, "ui/message"); break; }
        // Never sent on the view's say-so: the person is asked, under the view.
        if (this.messageID !== null) this.post(rpcError(this.messageID, -32000, "Another message replaced it."));
        this.messageID = ask.id;
        this.askedMessage.value = ask.text;
        this.askedRecipient.value = null;
        break;
      case "messageAgent": {
        // From a pin too: the session is named by its branch, not by where the view is.
        if (!this.actions.recipient || !this.actions.sendTo) {
          this.post(rpcError(ask.id, -32000, "This app can't send to another agent from here."));
          break;
        }
        const to = this.actions.recipient(ask.message);
        if (!to) { this.post(rpcError(ask.id, noAgentCode, `No agent here works on ${ask.message.branch}.`)); break; }
        if (this.messageID !== null) this.post(rpcError(this.messageID, -32000, "Another message replaced it."));
        this.messageID = ask.id;
        this.askedMessage.value = ask.message.text;
        this.askedRecipient.value = to;
        break;
      }
      case "startAgent": {
        const refused = this.actions.startAgent ? this.actions.startAgent(ask.start) : "This app can't open a new agent from here.";
        if (refused !== null) { this.post(rpcError(ask.id, -32000, refused)); break; }
        this.post(result(ask.id));
        void this.actions.call("views/log", { agentID: this.actions.agentID, viewID: this.call.id, level: "info",
          data: `${startAgentMethod}: the new-agent form opened, filled in` }).catch(() => {});
        break;
      }
      case "openDiff":
        // Drawn by the page, over the chat or the pin, with the Review page's diff (#1472).
        this.layer.diff.value = ask.diff;
        this.post(result(ask.id));
        void this.actions.call("views/log", { agentID: this.actions.agentID, viewID: this.call.id, level: "info",
          data: `${openDiffMethod}: ${ask.diff.files.length} file(s) drawn in the page's diff` }).catch(() => {});
        break;
      case "updateContext": {
        if (this.actions.folder) { this.refuse(ask.id, "ui/update-model-context"); break; }
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

  /** What only a chat's view may do, asked from a folder's place: refused, and logged (#189). */
  private refuse(id: string | number, method: string): void {
    this.post(rpcError(id, -32000, noAgentWords));
    void this.actions.call("views/log", { agentID: this.actions.agentID, viewID: this.call.id, level: "warning",
      data: `${method} refused: ${noAgentWords}` }).catch(() => {});
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
  /** A diff a view asked the page to draw (agents/open-diff, #1341): ViewDiff draws it. */
  readonly diff = signal<Diff | null>(null);
  /** Counts views made, so a page drawing one's state hears it arrive. */
  readonly made = signal(0);
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
      this.made.value += 1;
    } else {
      // Never another chat's: a row still drawn for a moment after the chat changed must not
      // hand a closing view the next chat's calls.
      if (actions.agentID === view.actions.agentID) view.actions = actions;
      view.update(call);
    }
    return view;
  }

  find(id: string): HostedView | undefined { return this.views.get(id); }

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

  /** The link came back: every view still loading, or whose read failed, is read again (#978). */
  reconnected(): void {
    for (const view of this.views.values()) view.retry();
  }

  stop(): void {
    if (!this.listening) return;
    window.removeEventListener("message", this.onMessage);
    window.removeEventListener("resize", this.onScheme);
    matchMedia?.("(prefers-color-scheme: dark)").removeEventListener?.("change", this.onScheme);
    this.listening = false;
  }
}
