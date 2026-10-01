// The key exchange from the browser (071 contracts/browser-auth.md; 058 contracts/wire.md):
// hello, auth, ok. Nothing but this is sent until the control plane has proved its key.
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
  | "unknown" | "forgotten" | "expired" | "spent" | "bad-proof" | "wrong-control-plane" | "bad-message";

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
}

export interface Admitted {
  grant: "operator" | "device";
  /** The control plane's name, from its hello. */
  name: string;
}

function parse(line: string): Record<string, unknown> {
  const value: unknown = JSON.parse(line);
  if (typeof value !== "object" || value === null) throw new Refused("bad-message");
  return value as Record<string, unknown>;
}

async function readHello(socket: LineSocket): Promise<Hello> {
  const hello = parse(await socket.next(15_000))["hello"] as Partial<Hello> | undefined;
  if (!hello || typeof hello.control !== "string" || typeof hello.nonce !== "string") throw new Refused("bad-message");
  return { name: String(hello.name ?? ""), control: hello.control, nonce: hello.nonce };
}

function transcript(serverNonce: Uint8Array, peerNonce: Uint8Array, identity: string, origin: string): Uint8Array {
  return concat(utf8("agents-auth-v1"), serverNonce, peerNonce, utf8(identity), utf8(origin));
}

/** Proves `key` as `identity`, and checks the control plane proves it back. */
async function prove(socket: LineSocket, hello: Hello, identity: string, key: CryptoKey, origin: string,
                     peerNonce: Uint8Array, kind: string): Promise<"operator" | "device"> {
  const serverNonce = fromBase64url(hello.nonce);
  if (!serverNonce) throw new Refused("bad-message");
  const said = transcript(serverNonce, peerNonce, identity, origin);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, concat(utf8("c"), said) as BufferSource));
  socket.send(JSON.stringify({ auth: { id: identity, nonce: base64url(peerNonce), mac: base64url(mac), kind } }));
  const answer = parse(await socket.next(15_000));
  const refused = answer["refused"] as { reason?: RefusalReason } | undefined;
  if (refused) throw new Refused(refused.reason ?? "unknown");
  const ok = answer["ok"] as { mac?: string; grant?: string } | undefined;
  const theirs = ok?.mac ? fromBase64url(ok.mac) : null;
  if (!ok || !theirs) throw new Refused("bad-message");
  const proved = await crypto.subtle.verify("HMAC", key, theirs as BufferSource, concat(utf8("s"), said) as BufferSource);
  if (!proved) throw new BadServerProof();
  return ok.grant === "operator" ? "operator" : "device";
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
  const grant = await prove(socket, hello, codeIdentity(code), await codeKey(code.secret), origin, peerNonce, kind);
  const made = await makeKey();
  socket.send(JSON.stringify({
    jsonrpc: "2.0", id: 1, method: "clients/announce",
    params: { id: made.client, publicKey: base64(made.publicRaw), name, kind },
  }));
  const reply = parse(await socket.next(15_000));
  if (reply["error"]) {
    const error = reply["error"] as { message?: string };
    throw new Error(error.message ?? "the control plane wouldn't pair this browser");
  }
  const result = reply["result"] as { grant?: string } | undefined;
  return { grant: result?.grant === "operator" ? "operator" : grant, name: hello.name, client: made.client };
}

/** Connects as the client `record` names: the page always as a browser; a walk tool may say otherwise. */
export async function connect(socket: LineSocket, record: KeyRecord, origin: string,
                              peerNonce: Uint8Array = nonce(), kind = "browser"): Promise<Admitted> {
  const hello = await readHello(socket);
  if (hello.control !== record.control) throw new WrongControlPlane();
  const control = fromBase64url(record.control);
  if (!control) throw new WrongControlPlane();
  const key = await clientKey(record.privateKey, control, record.client);
  const grant = await prove(socket, hello, "c:" + record.client, key, origin, peerNonce, kind);
  return { grant, name: hello.name };
}
