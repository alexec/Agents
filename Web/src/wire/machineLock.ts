// A person's machine lock (#3399, #3490, specs/3399-machine-lock): the chain check that
// Go/internal/machinelock does, byte for byte, so the page finds a control plane that adds a
// key, changes an entry, puts entries in another order or forks the chain. The page signs its
// own entries (root, addClient) with a P-256 key that cannot be copied out of the browser.
import type { Base64, Lock, LockBody, LockEntry, LockEntryKind, WireDate } from "../protocol/generated";
import { base64, concat, same, utf8 } from "./bytes";

/** LockBody.v. */
export const version = 1;
/** A signature covers this, then the body. */
const domain = "agents-lock/1\n";
const commitDomain = "agents-lock-join/1\n";
const digitsDomain = "agents-lock-digits/1\n";
export const mostEntries = 4096;
export const mostBody = 4096;
export const nonceSize = 16;

/** The ways a lock fails its check, as Go names them. */
export type LockFailure = "forged" | "outOfOrder" | "invalid" | "forked" | "behind";

const failureWords: Record<LockFailure, string> = {
  forged: "an entry is not signed by a key of the lock",
  outOfOrder: "an entry does not follow the entry before it",
  invalid: "an entry is not one the lock takes",
  forked: "the lock changed in a way your devices did not sign",
  behind: "the lock is older than the one last seen",
};

/** A failed check: what, and at which entry (-1 for the lock as a whole). */
export class LockCheckError extends Error {
  constructor(readonly failure: LockFailure, readonly index: number, readonly why: string) {
    super(index < 0 ? `${failureWords[failure]}: ${why}` : `entry ${index}: ${failureWords[failure]}: ${why}`);
  }
}

