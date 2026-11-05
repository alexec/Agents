// This browser in its person's machine lock (#3490, specs/3399-machine-lock D2, D5). On each
// connection the page reads the lock, checks it against the head it pinned, and makes the root
// when there is no lock yet. A browser that is not in the lock asks to join: it sends a
// commitment, a signer sends its nonce, the browser shows its own, and both screens show six
// digits. When this browser is a signer, it shows the other devices that ask, and adds one
// with an addClient entry that it signs.
import { signal } from "@preact/signals";
import { Failure, type Lock, type LockJoinDecided, type LockJoinRequest, type LockJoinStarted, type WireDate } from "../protocol/generated";
import { base64, same } from "../wire/bytes";
import {
  b64, commitment, digits, follow, fromBase64, isClient, LockCheckError, lockClientKind, makeSigningKey, newNonce,
  sign, wireNow, zeroPin, type LockPin, type LockState,
} from "../wire/machineLock";

/** What the model needs of the link: the control plane's calls and this page's keys. */
export interface LockLink {
  call(method: string, params: unknown): Promise<unknown>;
  keyRecord(): Promise<{ client: string } | null>;
  lockKey(): Promise<CryptoKeyPair | null>;
  saveLockKey(pair: CryptoKeyPair): Promise<void>;
}

/** Where the pin is kept: localStorage in the page, memory in the tests. */
export interface PinStore {
  load(): LockPin;
  save(pin: LockPin): void;
}

const pinKey = "agents-lock-pin";

export const localPins: PinStore = {
  load() {
    try {
      const said = JSON.parse(globalThis.localStorage?.getItem(pinKey) ?? "null") as Partial<LockPin> | null;
      if (said && typeof said.person === "string" && typeof said.count === "number" && typeof said.head === "string") {
        return { person: said.person, count: said.count, head: said.head };
      }
    } catch {
      // A pin that does not read is none.
    }
    return zeroPin;
  },
  save(pin) {
    try {
      globalThis.localStorage?.setItem(pinKey, JSON.stringify(pin));
    } catch {
      // Storage that is full or off keeps no pin.
    }
  },
};

export class MemoryPins implements PinStore {
  pin: LockPin = zeroPin;
  load(): LockPin {
    return this.pin;
  }
  save(pin: LockPin): void {
    this.pin = pin;
  }
}

/** Where this browser stands in its lock. */
export type ThisDevice =
  | { kind: "unknown" }
  | { kind: "member" }
  | { kind: "asking"; request: string; expires: number; digits?: string }
  | { kind: "ended"; result: "denied" | "expired" }
  | { kind: "broken"; forked: boolean; why: string };

/** What a signer's card for one request shows. */
export type SignerView =
  | { kind: "compare" }
  | { kind: "another" }
  | { kind: "waiting" }
  | { kind: "digits"; digits: string }
  | { kind: "notPromised" };

export interface SignerCard {
  request: LockJoinRequest;
  view: SignerView;
}

const isChangedElsewhere = (error: unknown) => (error as { code?: unknown } | null)?.code === Failure.changedElsewhere;

/** The words of a broken lock. */
export function brokenWords(device: { forked: boolean; why: string }): string {
  return device.forked ? "The lock changed in a way your devices did not sign." : `Your lock does not check: ${device.why}.`;
}

export class MachineLock {
  readonly device = signal<ThisDevice>({ kind: "unknown" });
  /** The signer's cards: other devices of this person that ask to join. */
  readonly cards = signal<SignerCard[]>([]);

  private client = "";
  private key: { pair: CryptoKeyPair; publicRaw: Uint8Array } | null = null;
  /** This browser's open request and its nonce, kept only in memory. */
  private own: { request: string; nonce: Uint8Array; expires: number; revealed: boolean } | null = null;
  /** Ended by the person's other device: not asked again until Ask Again. */
  private ended = false;
  /** The nonce this browser sent for each request, kept only in memory. */
  private readonly sent = new Map<string, Uint8Array>();
  private rows: LockJoinRequest[] = [];
  private running: Promise<void> | null = null;
  private again = false;
  private timer: ReturnType<typeof setTimeout> | undefined;

  constructor(private readonly link: LockLink, private readonly pins: PinStore = localPins,
    private readonly say: (error: unknown) => void = () => undefined, private readonly now: () => WireDate = () => wireNow()) {}

