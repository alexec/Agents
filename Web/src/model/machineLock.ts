// This browser in its person's machine lock (#3490, specs/3399-machine-lock D2, D5). On each
// connection the page reads the lock, checks it against the head it pinned, and makes the root
// when there is no lock yet. A browser that is not in the lock asks to join: it sends a
// commitment, a signer sends its nonce, the browser shows its own, and both screens show six
// digits. When this browser is a signer, it shows the other devices that ask, and adds one
// with an addClient entry that it signs.
//
// Machines (#3491, D3, D8): a machine that asks is shown the same way and added with an
// addMachine; a host code this browser shows carries an invite it put on the lock; and a
// secret is sealed only to a machine whose key its owner's lock names.
import { signal } from "@preact/signals";
import {
  Failure, type ControlCodeShown, type Lock, type LockJoinDecided, type LockJoinRequest, type LockJoinStarted, type WireDate,
} from "../protocol/generated";
import { base64, fromBase64url, hex, same } from "../wire/bytes";
import {
  b64, commitment, digits, follow, fromBase64, hashOf, inviteCode, isClient, LockCheckError, lockClientKind, makeInviteKey, makeRecovery,
  makeSigningKey, newNonce, openRecovery, parseRecovery, RecoveryError, sign, signedRecipients, wireNow, zeroPin, type LockPin,
  type LockState,
} from "../wire/machineLock";
import type { LockSigner } from "../wire/lockChannel";

/** What the model needs of the link: the control plane's calls and this page's keys. */
export interface LockLink {
  call(method: string, params: unknown): Promise<unknown>;
  keyRecord(): Promise<{ client: string; control?: string } | null>;
  lockKey(): Promise<CryptoKeyPair | null>;
  saveLockKey(pair: CryptoKeyPair): Promise<void>;
}

/** Where the pin is kept: localStorage in the page, memory in the tests. */
export interface PinStore {
  load(): LockPin;
  save(pin: LockPin): void;
}

const pinKey = "agents-lock-pin";

/**
 * The name this browser keeps a control plane's lock pins under (#3651), as the Mac and the
 * Remote name theirs: the first eight bytes of the control plane's key, in hex. A re-pair to
 * another control plane then starts from no pin, not from the old one. Without a key, the
 * plain name.
 */
export function pinName(control: string | undefined): string {
  const key = control ? fromBase64url(control) : null;
  return key && key.length >= 8 ? `${pinKey}.${hex(key.subarray(0, 8))}` : pinKey;
}

/** The pin kept in localStorage under key, or under the name key() gives at each use. */
export function pinsAt(key: string | (() => string)): PinStore {
  const name = typeof key === "string" ? () => key : key;
  return {
    load() {
      try {
        const said = JSON.parse(globalThis.localStorage?.getItem(name()) ?? "null") as Partial<LockPin> | null;
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
        globalThis.localStorage?.setItem(name(), JSON.stringify(pin));
      } catch {
        // Storage that is full or off keeps no pin.
      }
    },
  };
}

/**
 * Whether the person saved or skipped the recovery key on this device (#3493, D4), by person:
 * localStorage in the page, memory in the tests.
 */
export interface RecoveryDone {
  done(person: string): boolean;
  set(person: string): void;
}

/** The recovery marks kept in localStorage beside the pins named by name(). */
export function recoveryDoneAt(name: () => string): RecoveryDone {
  return {
    done(person) {
      try {
        return globalThis.localStorage?.getItem(`${name()}.recoveryDone:${person}`) === "1";
      } catch {
        return false;
      }
    },
    set(person) {
      try {
        globalThis.localStorage?.setItem(`${name()}.recoveryDone:${person}`, "1");
      } catch {
        // Storage that is full or off asks again next time.
      }
    },
  };
}

export class MemoryRecoveryDone implements RecoveryDone {
  readonly people = new Set<string>();
  done(person: string): boolean {
    return this.people.has(person);
  }
  set(person: string): void {
    this.people.add(person);
  }
}

/** The pins and recovery marks this browser keeps, mine and other people's, for every control
 *  plane, gone when the control plane forgets it (#3670): a new pairing starts clean. */
export function forgetPins(storage: Pick<Storage, "length" | "key" | "removeItem"> | undefined = globalThis.localStorage): void {
  removePins(storage, () => true);
}