export function fromBase64(text: string | undefined): Uint8Array {
  if (!text) return new Uint8Array();
  const binary = atob(text);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

export function hexOf(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256(...parts: Uint8Array[]): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", concat(...parts) as BufferSource));
}

/** An entry's hash: the SHA-256 of its body. */
export function hashOf(entry: LockEntry): Promise<Uint8Array> {
  return sha256(fromBase64(entry.body));
}

/** A P-256 public key, X9.63 uncompressed, as Go's ecdh.NewPublicKey takes it. */
async function verifyKey(raw: Uint8Array): Promise<CryptoKey | null> {
  if (raw.length !== 65 || raw[0] !== 4) return null;
  try {
    return await crypto.subtle.importKey("raw", raw as BufferSource, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  } catch {
    return null;
  }
}

/** Seconds since 2001-01-01, as a WireDate is. */
export function wireNow(now = Date.now()): WireDate {
  return (now / 1000 - 978307200) as WireDate;
}

/** Standard base64 with padding, as the wire's Base64 is. */
export function b64(bytes: Uint8Array): Base64 {
  return base64(bytes) as Base64;
}

/** A member: a key the lock names now. */
export interface LockMember {
  kind: LockEntryKind;
  key: Uint8Array;
  sealingKey: Uint8Array;
  id: string;
  name: string;
  clientKind: string;
  /** An invite's, as a WireDate; 0 for none. */
  expires: number;
  /** The index of the entry that added it. */
  entry: number;
}

/** Whether the member is a client, so a signer. */
export function isClient(member: LockMember): boolean {
  return member.kind === "root" || member.kind === "addClient";
}

/** What a client keeps of the lock it last checked. head is base64. */
export interface LockPin {
  person: string;
  count: number;
  head: string;
}

export const zeroPin: LockPin = { person: "", count: 0, head: "" };

const keyID = (key: Uint8Array) => base64(key);

/** A lock as its entries leave it. */
export class LockState {
  person = "";
  root: Uint8Array = new Uint8Array();
  readonly hashes: Uint8Array[] = [];
  readonly members = new Map<string, LockMember>();
  recovery: Uint8Array | null = null;

  get count(): number {
    return this.hashes.length;
  }

  /** The newest entry's hash; 32 zero bytes for a lock with no entries. */
  get head(): Uint8Array {
    return this.hashes[this.hashes.length - 1] ?? new Uint8Array(32);
  }

  member(key: Uint8Array): LockMember | undefined {
    return this.members.get(keyID(key));
  }

  /** Whether the key may sign an entry: a client of the person, or the recovery key. */
  signer(key: Uint8Array): boolean {
    const m = this.member(key);
    if (m) return isClient(m);
    return this.recovery !== null && same(key, this.recovery);
  }

  /** The members of a kind, in the order they were added; addClient takes the root too. */
  membersOf(kind: LockEntryKind): LockMember[] {
    return [...this.members.values()]
      .filter((m) => m.kind === kind || (kind === "addClient" && m.kind === "root"))
      .sort((a, b) => a.entry - b.entry);
  }

  pin(): LockPin {
    return { person: this.person, count: this.count, head: base64(this.head) };
  }

  private take(body: LockBody, index: number): void {
    const key = fromBase64(body.key);
    this.members.set(keyID(key), {
      kind: body.kind, key, sealingKey: fromBase64(body.sealingKey), id: body.id ?? "", name: body.name ?? "",
      clientKind: body.clientKind ?? "", expires: body.expires ?? 0, entry: index,
    });
  }

  /** Checks one entry onto the state and, when it passes, takes it. An empty state takes only a root. */
  async add(entry: LockEntry): Promise<void> {
    const i = this.hashes.length;
    const bad = (failure: LockFailure, why: string) => new LockCheckError(failure, i, why);
    if (i >= mostEntries) throw bad("invalid", `the lock has ${mostEntries} entries, the most it takes`);
    const body = await open(entry, i);
    const key = fromBase64(body.key);
    if (!(await verifyKey(key))) throw bad("invalid", "its key is not a P-256 key");
    const signerKey = fromBase64(body.signer);
    if (i === 0) {
      if (body.kind !== "root") throw bad("outOfOrder", `the first entry is ${body.kind}, not root`);
      if (fromBase64(body.previous).length !== 0) throw bad("outOfOrder", "the root names an entry before it");
      if (!body.person) throw bad("invalid", "the root names no person");
      if (!same(signerKey, key)) throw bad("forged", "the root is not signed by the key it names");
      this.person = body.person;
      this.take(body, i);
      this.root = await hashOf(entry);
      this.hashes.push(this.root);
      return;
    }
    if (body.person !== this.person) throw bad("forged", `it names the person "${body.person}", not "${this.person}"`);
    if (!same(fromBase64(body.previous), this.head)) throw bad("outOfOrder", `it follows ${hexOf(fromBase64(body.previous))}, not the head ${hexOf(this.head.slice(0, 8))}`);
    let signer = this.signer(signerKey);
    // An invite signs one addMachine, and is spent once that entry is taken.
    let spent = "";
    switch (body.kind) {
      case "root":
        throw bad("outOfOrder", "a second root");
      case "addMachine": {
        const sealing = fromBase64(body.sealingKey);
        if (sealing.length === 0 || !(await verifyKey(sealing))) throw bad("invalid", "the machine's sealing key is not a P-256 key");
        const invite = this.member(signerKey);
        if (invite?.kind === "invite") {
          if (!(body.at < invite.expires)) throw bad("forged", "its invite expired");
          spent = keyID(signerKey);
          signer = true;
        }
        break;
      }
      case "invite":
        if (body.expires === undefined || !(body.expires > body.at)) throw bad("invalid", "the invite has no expiry after it was made");
        break;
      case "addClient":
      case "remove":
      case "recovery":
        break;
      default:
        throw bad("invalid", `the kind "${String(body.kind)}" is not one this build knows`);
    }
    if (!signer) throw bad("forged", "its signer is not a client or the recovery key of the lock");
    if (body.kind === "remove") {
      if (!this.members.has(keyID(key))) throw bad("invalid", "it removes a key the lock does not name");
      this.members.delete(keyID(key));
    } else if (body.kind === "recovery") {
      if (this.members.has(keyID(key))) throw bad("invalid", "the recovery key is a member of the lock");
      this.recovery = key;
    } else {
      if (this.members.has(keyID(key)) || (this.recovery !== null && same(key, this.recovery))) throw bad("invalid", "its key is in the lock already");
      this.take(body, i);
    }
    if (spent) this.members.delete(spent);
    this.hashes.push(await hashOf(entry));
  }
}

/** Whether a field is absent or standard base64, as Go's []byte reads it. */
function readsAsBase64(value: unknown): boolean {
  if (value === undefined || value === null) return true;
  if (typeof value !== "string" || !/^[A-Za-z0-9+/]*={0,2}$/.test(value) || value.length % 4 !== 0) return false;
  try {
    atob(value);
    return true;
  } catch {
    return false;
  }
}

/**
 * Reads an entry's body and checks its signature by the signer it names. It does not say
 * whether that signer may sign: LockState.add does.
 */
export async function open(entry: LockEntry, index = 0): Promise<LockBody> {
  const bad = (failure: LockFailure, why: string) => new LockCheckError(failure, index, why);
  let bytes: Uint8Array;
  let sig: Uint8Array;
  try {
    bytes = fromBase64(entry.body);
    sig = fromBase64(entry.sig);
  } catch {
    throw bad("invalid", "it is not base64");
  }
  if (bytes.length > mostBody) throw bad("invalid", `its body is over ${mostBody} bytes`);
  let body: LockBody;
  try {
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as LockBody;
  } catch (error) {
    throw bad("invalid", `its body does not read: ${String(error)}`);
  }
  if (typeof body !== "object" || body === null) throw bad("invalid", "its body does not read");
  if (body.v !== version) throw bad("invalid", `version ${String(body.v)}, not ${version}`);
  if (typeof body.at !== "number" || typeof body.person !== "string" || typeof body.kind !== "string" ||
    !["signer", "key", "previous", "sealingKey"].every((field) => readsAsBase64((body as unknown as Record<string, unknown>)[field]))) {
    throw bad("invalid", "its body does not read");
  }
  const key = await verifyKey(fromBase64(body.signer));
  if (!key) throw bad("forged", "its signer is not a P-256 key");
  const good = sig.length === 64 &&
    (await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig as BufferSource, concat(utf8(domain), bytes) as BufferSource));
  if (!good) throw bad("forged", "its signature does not check");
  return body;
}

/** Reads a whole chain, the root first, and says where it leaves the lock. */
export async function check(entries: LockEntry[]): Promise<LockState> {
  const state = new LockState();
  for (const entry of entries) await state.add(entry);
  return state;
}

/**
 * Checks a lock against the pin last kept: it must pass check, be the same person's, and grow
 * from the pinned head. A zero pin takes any lock that checks (trust on first use, D9).
 */
export async function follow(pin: LockPin, lock: Lock): Promise<LockState> {
  const state = await check(lock.entries);
  if (pin.count === 0) return state;
  if (state.person !== pin.person) throw new LockCheckError("forked", -1, `it is "${state.person}"'s lock, not "${pin.person}"'s`);
  if (state.count < pin.count) throw new LockCheckError("behind", -1, `${state.count} entries, and ${pin.count} were seen`);
  const at = state.hashes[pin.count - 1]!;
  if (!same(at, fromBase64(pin.head))) throw new LockCheckError("forked", -1, `entry ${pin.count - 1} is ${hexOf(at.slice(0, 8))}, and another was pinned`);
  return state;
}

/** What a new entry says; sign sets v and signer. */
export type LockBodyDraft = Omit<LockBody, "v" | "signer">;

/** An entry of body, signed with the key; publicRaw is its public half, 65 bytes. */
export async function sign(privateKey: CryptoKey, publicRaw: Uint8Array, draft: LockBodyDraft): Promise<LockEntry> {
  // The fields in Go's order, so the bytes read as Go's would.
  const full: Record<string, unknown> = { v: version, kind: draft.kind, person: draft.person };
  if (draft.previous) full["previous"] = draft.previous;
  full["signer"] = base64(publicRaw);
  full["at"] = draft.at;
  full["key"] = draft.key;
  for (const field of ["sealingKey", "id", "name", "clientKind", "expires"] as const) {
    if (draft[field] !== undefined) full[field] = draft[field];
  }
  const body = utf8(JSON.stringify(full));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, concat(utf8(domain), body) as BufferSource));
  return { body: b64(body), sig: b64(sig) };
}

