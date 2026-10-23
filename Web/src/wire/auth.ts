// The key exchange from the browser (071 contracts/browser-auth.md; 058 contracts/wire.md):
// hello, auth, ok. Nothing but this is sent until the control plane has proved its key.
import { DeclaredCapabilities } from "../protocol/capabilities.generated";
import { base64, base64url, concat, fromBase64url, same, utf8 } from "./bytes";
import { type ClientCode, codeIdentity } from "./code";
import { clientKey, codeKey, type KeyRecord } from "./keys";

/** Lines over one socket: the exchange's view of a WebSocket. */
export interface LineSocket {
  send(line: string): void;
  /** The next line, or a rejection when the socket closes or `timeoutMs` passes. */
  next(timeoutMs?: number): Promise<string>;
  close(code?: number, reason?: string): void;
}

export type RefusalReason =
  | "unknown" | "forgotten" | "expired" | "spent" | "bad-proof" | "wrong-control-plane" | "bad-message"
  // The person's org provider suspended them (#1002, D13): the key stays.
  | "suspended"
  // The browser's key, or its person, holds as many sockets as it may: too many tabs (#2194).
  | "crowded";

/** The control plane said no. */
export class Refused extends Error {
  constructor(readonly reason: RefusalReason) {
    super(`refused: ${reason}`);
  }
}

/** The hello came from another control plane than the code's, or than the one paired with. */
export class WrongControlPlane extends Error {
  constructor() {
    super("wrong control plane");
  }
}

/**
 * The control plane wouldn't pair this browser with that code, and said why: a code made for a
 * window or a phone, say, which is good only over TLS (071 R2). Its words are the page's to show.
 */
export class AnnounceRefused extends Error {}

/** The control plane's proof didn't check out: not ours, or not who it says. */
export class BadServerProof extends Error {
  constructor() {
    super("the control plane's proof didn't check out");
  }
}

interface Hello {
  name: string;
  control: string;
  nonce: string;
  /** The control plane's key before it rotated (#997), for 30 days after. */
  previous?: string;
}

export interface Admitted {
  /** The control plane's name, from its hello. */
  name: string;
  /** The control plane's new key, base64url, given to a browser that proved itself with the previous one (#997). */
  newKey?: string;
}

/** An ok's new key (#997): the HMAC of it under the shared key from the previous one. */
interface NewKeyOffer {
  key?: string;
  proof?: string;
}

function parse(line: string): Record<string, unknown> {
  const value: unknown = JSON.parse(line);
  if (typeof value !== "object" || value === null) throw new Refused("bad-message");
  return value as Record<string, unknown>;
}

async function readHello(socket: LineSocket): Promise<Hello> {
  const hello = parse(await socket.next(15_000))["hello"] as Partial<Hello> | undefined;
  if (!hello || typeof hello.control !== "string" || typeof hello.nonce !== "string") throw new Refused("bad-message");
  const read: Hello = { name: String(hello.name ?? ""), control: hello.control, nonce: hello.nonce };
  if (typeof hello.previous === "string") read.previous = hello.previous;
  return read;
}

function transcript(serverNonce: Uint8Array, peerNonce: Uint8Array, identity: string, origin: string): Uint8Array {
  return concat(utf8("agents-auth-v1"), serverNonce, peerNonce, utf8(identity), utf8(origin));
}

/** Proves `key` as `identity`, and checks the control plane proves it back; the ok's new key, if it gave one. */
async function prove(socket: LineSocket, hello: Hello, identity: string, key: CryptoKey, origin: string,
                     peerNonce: Uint8Array, kind: string, publicKey?: Uint8Array): Promise<NewKeyOffer | undefined> {
  const serverNonce = fromBase64url(hello.nonce);
  if (!serverNonce) throw new Refused("bad-message");
  const said = transcript(serverNonce, peerNonce, identity, origin);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, concat(utf8("c"), said) as BufferSource));
  // A paired client says what it has (#1748); a code's holder is not a client yet.
  const capabilities = identity.startsWith("c:") ? DeclaredCapabilities["client"] : undefined;
  // A client signing in (`s:`, #995) says its new key, X9.63, in standard base64 as Go writes bytes.
  const publicKey64 = publicKey ? base64(publicKey) : undefined;
  socket.send(JSON.stringify({ auth: { id: identity, nonce: base64url(peerNonce), mac: base64url(mac), kind, capabilities, publicKey: publicKey64 } }));
  const answer = parse(await socket.next(15_000));
  const refused = answer["refused"] as { reason?: RefusalReason } | undefined;
  if (refused) throw new Refused(refused.reason ?? "unknown");
  const ok = answer["ok"] as { mac?: string; newKey?: NewKeyOffer } | undefined;
  const theirs = ok?.mac ? fromBase64url(ok.mac) : null;
  if (!ok || !theirs) throw new Refused("bad-message");
  const proved = await crypto.subtle.verify("HMAC", key, theirs as BufferSource, concat(utf8("s"), said) as BufferSource);
  if (!proved) throw new BadServerProof();
  return ok.newKey;
}

