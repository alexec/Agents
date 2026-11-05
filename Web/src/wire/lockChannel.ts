// Requests checked end to end (#3492, specs/3399-machine-lock D6): the page's side of a
// checked channel to a machine, as Go's machinelock/channel.go makes it. The page sends a new
// ECDH key signed with its lock key (lock/hello); the machine answers with one of its own,
// signed with its machine key, which the page's lock must name as an addMachine. HKDF-SHA256
// makes a key for each direction, and every request and answer then ends with
// "lock":{"n":…,"mac":…}: HMAC-SHA256 over the count and the message without that member.
//
// A prompt or a start for a machine that is not there goes signed instead (LockSignature), so
// the control plane can keep it and the machine still takes it when it connects.
import type { LockHello, LockHelloReply, LockSignature } from "../protocol/generated";
import { base64, concat, utf8 } from "./bytes";
import { fromBase64, type LockState } from "./machineLock";

const channelDomain = "agents-lock-channel/1\n";
const requestDomain = "agents-lock-request/1\n";

/** The member a MAC'd message ends with: the count, and 32 bytes of standard base64. */
const tail = /,"lock":\{"n":([0-9]{1,19}),"mac":"([A-Za-z0-9+/]{43}=)"\}\}$/;

/** Whether a message ends with a MAC, whether or not it checks. */
export function sealed(message: string): boolean {
  return tail.test(message);
}

async function verify(publicRaw: Uint8Array, data: Uint8Array, sig: Uint8Array): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey("raw", publicRaw as BufferSource, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig as BufferSource, data as BufferSource);
  } catch {
    return false;
  }
}

async function signData(privateKey: CryptoKey, data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, data as BufferSource));
}

export const clientHelloData = (ephemeral: Uint8Array) => concat(utf8(channelDomain + "client\n"), ephemeral);
export const machineHelloData = (clientEphemeral: Uint8Array, machineEphemeral: Uint8Array, clientKey: Uint8Array) =>
  concat(utf8(channelDomain + "machine\n"), clientEphemeral, machineEphemeral, clientKey);

/** The two keys, from the ECDH secret and both ephemeral keys: what the client sends with, then the machine. */
export async function channelKeys(shared: Uint8Array, clientEphemeral: Uint8Array, machineEphemeral: Uint8Array): Promise<[Uint8Array, Uint8Array]> {
  const ikm = await crypto.subtle.importKey("raw", shared as BufferSource, "HKDF", false, ["deriveBits"]);
  const salt = concat(clientEphemeral, machineEphemeral);
  const derive = async (info: string) =>
    new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: salt as BufferSource, info: utf8(info) as BufferSource }, ikm, 256));
  return [await derive("agents-lock-channel/1 client"), await derive("agents-lock-channel/1 machine")];
}

async function macOf(key: CryptoKey, n: number, body: string): Promise<Uint8Array> {
  const count = new Uint8Array(8);
  new DataView(count.buffer).setBigUint64(0, BigInt(n));
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, concat(count, utf8(body)) as BufferSource));
}

const hmacKey = (raw: Uint8Array, use: KeyUsage) =>
  crypto.subtle.importKey("raw", raw as BufferSource, { name: "HMAC", hash: "SHA-256" }, false, [use]);

export class ChannelError extends Error {}

/** One side of a checked channel: the page's, or (in the tests) the machine's. */
export class Channel {
  private sent = 0;
  private heard = 0;

  private constructor(private readonly send: CryptoKey, private readonly hear: CryptoKey) {}

  static async of(send: Uint8Array, hear: Uint8Array, sent = 0, heard = 0): Promise<Channel> {
    const c = new Channel(await hmacKey(send, "sign"), await hmacKey(hear, "sign"));
    c.sent = sent;
    c.heard = heard;
    return c;
  }

  /** The message with the next count and its MAC as its last member. The count is taken at once, so seal in the order the lines go out. */
  async seal(message: string): Promise<string> {
    const n = ++this.sent;
    const mac = await macOf(this.send, n, message);
    return `${message.slice(0, -1)},"lock":{"n":${n},"mac":"${base64(mac)}"}}`;
  }

