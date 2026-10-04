// The browser's one socket to the control plane (071 contracts/browser-auth.md, research R4/R5).
// One per tab: it proves the key, then carries 058's client lines, {"h", "m"} both ways, with
// the page's own request ids. It reconnects by itself with backoff, and notices a hung socket
// with a `control/status` every few seconds.
import { log } from "../log";
import type { Method, Params, Result } from "../protocol/methods";
import { targetOf } from "../protocol/methods";
import { type Admitted, connect, type LineSocket, Refused, WrongControlPlane } from "./auth";
import { type KeyRecord, type KeyStore, UnsupportedBrowser } from "./keys";

export type LinkState =
  | { kind: "connecting" }
  | { kind: "open"; name: string }
  | { kind: "down"; since: number }
  | { kind: "unpaired" }
  | { kind: "forgotten" }
  | { kind: "wrongControlPlane" }
  | { kind: "unsupported" };

/** A JSON-RPC error from a host or the control plane. */
export class CallFailed extends Error {
  constructor(readonly code: number, message: string) {
    super(message);
  }
}

/** The socket dropped before the answer came. */
export class LinkDown extends Error {
  constructor() {
    super("can't reach the control plane");
  }
}

/** No answer within the call's time (#170): one hung host must not hold up everything waiting on it. */
export class CallTimedOut extends LinkDown {}

/** What a browser WebSocket gives; a fake one in the tests. */
export interface SocketLike {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onclose: ((event: { code: number; reason: string }) => void) | null;
  onerror: ((event: unknown) => void) | null;
}

export interface LinkOptions {
  /** The page's own WebSocket: ws, the page's host, /v1/connect. */
  url: string;
  /** The page's own origin (location.origin): what every proof is bound to. */
  origin: string;
  keys: KeyStore;
  open?: (url: string) => SocketLike;
  /** Seconds before each retry; the last repeats. Each is taken between half and all of
   * it at random, as every other client does (#172). */
  backoff?: number[];
  /** How long, in ms, a connection must last before the next loss starts from the first step. */
  healthyAfter?: number;
  /** How often to check the socket, and how long to wait for the answer. */
  heartbeat?: { every: number; within: number };
  random?: () => number;
  /** How long a call waits for its answer before it is given up (#170). */
  callTimeout?: number;
  /** How long the link has to stay up before a drop starts the backoff from the first step again. */
  stableAfter?: number;
  /** Whether the tab is out of sight: no retries and no heartbeat then; retryNow on its return (#170). */
  hidden?: () => boolean;
  /** How long `unknown` has to keep coming back, with no connection between, before the
   * key is let go: the Swift clients' RefusalPatience (#81, #171). Milliseconds. */
  patience?: number;
  now?: () => number;
  /** The exchange; the real one unless a test stands in for it. */
  authenticate?: (socket: LineSocket, record: KeyRecord, origin: string) => Promise<Admitted>;
}

/**
 * Milliseconds before retry number `attempt` (from 0): the step, doubling to the last, taken
 * between half and all of it by `random` (0 to 1), as the apps' `ReconnectSchedule` does, so
 * that pages that lost the control plane together don't come back in step (#172).
 */
export function retryDelay(steps: number[], attempt: number, random: number): number {
  const step = steps[Math.min(attempt, steps.length - 1)]!;
  return step * 1000 * (0.5 + 0.5 * Math.min(Math.max(random, 0), 1));
}

/** Close code the control plane sends a forgotten client (contracts/browser-auth.md). */
export const forgottenCode = 4403;

/** A call waiting for its reply, and the route it went on: a host, or null for the control plane. */
type Pending = { resolve: (value: unknown) => void; reject: (error: Error) => void; route: string | null };

/** Lines from a socket, as the exchange reads them. */
export class Lines implements LineSocket {
  private queue: string[] = [];
  private waiting: { resolve: (line: string) => void; reject: (error: Error) => void } | null = null;
  private closed: Error | null = null;

  constructor(private socket: SocketLike) {}

  push(line: string): void {
    if (this.waiting) {
      const waiting = this.waiting;
      this.waiting = null;
      waiting.resolve(line);
    } else {
      this.queue.push(line);
    }
  }

  end(error: Error): void {
    this.closed = error;
    this.waiting?.reject(error);
    this.waiting = null;
  }

  send(line: string): void {
    this.socket.send(line);
  }

  next(timeoutMs = 15_000): Promise<string> {
    const queued = this.queue.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    if (this.closed) return Promise.reject(this.closed);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiting = null;
        reject(new LinkDown());
      }, timeoutMs);
      this.waiting = {
        resolve: (line) => { clearTimeout(timer); resolve(line); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      };
    });
  }

  close(code?: number, reason?: string): void {
    this.socket.close(code, reason);
  }
}