/** A new signing key: P-256, the private half non-extractable, and its public half as 65 bytes. */
export async function makeSigningKey(): Promise<{ pair: CryptoKeyPair; publicRaw: Uint8Array }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"])) as CryptoKeyPair;
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { pair, publicRaw };
}

/** A 16-byte nonce. */
export function newNonce(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(nonceSize));
}

/** What a new client sends first: SHA-256 of the domain, its key, its nonce. */
export function commitment(key: Uint8Array, nonce: Uint8Array): Promise<Uint8Array> {
  return sha256(utf8(commitDomain), key, nonce);
}

/**
 * The six digits both screens show: the first four bytes of SHA-256 of the domain, the new
 * client's key, its nonce and the signer's nonce, big-endian, modulo a million, with zeros.
 */
export async function digits(key: Uint8Array, clientNonce: Uint8Array, signerNonce: Uint8Array): Promise<string> {
  const sum = await sha256(utf8(digitsDomain), key, clientNonce, signerNonce);
  const n = new DataView(sum.buffer, sum.byteOffset, 4).getUint32(0, false);
  return String(n % 1_000_000).padStart(6, "0");
}

/** "123456" as a person reads it: "123 456". */
export function spaced(six: string): string {
  return `${six.slice(0, 3)} ${six.slice(3)}`;
}

/** A client's kind in an addClient entry: mac, remote or web. */
export function lockClientKind(kind: string): string {
  if (kind === "mac") return "mac";
  if (kind === "iPhone" || kind === "iPad") return "remote";
  if (kind === "browser") return "web";
  return kind;
}
