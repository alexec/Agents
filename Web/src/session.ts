// The page's one connection to the control plane, and what it says about itself (071 US1):
// unpaired, pairing, connecting, open, down, forgotten. Views read `session.state`.
import { signal } from "@preact/signals";
import { log } from "./log";
import { AnnounceRefused, BadServerProof, pair, Refused, type RefusalReason, WrongControlPlane } from "./wire/auth";
import { base64url } from "./wire/bytes";
import { parseCode } from "./wire/code";
import { IndexedKeyStore, type KeyStore, makeKeyPair, newClientID, UnsupportedBrowser } from "./wire/keys";
import { Link, type LinkState, Lines, type SocketLike } from "./wire/link";


/**
 * The page and its control plane are on one machine, so the link can afford to be quick: a beat
 * every 2 s answered within 2 s notices a hung control plane in 4 s, and retries never more than
 * 4 s apart catch its return within 5 (US7, SC-009). A control plane that stops outright closes
 * the socket, which is noticed at once.
 */
export const loopbackTiming = { heartbeat: { every: 2_000, within: 2_000 }, backoff: [0.5, 1, 2, 4] };

export type PageState =
  | LinkState
  | { kind: "pairing" }
  | { kind: "loading" };

/** Why the last pairing didn't work, in the page's words (contracts/browser-auth.md). */
export const pairingWords: Record<RefusalReason | "notACode" | "otherControlPlane" | "unreachable" | "unsupported" | "badProof", string> = {
  expired: "This code has expired. Ask for a new one.",
  spent: "This code has been used. Ask for a new one.",
  unknown: "That isn't a code from this control plane.",
  "bad-proof": "That isn't a code from this control plane.",
  forgotten: "That isn't a code from this control plane.",
  "bad-message": "The control plane answered something this page doesn't understand.",
  "wrong-control-plane": "This code is for another control plane.",
  notACode: "That isn't an Agents code. It starts agents-control:2:c:",
  otherControlPlane: "This code is for another control plane.",
  unreachable: "Can't reach the control plane. Is Agents Host open?",
  unsupported: "This browser can't keep a key that can't be copied out of it. Use the current Safari or Chrome.",
  badProof: "That isn't a code from this control plane.",
};

/** "Safari", "Chrome", "Firefox": the control plane adds "on <this Mac>". */
export function browserName(agent: string = navigator.userAgent): string {
  if (/Edg\//.test(agent)) return "Edge";
  if (/Firefox\//.test(agent)) return "Firefox";
  if (/Chrome\//.test(agent)) return "Chrome";
  if (/Safari\//.test(agent)) return "Safari";
  return "A browser";
}

export class Session {
  readonly state = signal<PageState>({ kind: "loading" });
  /** The words under the code field after a pairing that didn't work, or null. */
  readonly pairingError = signal<string | null>(null);
  /** Set when this browser was forgotten by someone else, for the line above pairing. */
  readonly wasForgotten = signal(false);
  readonly link: Link;
  private readonly tabs: BroadcastChannel | null;
  private forgettingMyself = false;

  constructor(
    readonly keys: KeyStore = new IndexedKeyStore(),
    readonly origin: string = location.origin,
    private readonly open: (url: string) => SocketLike = (url) => new WebSocket(url) as unknown as SocketLike,
  ) {
    const url = origin.replace(/^http/, "ws") + "/v1/connect";
    this.link = new Link({ url, origin, keys, open, ...loopbackTiming });
    this.link.onState((state) => {
      if (state.kind === "forgotten") {
        this.wasForgotten.value = !this.forgettingMyself;
        this.forgettingMyself = false;
        this.tabs?.postMessage("forgotten");
      }
      this.state.value = state;
    });
    // Other tabs of this browser share the key: tell them when it is made or gone. Only
    // the word goes across, never the key.
    this.tabs = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel("agents");
    if (this.tabs) {
      this.tabs.onmessage = (event) => {
        if (event.data === "paired" && this.state.value.kind !== "open") this.link.start();
        if (event.data === "forgotten" && this.state.value.kind !== "forgotten" && this.state.value.kind !== "unpaired") {
          this.link.stop();
          this.wasForgotten.value = true;
          this.state.value = { kind: "forgotten" };
        }
      };
    }
  }

  start(): void {
    this.link.start();
  }

  /** Pairs with the pasted `text`; on success the link connects with the new key. */
  async pair(text: string): Promise<void> {
    this.pairingError.value = null;
    const code = parseCode(text);
    if (!code) {
      this.pairingError.value = pairingWords.notACode;
      return;
    }
    this.state.value = { kind: "pairing" };
    const socket = this.open(this.origin.replace(/^http/, "ws") + "/v1/connect");
    const lines = new Lines(socket);
    socket.onmessage = (event) => lines.push(String(event.data));
    socket.onclose = () => lines.end(new Error("closed"));
    socket.onerror = () => {};
    try {
      await new Promise<void>((resolve, reject) => {
        socket.onopen = () => resolve();
        socket.onclose = () => { lines.end(new Error("closed")); reject(new Error("unreachable")); };
      });
      await this.keys.forget();
      await pair(lines, code, this.origin, browserName(), async () => {
        const { pair: keyPair, publicRaw } = await makeKeyPair();
        const client = newClientID();
        // Kept and read back before it is announced: a browser that can't keep it never pairs.
        await this.keys.save({ privateKey: keyPair.privateKey, publicKey: keyPair.publicKey, client,
          control: base64url(code.controlKey), paired: new Date().toISOString() });
        return { client, publicRaw };
      });
      socket.close(1000, "");
      log("pair.ok");
      this.wasForgotten.value = false;
      this.tabs?.postMessage("paired");
      this.link.start();
    } catch (error) {
      socket.close(1000, "");
      await this.keys.forget();
      this.state.value = { kind: "unpaired" };
      let words = pairingWords.unreachable;
      if (error instanceof Refused) words = pairingWords[error.reason];
      else if (error instanceof WrongControlPlane) words = pairingWords.otherControlPlane;
      else if (error instanceof BadServerProof) words = pairingWords.badProof;
      else if (error instanceof UnsupportedBrowser) words = pairingWords.unsupported;
      else if (error instanceof AnnounceRefused) words = error.message;
      log("pair.failed", error instanceof Refused ? error.reason : undefined);
      this.pairingError.value = words;
    }
  }

  /** **Forget This Browser**: the control plane forgets it, then the key goes (FR-015). */
  async forgetThisBrowser(): Promise<void> {
    this.forgettingMyself = true;
    try {
      await this.link.call("clients/forgetSelf", {});
    } catch {
      this.forgettingMyself = false;
      throw new Error("not forgotten");
    }
  }
}