  /** The flow, once at a time: asked again while it runs, it runs once more after. */
  run(): Promise<void> {
    if (this.running) {
      this.again = true;
      return this.running;
    }
    this.running = (async () => {
      do {
        this.again = false;
        try {
          await this.step();
        } catch (error) {
          this.say(error);
        }
      } while (this.again);
      this.running = null;
    })();
    return this.running;
  }

  /** A control/lock… notification. */
  notify(method: string, params: unknown): void {
    if (method === "control/lockChanged") {
      void this.run();
      return;
    }
    if (method === "control/lockJoinRequested") {
      const row = params as LockJoinRequest | null;
      if (row?.request) void this.take(row).catch((error: unknown) => this.say(error));
      return;
    }
    if (method === "control/lockJoinDecided") {
      const decided = params as LockJoinDecided | null;
      if (decided?.request) this.decided(decided);
    }
  }

  private async signingKey(): Promise<{ pair: CryptoKeyPair; publicRaw: Uint8Array }> {
    if (this.key) return this.key;
    let pair = await this.link.lockKey();
    if (!pair) {
      pair = (await makeSigningKey()).pair;
      await this.link.saveLockKey(pair);
    }
    this.key = { pair, publicRaw: new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)) };
    return this.key;
  }

  /** The lock, checked against the pin, and the pin moved on; null when it is broken. */
  private async checked(): Promise<{ lock: Lock; state: LockState } | null> {
    const lock = (await this.link.call("lock/get", {})) as Lock;
    try {
      const state = await follow(this.pins.load(), lock);
      this.pins.save(state.pin());
      return { lock, state };
    } catch (error) {
      if (!(error instanceof LockCheckError)) throw error;
      this.device.value = { kind: "broken", forked: error.failure === "forked" || error.failure === "behind", why: error.message };
      this.cards.value = [];
      return null;
    }
  }

  private async step(): Promise<void> {
    const record = await this.link.keyRecord();
    if (!record) return;
    this.client = record.client.toUpperCase();
    const { pair, publicRaw } = await this.signingKey();
    let read = await this.checked();
    if (!read) return;
    if (read.lock.entries.length === 0) {
      const root = await sign(pair.privateKey, publicRaw, {
        kind: "root", person: read.lock.person, at: this.now(), key: b64(publicRaw), clientKind: "web",
      });
      try {
        await this.link.call("lock/add", { entries: [root] });
      } catch (error) {
        // Another device made the root at the same time: read it again, once.
        if (!isChangedElsewhere(error)) throw error;
      }
      read = await this.checked();
      if (!read) return;
    }
    const member = read.state.member(publicRaw);
    if (member && isClient(member)) {
      this.own = null;
      this.ended = false;
      this.device.value = { kind: "member" };
      const listed = (await this.link.call("lock/joinRequests", {}).catch(() => [])) as LockJoinRequest[];
      this.rows = [];
      for (const row of listed) await this.take(row);
      await this.show();
      return;
    }
    this.rows = [];
    this.cards.value = [];
    if (this.ended) return;
    if (this.own && this.own.expires > this.now()) {
      // The request goes on: its row may wait for this browser's nonce.
      if (this.device.peek().kind !== "asking") this.device.value = { kind: "asking", request: this.own.request, expires: this.own.expires };
      const listed = (await this.link.call("lock/joinRequests", {}).catch(() => [])) as LockJoinRequest[];
      for (const row of listed) if (row.client.toUpperCase() === this.client) await this.take(row);
      return;
    }
    await this.join(publicRaw);
  }

  private async join(publicRaw: Uint8Array): Promise<void> {
    const nonce = newNonce();
    const started = (await this.link.call("lock/join", { key: base64(publicRaw), commitment: base64(await commitment(publicRaw, nonce)) })) as LockJoinStarted;
    this.own = { request: started.request, nonce, expires: started.expires, revealed: false };
    this.device.value = { kind: "asking", request: started.request, expires: started.expires };
    this.wake();
  }

  /** Ask Again, after a request was denied or ran out. */
  async askAgain(): Promise<void> {
    this.ended = false;
    this.own = null;
    this.device.value = { kind: "unknown" };
    await this.run();
  }

  /** A row from lock/joinRequests or control/lockJoinRequested. */
  private async take(row: LockJoinRequest): Promise<void> {
    if (row.client.toUpperCase() === this.client) {
      const own = this.own;
      if (!own || row.request !== own.request || !row.nonce || !this.key) return;
      const shown = await digits(this.key.publicRaw, own.nonce, fromBase64(row.nonce));
      if (!row.reveal && !own.revealed) {
        own.revealed = true;
        try {
          await this.link.call("lock/joinReveal", { request: own.request, nonce: base64(own.nonce) });
        } catch (error) {
          own.revealed = false;
          throw error;
        }
      }
      if (this.own === own) this.device.value = { kind: "asking", request: own.request, expires: own.expires, digits: shown };
      return;
    }
    if (this.device.peek().kind !== "member") return;
    this.rows = [...this.rows.filter((r) => r.request !== row.request), row];
    await this.show();
  }

  private decided(decided: LockJoinDecided): void {
    if (this.own && decided.request === this.own.request) {
      this.own = null;
      if (decided.result === "approved") {
        void this.run();
      } else {
        this.ended = true;
        this.device.value = { kind: "ended", result: decided.result === "denied" ? "denied" : "expired" };
      }
      return;
    }
    this.sent.delete(decided.request);
    this.rows = this.rows.filter((r) => r.request !== decided.request);
    void this.show();
  }

  /** The signer's cards from the rows: each one's view, the digits made from this browser's nonce. */
  private async show(): Promise<void> {
    const now = this.now();
    this.rows = this.rows.filter((r) => r.expires > now);
    const cards: SignerCard[] = [];
    for (const request of this.rows) cards.push({ request, view: await this.viewOf(request) });
    this.cards.value = cards;
    this.wake();
  }

  private async viewOf(row: LockJoinRequest): Promise<SignerView> {
    const mine = this.sent.get(row.request);
    if (!row.nonce) return { kind: "compare" };
    if (!mine || row.answeredBy?.toUpperCase() !== this.client) return { kind: "another" };
    if (!row.reveal) return { kind: "waiting" };
    const key = fromBase64(row.key);
    const reveal = fromBase64(row.reveal);
    if (!same(await commitment(key, reveal), fromBase64(row.commitment))) return { kind: "notPromised" };
    // Never the row's nonce: a control plane could have put its own there.
    return { kind: "digits", digits: await digits(key, reveal, mine) };
  }

  /** A timer for the next request to run out. */
  private wake(): void {
    clearTimeout(this.timer);
    const own = this.device.peek();
    const ends = [...this.rows.map((r) => r.expires), ...(own.kind === "asking" ? [own.expires] : [])];
    if (ends.length === 0) return;
    const seconds = Math.min(...ends) - this.now();
    this.timer = setTimeout(() => {
      const device = this.device.peek();
      if (device.kind === "asking" && device.expires <= this.now()) {
        this.own = null;
        this.ended = true;
        this.device.value = { kind: "ended", result: "expired" };
      }
      void this.show();
    }, Math.max(0, seconds * 1000) + 500);
    (this.timer as { unref?: () => void } | undefined)?.unref?.();
  }

  /** Compare Digits: send this browser's nonce for the request. */
  async compare(request: string): Promise<void> {
    const nonce = newNonce();
    this.sent.set(request, nonce);
    try {
      await this.link.call("lock/joinAnswer", { request, nonce: base64(nonce) });
    } catch (error) {
      this.sent.delete(request);
      this.say(error);
    }
    await this.show();
  }

  /** Approve: put the request's addClient on the lock, signed by this browser. */
  async approve(request: string): Promise<void> {
    const card = this.cards.peek().find((c) => c.request.request === request);
    if (!card || card.view.kind !== "digits") return;
    const row = card.request;
    try {
      const { pair, publicRaw } = await this.signingKey();
      for (let tries = 0; ; tries++) {
        const read = await this.checked();
        if (!read) return;
        const entry = await sign(pair.privateKey, publicRaw, {
          kind: "addClient", person: read.state.person, previous: b64(read.state.head), at: this.now(), key: row.key,
          name: row.name, clientKind: lockClientKind(row.kind),
        });
        try {
          await this.link.call("lock/add", { entries: [entry] });
          await read.state.add(entry);
          this.pins.save(read.state.pin());
          break;
        } catch (error) {
          if (!isChangedElsewhere(error) || tries > 0) throw error;
        }
      }
      this.sent.delete(request);
      this.rows = this.rows.filter((r) => r.request !== request);
      await this.show();
    } catch (error) {
      this.say(error);
    }
  }

  /** Deny: the request ends. */
  async deny(request: string): Promise<void> {
    try {
      await this.link.call("lock/joinDeny", { request });
      this.sent.delete(request);
      this.rows = this.rows.filter((r) => r.request !== request);
      await this.show();
    } catch (error) {
      this.say(error);
    }
  }
}
