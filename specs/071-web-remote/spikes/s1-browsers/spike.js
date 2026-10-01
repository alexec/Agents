// 071 S1: does this browser give the web remote what it needs? (research R1)
//
// 1. a secure context at http://localhost;
// 2. a non-extractable P-256 key, with a 65-byte raw public key;
// 3. that key kept in IndexedDB across a full quit of the browser;
// 4. ECDH → HKDF → HMAC giving the bytes ControlAgreement gives (Web/test/vectors.json);
// 5. what navigator.storage says about keeping it.
//
// The result goes in #out as JSON, and the title becomes "done" or "failed".

const DB = "agents-spike-s1";
const enc = new TextEncoder();

const hex = (buffer) => [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
const unhex = (text) => new Uint8Array(text.match(/../g).map((h) => parseInt(h, 16)));
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore("key");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function op(db, mode, act) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction("key", mode);
    const request = act(tx.objectStore("key"));
    tx.oncomplete = () => resolve(request.result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
  });
}

async function storage() {
  const s = navigator.storage;
  if (!s) return { present: false };
  const before = s.persisted ? await s.persisted() : null;
  const asked = s.persist ? await s.persist() : null;
  const after = s.persisted ? await s.persisted() : null;
  const estimate = s.estimate ? await s.estimate() : null;
  return { present: true, persistedBefore: before, persistGranted: asked, persistedAfter: after,
           quota: estimate?.quota ?? null };
}

// The key a paired browser keeps: made once, then read back on every later run.
async function keptKey(controlPublic) {
  const db = await openDB();
  let record = await op(db, "readonly", (store) => store.get("self"));
  const existed = !!record;
  if (!record) {
    const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
    const probe = await crypto.subtle.deriveBits({ name: "ECDH", public: controlPublic }, pair.privateKey, 256);
    record = { privateKey: pair.privateKey, publicKey: pair.publicKey,
               publicRaw: hex(await crypto.subtle.exportKey("raw", pair.publicKey)),
               probe: hex(probe), made: new Date().toISOString() };
    await op(db, "readwrite", (store) => store.put(record, "self"));
    record = await op(db, "readonly", (store) => store.get("self"));
  }
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", record.publicKey));
  let privateExportRefused = false;
  try { await crypto.subtle.exportKey("pkcs8", record.privateKey); } catch { privateExportRefused = true; }
  let jwkExportRefused = false;
  try { await crypto.subtle.exportKey("jwk", record.privateKey); } catch { jwkExportRefused = true; }
  const probe = hex(await crypto.subtle.deriveBits({ name: "ECDH", public: controlPublic }, record.privateKey, 256));
  db.close();
  return {
    existedBefore: existed,
    made: record.made,
    ageHours: Math.round((Date.now() - Date.parse(record.made)) / 36e5 * 10) / 10,
    privateIsCryptoKey: record.privateKey instanceof CryptoKey,
    extractable: record.privateKey.extractable,
    privateExportRefused, jwkExportRefused,
    publicRawLength: raw.length,
    publicRawFirstByte: raw[0],
    publicUnchanged: hex(raw) === record.publicRaw,
    deriveUnchanged: probe === record.probe,
  };
}

// The MAC a peer and a server send, as ControlAuth.peerMAC / serverMAC make them.
async function macs(key, v, identity) {
  const transcript = concat(enc.encode("agents-auth-v1"), unhex(v.serverNonce), unhex(v.peerNonce),
                            enc.encode(identity), enc.encode(v.origin));
  const peer = await crypto.subtle.sign("HMAC", key, concat(enc.encode("c"), transcript));
  return { peer: hex(peer), transcript };
}

async function hmacFromHKDF(ikm, salt, info) {
  const base = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: enc.encode(salt), info },
                                 base, { name: "HMAC", hash: "SHA-256", length: 256 }, false, ["sign", "verify"]);
}

async function vectorsMatch(v, controlPublic) {
  const clientPrivate = await crypto.subtle.importKey("jwk", v.client.jwk, { name: "ECDH", namedCurve: "P-256" },
                                                      false, ["deriveBits"]);
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: controlPublic }, clientPrivate, 256);
  // The control plane's info is the UUID as Swift's uuidString writes it: upper case.
  const clientKey = await hmacFromHKDF(shared, v.client.salt, enc.encode(v.client.id));
  const client = await macs(clientKey, v, v.client.identity);
  const clientServer = await crypto.subtle.verify("HMAC", clientKey, unhex(v.client.mac.server),
                                                  concat(enc.encode("s"), client.transcript));
  const lowerKey = await hmacFromHKDF(shared, v.client.salt, enc.encode(v.client.id.toLowerCase()));
  const lower = await macs(lowerKey, v, v.client.identity);

  const codeKey = await hmacFromHKDF(unhex(v.code.secret), v.code.salt, new Uint8Array());
  const code = await macs(codeKey, v, v.code.identity);
  const codeServer = await crypto.subtle.verify("HMAC", codeKey, unhex(v.code.mac.server),
                                                concat(enc.encode("s"), code.transcript));
  return {
    sharedX: hex(shared) === v.client.sharedX,
    clientPeerMAC: client.peer === v.client.mac.peer,
    clientServerMACVerifies: clientServer,
    lowerCaseUUIDWouldMatch: lower.peer === v.client.mac.peer,
    codePeerMAC: code.peer === v.code.mac.peer,
    codeServerMACVerifies: codeServer,
  };
}

async function run() {
  const out = document.getElementById("out");
  const result = { origin: location.origin, userAgent: navigator.userAgent, at: new Date().toISOString() };
  try {
    result.secureContext = window.isSecureContext;
    result.subtle = !!(window.crypto && crypto.subtle);
    const v = await (await fetch("/vectors.json")).json();
    const controlPublic = await crypto.subtle.importKey("raw", unhex(v.control.public),
                                                        { name: "ECDH", namedCurve: "P-256" }, true, []);
    result.storage = await storage();
    result.key = await keptKey(controlPublic);
    result.vectors = await vectorsMatch(v, controlPublic);
    const k = result.key, m = result.vectors;
    result.pass = result.secureContext && result.subtle && k.privateIsCryptoKey && k.extractable === false
      && k.privateExportRefused && k.jwkExportRefused && k.publicRawLength === 65 && k.publicRawFirstByte === 4
      && k.publicUnchanged && k.deriveUnchanged
      && m.sharedX && m.clientPeerMAC && m.clientServerMACVerifies && m.codePeerMAC && m.codeServerMACVerifies;
    document.title = "done";
  } catch (error) {
    result.error = String(error && error.stack || error);
    result.pass = false;
    document.title = "failed";
  }
  out.textContent = JSON.stringify(result, null, 2);
  window.spikeResult = result;
}

async function forget() {
  await new Promise((resolve) => {
    const request = indexedDB.deleteDatabase(DB);
    request.onsuccess = request.onerror = request.onblocked = () => resolve();
  });
  document.getElementById("out").textContent = "Forgotten. Run again to make a new key.";
}

document.getElementById("run").addEventListener("click", run);
document.getElementById("forget").addEventListener("click", forget);
run();