/** The proof of a rotated key (#997): HMAC("k" ‖ "agents-newkey-v1" ‖ the new key) under the shared key. */
export function newKeyMessage(key: Uint8Array): Uint8Array {
  return concat(utf8("k"), utf8("agents-newkey-v1"), key);
}

/** The new key from an ok, once its proof is the previous key's holder's; a wrong one is not this control plane. */
async function checkedNewKey(offer: NewKeyOffer, shared: CryptoKey): Promise<string> {
  const key = offer.key ? fromBase64url(offer.key) : null;
  const proof = offer.proof ? fromBase64url(offer.proof) : null;
  if (!key || key.length !== 65 || !proof) throw new WrongControlPlane();
  const proved = await crypto.subtle.verify("HMAC", shared, proof as BufferSource, newKeyMessage(key) as BufferSource);
  if (!proved) throw new WrongControlPlane();
  return base64url(key);
}

function nonce(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(32));
}

/**
 * Pairs with `code`: proves the code, makes this browser's key with `makeKey`, announces it,
 * and returns what the control plane admitted. The socket is spent afterwards; the control
 * plane closes it, and the browser connects again with its own key.
 */
export async function pair(socket: LineSocket, code: ClientCode, origin: string, name: string,
                           makeKey: () => Promise<{ client: string; publicRaw: Uint8Array }>,
                           peerNonce: Uint8Array = nonce(),
                           kind = "browser"): Promise<Admitted & { client: string }> {
  const hello = await readHello(socket);
  const theirs = fromBase64url(hello.control);
  // Nothing is sent to a control plane that isn't the code's (spec edge case).
  if (!theirs || !same(theirs, code.controlKey)) throw new WrongControlPlane();
  await prove(socket, hello, codeIdentity(code), await codeKey(code.secret), origin, peerNonce, kind);
  const made = await makeKey();
  socket.send(JSON.stringify({
    jsonrpc: "2.0", id: 1, method: "clients/announce",
    params: { id: made.client, publicKey: base64(made.publicRaw), name, kind },
  }));
  const reply = parse(await socket.next(15_000));
  if (reply["error"]) {
    const error = reply["error"] as { message?: string };
    throw new AnnounceRefused(error.message ?? "The control plane wouldn't pair this browser.");
  }
  return { name: hello.name, client: made.client };
}

/** Connects as the client `record` names: the page always as a browser; a walk tool may say otherwise. */
export async function connect(socket: LineSocket, record: KeyRecord, origin: string,
                              peerNonce: Uint8Array = nonce(), kind = "browser"): Promise<Admitted> {
  const hello = await readHello(socket);
  // The key it trusts, or the one before a rotation (#997), which it then proves itself with.
  if (hello.control !== record.control && hello.previous !== record.control) throw new WrongControlPlane();
  const control = fromBase64url(record.control);
  if (!control) throw new WrongControlPlane();
  const key = await clientKey(record.privateKey, control, record.client);
  const offer = await prove(socket, hello, "c:" + record.client, key, origin, peerNonce, kind);
  if (!offer) return { name: hello.name };
  return { name: hello.name, newKey: await checkedNewKey(offer, key) };
}

/** A sign-in connection that proved its key: the control plane's name and key, from its hello. */
export interface SignedIn {
  name: string;
  /** The hello's control key, base64url: trusted (TLS), and kept once the browser is paired. */
  control: string;
}

/**
 * Opens a sign-in connection as `s:<client>` (#995, #1002 FR-027): proves the browser's new key,
 * bound to the client id as a paired client's is, and says its public half. The hello's control
 * key is trusted: the page came from this control plane over TLS.
 */
export async function signInConnect(socket: LineSocket, client: string, privateKey: CryptoKey, publicRaw: Uint8Array,
                                    origin: string, peerNonce: Uint8Array = nonce(), kind = "browser"): Promise<SignedIn> {
  const hello = await readHello(socket);
  const control = fromBase64url(hello.control);
  if (!control || control.length !== 65) throw new Refused("bad-message");
  const key = await clientKey(privateKey, control, client);
  await prove(socket, hello, "s:" + client, key, origin, peerNonce, kind, publicRaw);
  return { name: hello.name, control: hello.control };
}