export class Link {
  private options: Required<Omit<LinkOptions, "open">> & { open: (url: string) => SocketLike };
  private socket: SocketLike | null = null;
  private stopped = true;
  private attempt = 0;
  /** When `unknown` was first heard since the last connection, or null. */
  private firstUnknown: number | null = null;
  private openedAt: number | null = null;
  private retry: ReturnType<typeof setTimeout> | null = null;
  private beat: ReturnType<typeof setInterval> | null = null;
  private stable: ReturnType<typeof setTimeout> | null = null;
  private nextID = 1;
  private pending = new Map<number, Pending>();
  private stateListeners = new Set<(state: LinkState) => void>();
  private noticeListeners = new Set<(method: string, params: unknown, host: string | null) => void>();
  state: LinkState = { kind: "connecting" };

  constructor(options: LinkOptions) {
    this.options = {
      backoff: [1, 2, 4, 8, 16, 30],
      healthyAfter: 10_000,
      heartbeat: { every: 5_000, within: 3_000 },
      random: Math.random,
      callTimeout: 30_000,
      stableAfter: 30_000,
      hidden: () => globalThis.document?.visibilityState === "hidden",
      patience: 120_000,
      now: Date.now,
      authenticate: connect,
      open: (url) => new WebSocket(url) as unknown as SocketLike,
      ...options,
    };
  }

  onState(listener: (state: LinkState) => void): () => void {
    this.stateListeners.add(listener);
    return () => this.stateListeners.delete(listener);
  }

  /** Every notification, with the host it came from (null for the control plane's own). */
  onNotification(listener: (method: string, params: unknown, host: string | null) => void): () => void {
    this.noticeListeners.add(listener);
    return () => this.noticeListeners.delete(listener);
  }

  private set(state: LinkState): void {
    this.state = state;
    for (const listener of this.stateListeners) listener(state);
  }

  start(): void {
    this.stopped = false;
    void this.dial();
  }

  stop(): void {
    this.stopped = true;
    this.clearTimers();
    this.socket?.close(1000, "");
    this.socket = null;
  }

  /**
   * Try again now: the tab came back into view, or the person asked. A link that stayed up
   * while the tab was hidden is checked at once, its heartbeat having rested meanwhile.
   */
  retryNow(): void {
    if (!this.stopped && this.state.kind === "open") return this.check();
    if (this.stopped || this.state.kind !== "down") return;
    if (this.retry) clearTimeout(this.retry);
    this.retry = null;
    void this.dial();
  }

