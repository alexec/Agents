// The browser's key (071 research R4, data-model.md "Browser key"): a P-256 pair made with
// WebCrypto, the private half non-extractable, kept in IndexedDB and nowhere else (FR-009).
import { utf8 } from "./bytes";

export interface KeyRecord {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
  /** Upper case, as Swift's uuidString writes it: the `c:` identity and HKDF's info use it. */
  client: string;
  /** The control plane's key from the code, base64url; every hello must show the same. */
  control: string;
  paired: string;
}

/** Where the record lives. IndexedDB in the page; memory in the tests. */
export interface KeyStore {
  load(): Promise<KeyRecord | null>;
  save(record: KeyRecord): Promise<void>;
  forget(): Promise<void>;
  /** The machine lock's signing key (#3490): ECDSA P-256, the private half non-extractable. */
  loadLockKey(): Promise<CryptoKeyPair | null>;
  saveLockKey(pair: CryptoKeyPair): Promise<void>;
}

export class UnsupportedBrowser extends Error {
  constructor() {
    super("This browser can't keep a key that can't be copied out of it.");
  }
}

const curve = { name: "ECDH", namedCurve: "P-256" } as const;

/** A new pair, the private half non-extractable, and its public half as 65 raw bytes. */
export async function makeKeyPair(): Promise<{ pair: CryptoKeyPair; publicRaw: Uint8Array }> {
  const pair = (await crypto.subtle.generateKey(curve, false, ["deriveBits"])) as CryptoKeyPair;
  if (pair.privateKey.extractable) throw new UnsupportedBrowser();
  const publicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { pair, publicRaw };
}

/** A new client id, in the case the control plane writes it. */
export function newClientID(): string {
  return crypto.randomUUID().toUpperCase();
}

async function hmacFromHKDF(ikm: ArrayBuffer | Uint8Array, salt: string, info: Uint8Array): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey("raw", ikm as BufferSource, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: utf8(salt) as BufferSource, info: info as BufferSource },
    base,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    ["sign", "verify"],
  );
}

/** HKDF(ECDH(browser, control), "agents-control-client-v1", uuid): the key every proof uses. */
export async function clientKey(privateKey: CryptoKey, controlRaw: Uint8Array, client: string): Promise<CryptoKey> {
  const control = await crypto.subtle.importKey("raw", controlRaw as BufferSource, curve, false, []);
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: control }, privateKey, 256);
  return hmacFromHKDF(shared, "agents-control-client-v1", utf8(client));
}

/** HKDF(secret, "agents-control-code-v1", ""): the key a code holder proves. */
export function codeKey(secret: Uint8Array): Promise<CryptoKey> {
  return hmacFromHKDF(secret, "agents-control-code-v1", new Uint8Array());
}

/**
 * The record in IndexedDB: database `agents`, store `key`, key `self`. The machine lock's
 * signing key is in the same store, key `lockSigning`, so a forget drops it too.
 */
export class IndexedKeyStore implements KeyStore {
  private open(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open("agents", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("key");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  private async run<T>(mode: IDBTransactionMode, act: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await this.open();
    try {
      return await new Promise<T>((resolve, reject) => {
        const tx = db.transaction("key", mode);
        const request = act(tx.objectStore("key"));
        tx.oncomplete = () => resolve(request.result);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      });
    } finally {
      db.close();
    }
  }

  async load(): Promise<KeyRecord | null> {
    const record = (await this.run("readonly", (store) => store.get("self"))) as KeyRecord | undefined;
    if (!record) return null;
    // A key that could be copied out is not one this page keeps (spec edge case).
    if (!(record.privateKey instanceof CryptoKey) || record.privateKey.extractable) {
      await this.forget();
      throw new UnsupportedBrowser();
    }
    return record;
  }

  async save(record: KeyRecord): Promise<void> {
    // Asked, not waited for: Firefox asks the person, and a pairing that waited for the
    // answer would outlast the control plane's wait for the key (#3418).
    void navigator.storage?.persist?.().catch(() => false);
    await this.run("readwrite", (store) => store.put(record, "self"));
    const back = await this.load();
    if (!back || back.client !== record.client) throw new UnsupportedBrowser();
  }

  async loadLockKey(): Promise<CryptoKeyPair | null> {
    const pair = (await this.run("readonly", (store) => store.get("lockSigning"))) as CryptoKeyPair | undefined;
    if (!pair || !(pair.privateKey instanceof CryptoKey) || pair.privateKey.extractable) return null;
    return pair;
  }

  async saveLockKey(pair: CryptoKeyPair): Promise<void> {
    await navigator.storage?.persist?.().catch(() => false);
    await this.run("readwrite", (store) => store.put(pair, "lockSigning"));
  }

  async forget(): Promise<void> {
    await new Promise<void>((resolve) => {
      const request = indexedDB.deleteDatabase("agents");
      request.onsuccess = request.onerror = request.onblocked = () => resolve();
    });
  }
}

/** For the tests: the same contract, in memory. */
export class MemoryKeyStore implements KeyStore {
  record: KeyRecord | null = null;
  lockKey: CryptoKeyPair | null = null;
  async loadLockKey(): Promise<CryptoKeyPair | null> {
    return this.lockKey;
  }
  async saveLockKey(pair: CryptoKeyPair): Promise<void> {
    this.lockKey = pair;
  }
  async load(): Promise<KeyRecord | null> {
    return this.record;
  }
  async save(record: KeyRecord): Promise<void> {
    this.record = record;
  }
  async forget(): Promise<void> {
    this.record = null;
    this.lockKey = null;
  }
}