/** The pins and recovery marks of every other control plane than the one `name` is for, gone once
 *  the page knows its own (#3750): a page is paired with one at a time. Nothing goes while `name` is
 *  the plain one. */
export function prunePins(name: string, storage: Pick<Storage, "length" | "key" | "removeItem"> | undefined = globalThis.localStorage): void {
  if (name === pinKey) return;
  removePins(storage, (key) => !under(key, name));
}

function under(key: string, name: string): boolean {
  return key === name || key.startsWith(`${name}:`) || key.startsWith(`${name}.`);
}

function removePins(storage: Pick<Storage, "length" | "key" | "removeItem"> | undefined, goes: (key: string) => boolean): void {
  if (!storage) return;
  try {
    const kept: string[] = [];
    for (let i = 0; i < storage.length; i++) {
      const key = storage.key(i);
      if (key && (under(key, pinKey) || key.startsWith("agents-lock-recovery-done:")) && goes(key)) kept.push(key);
    }
    for (const key of kept) storage.removeItem(key);
  } catch {
    // Storage that is off keeps nothing to forget.
  }
}

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

/**
 * The recovery key's card on a device in the lock (#3493, D4): the key, shown once after it is
 * made; or, while the lock has one client and the person neither saved nor skipped it here, an
 * offer to make one (the key shown before is gone once the page closes).
 */
export type RecoveryCard = { kind: "none" } | { kind: "show"; text: string } | { kind: "offer" };

export interface SignerCard {
  request: LockJoinRequest;
  view: SignerView;
}

/** An invite works for five minutes, as a code does (D3). */
const inviteLifetime = 5 * 60;

const isChangedElsewhere = (error: unknown) => (error as { code?: unknown } | null)?.code === Failure.changedElsewhere;

/** What Start a New Lock asks before it drops the lock (#3493, D4); the Mac and the Remote say the same. */
export const newLockWords =
  "Start a new lock? Do this only if you lost every device and your recovery key. Each machine refuses the new lock until you run agentsd lock reset in its shell, and approve it here.";

/** The words of a broken lock. */
export function brokenWords(device: { forked: boolean; why: string }): string {
  return device.forked ? "The lock changed in a way your devices did not sign." : `Your lock does not check: ${device.why}.`;
}

export class MachineLock {
  readonly device = signal<ThisDevice>({ kind: "unknown" });
  /** The signer's cards: other devices of this person that ask to join. */
  readonly cards = signal<SignerCard[]>([]);
  readonly recovery = signal<RecoveryCard>({ kind: "none" });

  private client = "";
  private key: { pair: CryptoKeyPair; publicRaw: Uint8Array } | null = null;
  /** This browser's open request and its nonce, kept only in memory. */
  private own: { request: string; nonce: Uint8Array; expires: number; revealed: boolean } | null = null;
  /** Ended by the person's other device: not asked again until Ask Again. */
  private ended = false;
  /** The nonce this browser sent for each request, kept only in memory. */
  private readonly sent = new Map<string, Uint8Array>();
  private rows: LockJoinRequest[] = [];
  /** The lock as this page last checked it. */
  private state: LockState | null = null;
  private running: Promise<void> | null = null;
  private again = false;
  private timer: ReturnType<typeof setTimeout> | undefined;

  /** The control plane's key from the key record, which names where the pins are kept. */
  private control: string | undefined;
  private readonly pins: PinStore;
  /** The pins are this page's own, in localStorage, so another control plane's can be pruned. */
  private readonly keepsPins: boolean;
  private readonly pinsOf: (person: string) => PinStore;
  private readonly recoveryDone: RecoveryDone;

  /** Without stores, the pins are kept in localStorage under this control plane's name (#3651). */
  constructor(private readonly link: LockLink, pins?: PinStore,
    private readonly say: (error: unknown) => void = () => undefined, private readonly now: () => WireDate = () => wireNow(),
    pinsOf?: (person: string) => PinStore, recoveryDone?: RecoveryDone) {
    const name = () => pinName(this.control);
    this.keepsPins = !pins;
    this.pins = pins ?? pinsAt(name);
    // Another person's lock, as an admin's page pins it to check the machines it seals to (D7).
    this.pinsOf = pinsOf ?? ((person) => pinsAt(() => `${name()}:${person}`));
    this.recoveryDone = recoveryDone ?? recoveryDoneAt(name);
  }

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