  /** The message without its "lock" member, once its MAC and count check. Open in the order the lines came. */
  async open(message: string): Promise<string> {
    const match = tail.exec(message);
    if (!match) throw new ChannelError("The machine's answer is not signed.");
    const n = Number(match[1]);
    const body = message.slice(0, match.index) + "}";
    const want = await macOf(this.hear, n, body);
    if (base64(want) !== match[2]) throw new ChannelError("The machine's answer does not check.");
    if (n <= this.heard) throw new ChannelError("The machine's answer was sent before.");
    this.heard = n;
    return body;
  }
}

/** A page's lock key: the private half to sign with, and the public half as the lock names it. */
export interface LockSigner {
  privateKey: CryptoKey;
  publicRaw: Uint8Array;
}

/** The page's lock/hello, and the ephemeral key it keeps for finish. */
export interface Hello {
  params: LockHello;
  ephemeral: CryptoKeyPair;
  ephemeralRaw: Uint8Array;
}

export async function newHello(signer: LockSigner): Promise<Hello> {
  const ephemeral = (await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"])) as CryptoKeyPair;
  const ephemeralRaw = new Uint8Array(await crypto.subtle.exportKey("raw", ephemeral.publicKey));
  const sig = await signData(signer.privateKey, clientHelloData(ephemeralRaw));
  return { params: { key: base64(signer.publicRaw), ephemeral: base64(ephemeralRaw), sig: base64(sig) } as LockHello, ephemeral, ephemeralRaw };
}

/** Whether the lock names the machine host with an addMachine. */
export function names(state: LockState, host: string): boolean {
  return host !== "" && state.membersOf("addMachine").some((m) => m.id === host);
}

/**
 * Checks the machine's answer against the page's lock and makes the page's side of the
 * channel. host is the machine's id; "" is any machine. A machine the lock names must answer
 * with the key its addMachine names; one it does not name yet (it waits for approval) is
 * taken on its word, as before the lock, and the requests to it are still the page's alone.
 */
export async function finish(hello: Hello, state: LockState, host: string, reply: LockHelloReply): Promise<Channel> {
  const key = fromBase64(reply.key);
  const member = state.member(key);
  if (member ? member.kind !== "addMachine" || (host && member.id && member.id !== host) : names(state, host)) {
    throw new ChannelError("The machine's key is not the one your lock names.");
  }
  const machineEphemeral = fromBase64(reply.ephemeral);
  if (!(await verify(key, machineHelloData(hello.ephemeralRaw, machineEphemeral, fromBase64(hello.params.key)), fromBase64(reply.sig)))) {
    throw new ChannelError("The machine's answer is not signed by its key.");
  }
  const peer = await crypto.subtle.importKey("raw", machineEphemeral as BufferSource, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: peer }, hello.ephemeral.privateKey, 256));
  const [client, machine] = await channelKeys(shared, hello.ephemeralRaw, machineEphemeral);
  return Channel.of(client, machine);
}

export const requestData = (to: string, at: number, method: string, params: string) =>
  utf8(`${requestDomain}${to}\n${at}\n${method}\n${params}`);

/** A request signed for the machine to, with the params as they are sent. */
export async function signRequest(signer: LockSigner, to: string, method: string, params: string, at = Math.floor(Date.now() / 1000)): Promise<LockSignature> {
  const sig = await signData(signer.privateKey, requestData(to, at, method, params));
  return { to, at, key: base64(signer.publicRaw), sig: base64(sig) } as LockSignature;
}

/** Whether a signature checks: for the tests, against Go's. */
export function verifyRequest(signature: LockSignature, method: string, params: string): Promise<boolean> {
  return verify(fromBase64(signature.key), requestData(signature.to ?? "", signature.at, method, params), fromBase64(signature.sig));
}

export function verifyHello(publicRaw: Uint8Array, data: Uint8Array, sig: Uint8Array): Promise<boolean> {
  return verify(publicRaw, data, sig);
}
