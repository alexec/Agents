// The page's one connection to the control plane, and what it says about itself (071 US1):
// unpaired, pairing, connecting, open, down, forgotten, suspended. Views read `session.state`.
// It pairs with a code, by approval on one of the person's clients (#2097), or with the organisation's
// provider in the same tab (#1002, FR-026, FR-027).
import { signal } from "@preact/signals";
import { log } from "./log";
import { onThisMac } from "./place";
import type { Admitted, SignInDiscovered, SignInOrgProvider, SignInOrgStarted, SignInProviders, SignInTicketResult }
  from "./protocol/generated";
import { askExpired, byOrder, noOrgForEmail, type OIDCReturn, oidcErrorWords, pendingLive, personSuspended, requiredProvider, signInExpired } from "./model/signIn";
import { AnnounceRefused, BadServerProof, pair, Refused, type RefusalReason, WrongControlPlane } from "./wire/auth";
import { base64url } from "./wire/bytes";
import { parseCode } from "./wire/code";
import { IndexedKeyStore, type KeyStore, makeKeyPair, newClientID, UnsupportedBrowser } from "./wire/keys";
import { CallFailed, Link, type LinkState, Lines, type SocketLike } from "./wire/link";
import { connectionApprovalCode, IndexedPendingStore, openSignIn, type PendingStore, type SignInConnection } from "./wire/signIn";


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
  suspended: "Your organisation's sign-in turned your access off.",
  // As the banner says it, for a tab one too many (#2194).
  crowded: "Too many Agents tabs are open in this browser. Close one to use this one.",
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
  /** A code the page was opened with (#109), used once if this browser turns out unpaired. */
  private linked: string | null = null;
  /** The org providers on the pairing page (#1002, FR-026), in order; none on this Mac's page or when the call fails. */
  readonly orgProviders = signal<SignInOrgProvider[]>([]);
  /** A claimed domain sends people to its provider: the page offers Use an Email (FR-011). */
  readonly discover = signal(false);
  /** The provider an orgSignInRequired refusal named (FR-012, FR-029): the page asks for it. */
  readonly orgRequired = signal<SignInOrgProvider | null>(null);
  /** An org sign-in is going: its buttons wait. */
  readonly orgBusy = signal(false);
  /** A built-in sign-in provider is on: the page offers Sign in with your account (#2097). */
  readonly askOn = signal(false);
  /** The code this browser shows while it waits for approval (#2097), or null. */
  readonly askCode = signal<string | null>(null);
  /** The approval sign-in going, so Cancel closes it. */
  private asking: SignInConnection | null = null;

  constructor(
    readonly keys: KeyStore = new IndexedKeyStore(),
    readonly origin: string = location.origin,
    private readonly open: (url: string) => SocketLike = (url) => new WebSocket(url) as unknown as SocketLike,
    readonly pending: PendingStore = new IndexedPendingStore(),
  ) {
    const url = origin.replace(/^http/, "ws") + "/v1/connect";
    this.link = new Link({ url, origin, keys, open, ...loopbackTiming });
    this.link.onState((state) => {
      // Opened with a code (#109): pair with it if there is no key, else leave it unused to
      // expire. Either way only once, and only the first state the link reaches.
      const linked = this.linked;
      this.linked = null;
      if (linked && state.kind === "unpaired") {
        log("pair.fromLink");
        void this.pair(linked);
        return;
      }
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

  /**
   * Connects with the stored key, or pairs with `code` from the page's address if there is none. A
   * return from the org provider (`back`, FR-027) is finished first, and the link starts after it.
   */
  start(code: string | null = null, back: OIDCReturn | null = null): void {
    if (back) {
      void this.finishOrg(back);
      return;
    }
    this.linked = code;
    this.link.start();
  }

  /** A socket to the control plane, open, and its lines. */
  private async dialLines(): Promise<{ socket: SocketLike; lines: Lines }> {
    const socket = this.open(this.origin.replace(/^http/, "ws") + "/v1/connect");
    const lines = new Lines(socket);
    socket.onmessage = (event) => lines.push(String(event.data));
    socket.onerror = () => {};
    await new Promise<void>((resolve, reject) => {
      socket.onopen = () => resolve();
      socket.onclose = () => { lines.end(new Error("closed")); reject(new Error("unreachable")); };
    });
    socket.onclose = () => lines.end(new Error("closed"));
    return { socket, lines };
  }

  /** A sign-in connection as `s:<client>` with that key (#995). */
  private async signInWith(client: string, privateKey: CryptoKey, publicKey: CryptoKey): Promise<SignInConnection> {
    const { socket, lines } = await this.dialLines();
    try {
      return await openSignIn(lines, client, privateKey, publicKey, this.origin);
    } catch (error) {
      socket.close(1000, "");
      throw error;
    }
  }

  /** A sign-in connection with a key made for it alone: to read the providers or find one by email. */
  private async signInOnce(): Promise<SignInConnection> {
    const { pair: keyPair } = await makeKeyPair();
    return this.signInWith(newClientID(), keyPair.privateKey, keyPair.publicKey);
  }

  /**
   * The org providers for the pairing page (FR-026), read on a short sign-in connection. This Mac's
   * page (http on localhost) is not where the provider sends the browser back, and its listener
   * answers no `s:` anyway; the control plane's own page on loopback (a walk's) is https.
   * A failure leaves the page as it was: the code only.
   */
  async loadOrgProviders(): Promise<void> {
    const page = new URL(this.origin);
    if (onThisMac(page.hostname) && page.protocol === "http:") return;
    let connection: SignInConnection | null = null;
    try {
      connection = await this.signInOnce();
      const providers = await connection.call<SignInProviders>("signIn/providers", {});
      this.orgProviders.value = byOrder(providers.orgProviders);
      this.askOn.value = providers.providers.some((p) => p.on);
      this.discover.value = providers.discover === true && this.orgProviders.value.length > 0;
    } catch (error) {
      log("signIn.providersFailed", error instanceof CallFailed ? error.code : undefined);
    } finally {
      connection?.close();
    }
  }

  /** **Use an Email** ▸ Continue (FR-011): the provider a claimed domain sends people to, or null with the page's words said. */
  async discoverEmail(email: string): Promise<SignInOrgProvider | null> {
    this.pairingError.value = null;
    let connection: SignInConnection | null = null;
    try {
      connection = await this.signInOnce();
      const found = await connection.call<SignInDiscovered>("signIn/discover", { email: email.trim() });
      if (!found.provider) {
        this.pairingError.value = noOrgForEmail;
        return null;
      }
      return { id: found.provider, name: found.name ?? found.provider, order: 0 };
    } catch (error) {
      this.pairingError.value = this.orgFailure(error);
      return null;
    } finally {
      connection?.close();
    }
  }

  /**
   * **Sign in with your account** (#2097): signIn/ask with the email or GitHub login typed, on `s:` with
   * a new key. Told control/signInWaiting, the page shows the code it makes from its key and the control key; once the person types it on one of
   * their clients and approves, the key becomes this browser's and the link starts. An account nobody
   * has waits the same, and runs out after 10 minutes.
   */
  async askToPair(account: string): Promise<void> {
    if (this.asking || !account.trim()) return;
    this.pairingError.value = null;
    this.askCode.value = null;
    let connection: SignInConnection | null = null;
    try {
      const { pair: keyPair } = await makeKeyPair();
      const client = newClientID();
      connection = await this.signInWith(client, keyPair.privateKey, keyPair.publicKey);
      this.asking = connection;
      // The code made here, never the control plane's (it shows the same one when honest).
      const code = await connectionApprovalCode(connection, keyPair.publicKey);
      const admitted = await connection.call<Admitted>("signIn/ask", { account: account.trim(), name: browserName() }, 11 * 60_000,
        (method) => {
          if (method === "control/signInWaiting") this.askCode.value = code;
        });
      if (!admitted.client || admitted.client.toUpperCase() !== client) throw new Refused("bad-message");
      // As a code's pairing keeps it: read back before it counts, so a browser that can't keep it never pairs.
      await this.keys.save({ privateKey: keyPair.privateKey, publicKey: keyPair.publicKey, client,
        control: connection.signedIn.control, paired: new Date().toISOString() });
      log("pair.ask");
      this.wasForgotten.value = false;
      this.tabs?.postMessage("paired");
      this.link.start();
    } catch (error) {
      // Cancel closed it: nothing to say.
      if (this.asking === connection) this.pairingError.value = this.askFailure(error);
    } finally {
      if (this.asking === connection) this.asking = null;
      this.askCode.value = null;
      connection?.close();
    }
  }

  /** Cancel while the page waits for approval. */
  cancelAsk(): void {
    const connection = this.asking;
    this.asking = null;
    this.askCode.value = null;
    connection?.close();
  }

  private askFailure(error: unknown): string | null {
    if (error instanceof CallFailed && /10 minutes/.test(error.message)) return askExpired;
    return this.orgFailure(error);
  }

  /**
   * **Sign in with <provider>** (FR-027): a new key and client id wait as the pending sign-in, the
   * control plane gives the provider's address for them, and the tab goes there. The provider sends
   * it back to `/#oidc-ticket=…`, and `finishOrg` pairs.
   */
  async startOrg(provider: string, loginHint?: string): Promise<void> {
    this.pairingError.value = null;
    this.orgBusy.value = true;
    let connection: SignInConnection | null = null;
    try {
      const { pair: keyPair } = await makeKeyPair();
      const client = newClientID();
      await this.pending.save({ privateKey: keyPair.privateKey, publicKey: keyPair.publicKey, client, made: Date.now() });
      connection = await this.signInWith(client, keyPair.privateKey, keyPair.publicKey);
      const params = { provider, purpose: "pair", returnTo: "web", ...(loginHint ? { loginHint } : {}) };
      const started = await connection.call<SignInOrgStarted>("signIn/orgStart", params);
      log("signIn.orgStart");
      location.assign(started.url);
    } catch (error) {
      await this.pending.drop();
      this.pairingError.value = this.orgFailure(error);
      this.orgBusy.value = false;
    } finally {
      connection?.close();
    }
  }

  /**
   * Back from the provider (FR-027): signIn/ticket on `s:<the pending client>`, with the pending key.
   * Paired, the pending key becomes this browser's key, with the hello's control key, and the link
   * starts. The pending sign-in goes either way.
   */
  private async finishOrg(back: OIDCReturn): Promise<void> {
    const pending = await this.pending.load().catch(() => null);
    await this.pending.drop();
    const fail = (words: string | null) => {
      this.pairingError.value = words;
      this.link.start();
    };
    if (!back.ticket) return fail(oidcErrorWords(back));
    if (!pending || !pendingLive(pending.made)) return fail(signInExpired);
    this.state.value = { kind: "pairing" };
    let connection: SignInConnection | null = null;
    try {
      connection = await this.signInWith(pending.client, pending.privateKey, pending.publicKey);
      const paired = await connection.call<SignInTicketResult>("signIn/ticket", { ticket: back.ticket, name: browserName(), kind: "browser" });
      if (!paired.client || paired.client.toUpperCase() !== pending.client) throw new Refused("bad-message");
      // As a code's pairing keeps it: read back before it counts, so a browser that can't keep it never pairs.
      await this.keys.save({ privateKey: pending.privateKey, publicKey: pending.publicKey, client: pending.client,
        control: connection.signedIn.control, paired: new Date().toISOString() });
      log("pair.org");
      this.wasForgotten.value = false;
      this.orgRequired.value = null;
      this.tabs?.postMessage("paired");
      this.link.start();
    } catch (error) {
      if (error instanceof CallFailed && error.code === personSuspended) {
        log("pair.suspended");
        this.state.value = { kind: "suspended", unpaired: true };
        return;
      }
      log("pair.orgFailed", error instanceof CallFailed ? error.code : undefined);
      fail(this.orgFailure(error));
    } finally {
      connection?.close();
    }
  }

  /**
   * An org sign-in's failure in the page's words. orgSignInRequired is said by the page itself, with
   * the button of the provider it names (FR-029), so it gives none.
   */
  private orgFailure(error: unknown): string | null {
    if (error instanceof CallFailed) {
      const wanted = requiredProvider(error.code, error.data);
      if (wanted) {
        this.orgRequired.value = wanted;
        return null;
      }
      return error.message;
    }
    if (error instanceof Refused) return pairingWords[error.reason];
    if (error instanceof UnsupportedBrowser) return pairingWords.unsupported;
    return pairingWords.unreachable;
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

  /** **Forget This Browser**: the control plane forgets it, then the key goes (FR-015). Answers
   *  why not, with nothing changed, or null: the Remote's `forgetThisDevice` (#935). */
  async forgetThisBrowser(): Promise<string | null> {
    this.forgettingMyself = true;
    try {
      await this.link.call("clients/forgetSelf", {});
      return null;
    } catch (error) {
      this.forgettingMyself = false;
      return error instanceof CallFailed ? error.message : "Your Mac is not answering. This browser is still paired.";
    }
  }
}