  /**
   * This page's lock key and its checked lock, for the channels it opens to machines (#3492,
   * D6); null until this page is in its lock, and then it talks to machines as before.
   */
  async signer(): Promise<{ signer: LockSigner; state: LockState } | null> {
    if (this.running) await this.running;
    const state = this.state;
    if (this.device.value.kind !== "member" || !state || !this.key) return null;
    const member = state.member(this.key.publicRaw);
    if (!member || !isClient(member)) return null;
    return { signer: { privateKey: this.key.pair.privateKey, publicRaw: this.key.publicRaw }, state };
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
    // Asked before the first step (an admin's seal): the pins' name is the control plane's.
    if (this.control === undefined) this.control = (await this.link.keyRecord())?.control;
    try {
      const state = await follow(this.pins.load(), lock);
      this.pins.save(state.pin());
      this.state = state;
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
    this.control = record.control;
    if (this.keepsPins) prunePins(pinName(this.control));
    const { pair, publicRaw } = await this.signingKey();
    let read = await this.checked();
    if (!read) return;
    if (read.lock.entries.length === 0) {
      const root = await sign(pair.privateKey, publicRaw, {
        kind: "root", person: read.lock.person, at: this.now(), key: b64(publicRaw), id: this.client, clientKind: "web",
      });
      // The recovery key goes on with the root, and is shown once (D4).
      const made = await makeRecovery();
      const recovery = await sign(pair.privateKey, publicRaw, {
        kind: "recovery", person: read.lock.person, previous: b64(await hashOf(root)), at: this.now(), key: b64(made.publicRaw),
        sealed: b64(made.sealed),
      });
      try {
        await this.link.call("lock/add", { entries: [root, recovery] });
        this.recovery.value = { kind: "show", text: made.text };
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
      this.offerRecovery(read.state);
      const listed = (await this.link.call("lock/joinRequests", {}).catch(() => [])) as LockJoinRequest[];
      this.rows = [];
      for (const row of listed) await this.take(row);
      await this.show();
      return;
    }
    this.rows = [];
    this.cards.value = [];
    this.recovery.value = { kind: "none" };
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

  /** The offer of a recovery key, while the lock has one client and none was saved or skipped here. */
  private offerRecovery(state: LockState): void {
    if (this.recovery.peek().kind === "show") return;
    const clients = state.membersOf("addClient").length;
    this.recovery.value = clients <= 1 && !this.recoveryDone.done(state.person) ? { kind: "offer" } : { kind: "none" };
  }

  /** I Saved It, or Skip: not asked again on this device. */
  recoveryDismissed(): void {
    if (this.state) this.recoveryDone.set(this.state.person);
    this.recovery.value = { kind: "none" };
  }

  /** Make Recovery Key: a new recovery entry, which takes the old key's place, and its key shown once. */
  async makeRecoveryKey(): Promise<void> {
    try {
      const { pair, publicRaw } = await this.signingKey();
      const made = await makeRecovery();
      for (let tries = 0; ; tries++) {
        const read = await this.checked();
        if (!read || !read.state.signer(publicRaw)) return;
        const entry = await sign(pair.privateKey, publicRaw, {
          kind: "recovery", person: read.state.person, previous: b64(read.state.head), at: this.now(), key: b64(made.publicRaw),
          sealed: b64(made.sealed),
        });
        try {
          await this.link.call("lock/add", { entries: [entry] });
        } catch (error) {
          if (!isChangedElsewhere(error) || tries > 0) throw error;
          continue;
        }
        await read.state.add(entry);
        this.pins.save(read.state.pin());
        this.recovery.value = { kind: "show", text: made.text };
        return;
      }
    } catch (error) {
      this.say(error);
    }
  }

  /**
   * Use Recovery Key (#3493, D4): this browser, not in its lock, opens the lock's recovery key
   * with the secret the person typed, and signs its own addClient with it. Null when it is in;
   * else the words to show under the field.
   */
  async useRecoveryKey(text: string): Promise<string | null> {
    try {
      const secret = await parseRecovery(text);
      const { publicRaw } = await this.signingKey();
      for (let tries = 0; ; tries++) {
        const read = await this.checked();
        if (!read) return "Your lock does not check, so the recovery key cannot be used.";
        const { recovery, recoverySealed } = read.state;
        if (!recovery || !recoverySealed) return "Your lock has no recovery key. Start a new lock instead.";
        const key = await openRecovery(secret, recovery, recoverySealed);
        const entry = await sign(key, recovery, {
          kind: "addClient", person: read.state.person, previous: b64(read.state.head), at: this.now(), key: b64(publicRaw),
          ...(this.client ? { id: this.client } : {}), clientKind: "web",
        });
        try {
          await this.link.call("lock/add", { entries: [entry] });
        } catch (error) {
          if (!isChangedElsewhere(error) || tries > 0) throw error;
          continue;
        }
        await read.state.add(entry);
        this.pins.save(read.state.pin());
        this.own = null;
        this.ended = false;
        await this.run();
        return null;
      }
    } catch (error) {
      if (error instanceof RecoveryError) return error.message;
      this.say(error);
      return "The recovery key could not be used. Try again.";
    }
  }

  /**
   * Start a New Lock (#3493, D4): every signer and the recovery key are lost. The control plane
   * drops the lock, this browser forgets its pin and signs a new root, and shows a new recovery
   * key. Each machine joins again after agentsd lock reset.
   */
  async startNewLock(): Promise<void> {
    try {
      await this.link.call("lock/reset", {});
      this.pins.save(zeroPin);
      this.own = null;
      this.ended = false;
      this.device.value = { kind: "unknown" };
      await this.run();
    } catch (error) {
      this.say(error);
    }
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
        // A machine's key is also its sealing key (D8).
        const entry = await sign(pair.privateKey, publicRaw, row.machine
          ? {
            kind: "addMachine", person: read.state.person, previous: b64(read.state.head), at: this.now(), key: row.key,
            sealingKey: row.key, id: row.machine, name: row.name,
          }
          : {
            kind: "addClient", person: read.state.person, previous: b64(read.state.head), at: this.now(), key: row.key,
            id: row.client, name: row.name, clientKind: lockClientKind(row.kind),
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

  /**
   * A host code with an invite (#3491, D3): this browser puts an invite on the lock and adds its
   * key to the code, so the machine adds itself. A browser that is not a signer, or a lock that
   * does not check, gives the code back as it was: the machine then asks to join.
   */
  async invite(shown: ControlCodeShown): Promise<ControlCodeShown> {
    if (this.device.peek().kind !== "member") return shown;
    try {
      const { pair, publicRaw } = await this.signingKey();
      const invite = await makeInviteKey();
      for (let tries = 0; ; tries++) {
        const read = await this.checked();
        if (!read || !read.state.signer(publicRaw)) return shown;
        const at = this.now();
        const entry = await sign(pair.privateKey, publicRaw, {
          kind: "invite", person: read.state.person, previous: b64(read.state.head), at, key: b64(invite.publicRaw),
          expires: (at + inviteLifetime) as WireDate,
        });
        try {
          await this.link.call("lock/add", { entries: [entry] });
        } catch (error) {
          if (!isChangedElsewhere(error) || tries > 0) throw error;
          continue;
        }
        await read.state.add(entry);
        this.pins.save(read.state.pin());
        const text = inviteCode(shown.text, invite.privateRaw, read.state.pin());
        return { ...shown, text, ...(shown.command ? { command: shown.command.replace(shown.text, text) } : {}) };
      }
    } catch (error) {
      this.say(error);
      return shown;
    }
  }

  /**
   * The recipients this browser may seal to (#3491, D8): every client, and each machine whose
   * key its owner's lock names. Another person's lock (an admin sealing an org route) is pinned
   * here too, on first use.
   */
  async signed<R extends { id: string; owner?: string; publicKey: string }>(recipients: R[]): Promise<R[]> {
    const own = await this.checked().catch(() => null);
    return signedRecipients(recipients, async (person) => {
      if (!person || person === own?.state.person) return own?.state ?? null;
      const lock = (await this.link.call("lock/get", { person })) as Lock;
      const pins = this.pinsOf(person);
      const state = await follow(pins.load(), lock);
      pins.save(state.pin());
      return state;
    });
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
