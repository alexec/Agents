// The page's sign-in connection (#995, #1002 slice 3, FR-026, FR-027): `s:<client>` with a new
// key, which answers signIn/providers, signIn/discover, signIn/ask, signIn/orgStart and signIn/ticket
// and nothing else. Its lines are bare JSON-RPC, not the `{"m"}` frames of a paired client.
// The org flow leaves the page: the key it started with waits in IndexedDB as a pending sign-in,
// apart from the paired key's record, until the provider sends the browser back or 10 minutes pass.
import { signInConnect, type LineSocket, type SignedIn } from "./auth";
import { fromBase64url } from "./bytes";
import { CallFailed, LinkDown } from "./link";

/** A sign-in started and not yet finished: the key and the client id the ticket is bound to. */
export interface PendingSignIn {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
  /** Upper case, as the `s:` identity says it. */
  client: string;
  /** When it was made, in ms: it is good for 10 minutes. */
  made: number;
}

/** Where the pending sign-in waits. IndexedDB in the page; memory in the tests. */
export interface PendingStore {
  load(): Promise<PendingSignIn | null>;
  save(pending: PendingSignIn): Promise<void>;
  drop(): Promise<void>;
}

/** Database `agents-signin`, store `pending`, key `self`: not the paired key's, which a forget deletes whole. */
export class IndexedPendingStore implements PendingStore {
  private open(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open("agents-signin", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("pending");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  private async run<T>(mode: IDBTransactionMode, act: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await this.open();
    try {
      return await new Promise<T>((resolve, reject) => {
        const tx = db.transaction("pending", mode);
        const request = act(tx.objectStore("pending"));
        tx.oncomplete = () => resolve(request.result);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      });
    } finally {
      db.close();
    }
  }

  async load(): Promise<PendingSignIn | null> {
    const pending = (await this.run("readonly", (store) => store.get("self"))) as PendingSignIn | undefined;
    if (!pending || !(pending.privateKey instanceof CryptoKey) || pending.privateKey.extractable) return null;
    return pending;
  }

  async save(pending: PendingSignIn): Promise<void> {
    await this.run("readwrite", (store) => store.put(pending, "self"));
  }

  async drop(): Promise<void> {
    await this.run("readwrite", (store) => store.delete("self")).catch(() => undefined);
  }
}

/** For the tests: the same contract, in memory. */
export class MemoryPendingStore implements PendingStore {
  pending: PendingSignIn | null = null;
  async load(): Promise<PendingSignIn | null> {
    return this.pending;
  }
  async save(pending: PendingSignIn): Promise<void> {
    this.pending = pending;
  }
  async drop(): Promise<void> {
    this.pending = null;
  }
}

/** One sign-in connection that proved its key: ask it, then close it. */
export class SignInConnection {
  private nextID = 1;

  constructor(private readonly lines: LineSocket, readonly signedIn: SignedIn) {}

  /**
   * Asks `method` and waits for its answer; a failure is a CallFailed with the wire's code and data.
   * `note` hears the notifications on the way (control/signInWaiting, for signIn/ask: #2097).
   */
  async call<T>(method: string, params: unknown, timeoutMs = 15_000,
                note?: (method: string, params: unknown) => void): Promise<T> {
    const id = this.nextID++;
    this.lines.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    for (;;) {
      let message: { id?: number | null; method?: string; params?: unknown; result?: unknown;
        error?: { code: number; message: string; data?: unknown } };
      try {
        message = JSON.parse(await this.lines.next(timeoutMs));
      } catch (error) {
        if (error instanceof SyntaxError) continue;
        throw error instanceof LinkDown ? error : new LinkDown();
      }
      if (message.id === undefined && message.method) {
        note?.(message.method, message.params);
        continue;
      }
      if (message.id !== id) continue;
      if (message.error) throw new CallFailed(message.error.code, message.error.message, message.error.data);
      return message.result as T;
    }
  }

  close(): void {
    this.lines.close(1000, "");
  }
}

/** Opens `s:<client>` on `lines` and proves the key. */
export async function openSignIn(lines: LineSocket, client: string, privateKey: CryptoKey, publicKey: CryptoKey,
                                 origin: string): Promise<SignInConnection> {
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", publicKey));
  const signedIn = await signInConnect(lines, client, privateKey, publicRaw, origin);
  return new SignInConnection(lines, signedIn);
}

const approvalLetters = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

/**
 * The code a sign-in that waits for approval shows, made here as the control plane makes it:
 * SHA-256("agents-signin-approve" ‖ the new key's public half ‖ the control key), two bytes a letter.
 * Never the control plane's: one that passed the sign-in on could only pass on another key's code.
 */
export async function approvalCode(clientPublic: Uint8Array, controlKey: Uint8Array): Promise<string> {
  const message = new Uint8Array([...new TextEncoder().encode("agents-signin-approve"), ...clientPublic, ...controlKey]);
  const sum = new Uint8Array(await crypto.subtle.digest("SHA-256", message));
  let out = "";
  for (let i = 0; i < 6; i++) out += approvalLetters[(((sum[2 * i] ?? 0) << 8) | (sum[2 * i + 1] ?? 0)) % approvalLetters.length];
  return out;
}

/** The code `connection`, opened with `publicKey`, shows while it waits for approval. */
export async function connectionApprovalCode(connection: SignInConnection, publicKey: CryptoKey): Promise<string> {
  const control = fromBase64url(connection.signedIn.control);
  if (!control) throw new Error("no control key");
  return approvalCode(new Uint8Array(await crypto.subtle.exportKey("raw", publicKey)), control);
}