  /** Sends `method` to `host`, or to the control plane for its own methods. */
  call<M extends Method>(method: M, params: Params<M>, host?: string): Promise<Result<M>> {
    if (this.state.kind !== "open" || !this.socket) return Promise.reject(new LinkDown());
    const id = this.nextID++;
    const message = { jsonrpc: "2.0", id, method, params };
    const route = targetOf(method) === "host" ? host ?? "mac" : null;
    const line = route !== null ? JSON.stringify({ h: route, m: message }) : JSON.stringify({ m: message });
    return new Promise<Result<M>>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        log("call.timedOut");
        reject(new CallTimedOut());
      }, this.options.callTimeout);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value as Result<M>); },
        reject: (error) => { clearTimeout(timer); reject(error); },
        route,
      });
      this.socket?.send(line);
    });
  }

  private clearTimers(): void {
    if (this.retry) clearTimeout(this.retry);
    if (this.beat) clearInterval(this.beat);
    if (this.stable) clearTimeout(this.stable);
    this.retry = null;
    this.beat = null;
    this.stable = null;
  }

  private async dial(): Promise<void> {
    this.clearTimers();
    let record;
    try {
      record = await this.options.keys.load();
    } catch (error) {
      if (error instanceof UnsupportedBrowser) {
        log("link.unsupported");
        return this.set({ kind: "unsupported" });
      }
      throw error;
    }
    if (!record) return this.set({ kind: "unpaired" });
    if (this.state.kind !== "down") this.set({ kind: "connecting" });
    log("link.connecting");

    const socket = this.options.open(this.options.url);
    this.socket = socket;
    const lines = new Lines(socket);
    let authed = false;
    socket.onmessage = (event) => {
      const line = String(event.data);
      if (authed) this.heard(line);
      else lines.push(line);
    };
    socket.onerror = () => {};
    socket.onclose = (event) => {
      lines.end(new LinkDown());
      if (this.socket !== socket) return;
      this.socket = null;
      this.failPending();
      if (event.code === forgottenCode) return void this.forgotten();
      if (authed || this.state.kind === "connecting" || this.state.kind === "down") this.down();
    };
    socket.onopen = async () => {
      try {
        const admitted = await this.options.authenticate(lines, record, this.options.origin);
        authed = true;
        // Back to the first step only once it has stayed up: a link that drops straight after
        // each sign-in would otherwise redial, and reload everything, every second (#170).
        this.stable = setTimeout(() => (this.attempt = 0), this.options.stableAfter);
        this.firstUnknown = null;
        this.openedAt = Date.now();
        log("link.open");
        this.set({ kind: "open", name: admitted.name });
        this.startHeartbeat();
      } catch (error) {
        if (error instanceof Refused && (error.reason === "forgotten" || this.unknownLasted(error.reason))) {
          log("link.refused", error.reason);
          this.socket = null;
          socket.close(1000, "");
          return void this.forgotten();
        }
        if (error instanceof WrongControlPlane) {
          log("link.wrongControlPlane");
          this.socket = null;
          socket.close(1000, "");
          return this.set({ kind: "wrongControlPlane" });
        }
        if (error instanceof Refused) log("link.refused", error.reason);
        socket.close(1000, "");
      }
    };
  }

  private heard(line: string): void {
    let frame: { h?: string; m?: { id?: number | null; result?: unknown; error?: { code: number; message: string }; method?: string; params?: unknown } };
    try {
      frame = JSON.parse(line);
    } catch {
      return;
    }
    const message = frame.m;
    if (!message) return;
    if (message.id === null && message.error) {
      // A failure tied to no request: one of ours the far end couldn't read. Which one can't be
      // known, so every call waiting on that route is told, rather than left waiting for good
      // (#93, as JSONRPCConnection does).
      log("call.failed", message.error.code);
      const route = frame.h ?? null;
      for (const [id, pending] of this.pending) {
        if (pending.route !== route) continue;
        this.pending.delete(id);
        pending.reject(new CallFailed(message.error.code, message.error.message));
      }
      return;
    }
    if (typeof message.id === "number" && (message.result !== undefined || message.error)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        log("call.failed", message.error.code);
        pending.reject(new CallFailed(message.error.code, message.error.message));
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (typeof message.method === "string") {
      for (const listener of this.noticeListeners) listener(message.method, message.params, frame.h ?? null);
    }
  }

  private startHeartbeat(): void {
    this.beat = setInterval(() => {
      if (!this.options.hidden()) this.check();
    }, this.options.heartbeat.every);
  }

  /** One heartbeat: the control plane answers within its time, or the link is counted down. */
  private check(): void {
    const socket = this.socket;
    if (!socket) return;
    // A hung control plane never answers the close handshake either, so the page counts
    // the link down at once rather than waiting for the browser's own timeout.
    const timer = setTimeout(() => {
      if (this.socket !== socket) return;
      this.socket = null;
      socket.close(4000, "no answer");
      this.failPending();
      this.down();
    }, this.options.heartbeat.within);
    this.call("control/status", {} as Params<"control/status">).then(() => clearTimeout(timer), () => {});
  }

  private failPending(): void {
    for (const pending of this.pending.values()) pending.reject(new LinkDown());
    this.pending.clear();
  }

  private down(): void {
    this.clearTimers();
    if (this.state.kind !== "down") {
      log("link.down");
      this.set({ kind: "down", since: Date.now() });
    }
    // Out of sight it waits: the tab's return calls retryNow (#170).
    if (this.stopped || this.options.hidden()) return;
    // Back to the first step only after a connection that lasted: one the control plane
    // takes and drops at once does not make the page dial every second (#172).
    if (this.openedAt !== null && Date.now() - this.openedAt >= this.options.healthyAfter) this.attempt = 0;
    this.openedAt = null;
    const delay = retryDelay(this.options.backoff, this.attempt, this.options.random());
    this.attempt++;
    this.retry = setTimeout(() => void this.dial(), delay);
  }

  /** `forgotten` is a person's decision and final; `unknown` is final only once it has
   * lasted (#171): a control plane starting, or a record it could not read for a moment,
   * says it too, and a page that let its key go then had to be paired again. */
  private unknownLasted(reason: string): boolean {
    if (reason !== "unknown") return false;
    const now = this.options.now();
    if (this.firstUnknown === null) {
      this.firstUnknown = now;
      return false;
    }
    return now - this.firstUnknown >= this.options.patience;
  }

  private async forgotten(): Promise<void> {
    this.clearTimers();
    this.stopped = true;
    log("link.forgotten");
    await this.options.keys.forget();
    this.set({ kind: "forgotten" });
  }
}
