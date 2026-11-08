// Client sealing (#3397, specs/3397-client-sealing): the page seals an org route's secrets, and
// a person's own secrets, with HPKE straight to each machine (and each client) that may hold
// them. The control plane keeps and sends the envelopes and never opens one. The associated data
// is Go's controllink.OrgRouteAD and UserSecretAD, byte for byte; AgentsKit's Sealing.swift is
// the same. HPKE is @hpke/core over WebCrypto: DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM.
import { Aes256Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";
import type { Base64, OrgRouteKind, OrgRouteSettings, OrgRouteVendor, SealedEnvelope, SealingAddItem, SealingItem, SealRecipient,
  SealingWork } from "../protocol/generated";
import { base64, hex, utf8 } from "./bytes";
import type { KeyRecord } from "./keys";

export const orgRoutePurpose = "com.alexecollins.agents.orgroute.v3";
export const userSecretPurpose = "com.alexecollins.agents.usersecret.v1";

const suite = new CipherSuite({ kem: new DhkemP256HkdfSha256(), kdf: new HkdfSha256(), aead: new Aes256Gcm() });

/** A client as a recipient: its id in upper case. */
export function clientRecipient(client: string): string {
  return `c:${client.toUpperCase()}`;
}

/** The settings that bind a route's secrets, one name=value line each, in this order. */
const settingOrder: (keyof OrgRouteSettings)[] = ["address", "apiVersion", "clientID", "header", "location", "project", "region",
  "resource", "tenant"];

async function sha256Hex(text: string): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(text) as BufferSource)));
}

/** The hex SHA-256 of a route's settings: where its key goes. */
export function orgRouteBinding(settings: OrgRouteSettings | undefined): Promise<string> {
  const lines = settingOrder.filter((name) => settings?.[name] !== undefined).map((name) => `${name}=${settings![name]}\n`).join("");
  return sha256Hex(lines);
}

/** Where a route's key goes, as its associated data binds it. */
export interface RouteBinding {
  id: string;
  kind: OrgRouteKind;
  vendor?: OrgRouteVendor | undefined;
  settings?: OrgRouteSettings | undefined;
}

export async function orgRouteAD(route: RouteBinding, recipient: string, field: string, sealVersion: number): Promise<Uint8Array> {
  const binding = await orgRouteBinding(route.settings);
  return utf8(`orgroute.v3|${route.id}|${recipient}|${field}|${sealVersion}|${route.kind}|${route.vendor ?? ""}|${binding}`);
}

/** Ask before use (#4014) adds "|ask", as Go's UserSecretADAsk, so a flag the control plane changed does not open. */
export function userSecretAD(user: string, recipient: string, name: string, version: number, ask = false): Uint8Array {
  return utf8(`usersecret.v1|${user}|${recipient}|${name}|${version}${ask ? "|ask" : ""}`);
}

function fromBase64(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

/** HPKE to a recipient's P-256 key (X9.63, 65 bytes), under info, with ad. */
export async function seal(publicKey: Base64 | Uint8Array, info: string, ad: Uint8Array, value: Uint8Array): Promise<SealedEnvelope> {
  const raw = typeof publicKey === "string" ? fromBase64(publicKey) : publicKey;
  const recipientPublicKey = await suite.kem.deserializePublicKey(raw.slice().buffer);
  const sender = await suite.createSenderContext({ recipientPublicKey, info: utf8(info).slice().buffer });
  const ciphertext = await sender.seal(value.slice().buffer, ad.slice().buffer);
  return { encapsulated: base64(new Uint8Array(sender.enc)) as Base64, ciphertext: base64(new Uint8Array(ciphertext)) as Base64 };
}

/** Opens what was sealed to this page, with its own key, which never leaves the browser. */
export async function open(record: KeyRecord, info: string, ad: Uint8Array, sealed: SealedEnvelope): Promise<Uint8Array> {
  const recipient = await suite.createRecipientContext({
    recipientKey: { privateKey: record.privateKey, publicKey: record.publicKey },
    enc: fromBase64(sealed.encapsulated).slice().buffer,
    info: utf8(info).slice().buffer,
  });
  return new Uint8Array(await recipient.open(fromBase64(sealed.ciphertext).slice().buffer, ad.slice().buffer));
}

/** The first 8 hex of a value's SHA-256, so two admins can compare a key (spec D14). */
export async function fingerprint(value: string): Promise<string> {
  return (await sha256Hex(value)).slice(0, 8);
}

/** Each value of a route sealed to each recipient, by recipient, then by field. */
export async function sealRoute(route: RouteBinding, values: Record<string, string>, sealVersion: number,
  recipients: SealRecipient[]): Promise<{ [recipient: string]: { [field: string]: SealedEnvelope } }> {
  const out: { [recipient: string]: { [field: string]: SealedEnvelope } } = {};
  for (const r of recipients) {
    out[r.id] = {};
    for (const [field, value] of Object.entries(values)) {
      out[r.id]![field] = await seal(r.publicKey, orgRoutePurpose, await orgRouteAD(route, r.id, field, sealVersion), utf8(value));
    }
  }
  return out;
}

/** A person's secret sealed to each recipient. */
export async function sealSecret(user: string, name: string, version: number, value: string,
  recipients: SealRecipient[], ask = false): Promise<{ [recipient: string]: SealedEnvelope }> {
  const out: { [recipient: string]: SealedEnvelope } = {};
  for (const r of recipients) out[r.id] = await seal(r.publicKey, userSecretPurpose, userSecretAD(user, r.id, name, version, ask), utf8(value));
  return out;
}

/** This page's copy of an item's values, opened: by field. */
export async function openItem(record: KeyRecord, item: SealingItem): Promise<Record<string, string>> {
  const me = clientRecipient(record.client);
  const out: Record<string, string> = {};
  for (const [field, sealed] of Object.entries(item.mine)) {
    const plain = item.item === "userSecret"
      ? await open(record, userSecretPurpose, userSecretAD(item.user ?? "", me, item.id, item.version, item.needsApproval === true), sealed)
      : await open(record, orgRoutePurpose, await orgRouteAD({ id: item.id, kind: item.kind!, vendor: item.vendor, settings: item.settings },
        me, field, item.version), sealed);
    out[field] = new TextDecoder().decode(plain);
  }
  return out;
}

/** What sealing/work asks, sealed for each recipient missing; an item whose copy does not open here is left out. */
export async function sealWork(record: KeyRecord, work: SealingWork): Promise<SealingAddItem[]> {
  const out: SealingAddItem[] = [];
  for (const item of work.items) {
    let values: Record<string, string>;
    try {
      values = await openItem(record, item);
    } catch {
      continue;
    }
    const sealed = item.item === "userSecret"
      ? Object.fromEntries(Object.entries(await sealSecret(item.user ?? "", item.id, item.version, values["value"] ?? "", item.missing,
        item.needsApproval === true))
        .map(([recipient, e]) => [recipient, { value: e }]))
      : await sealRoute({ id: item.id, kind: item.kind!, vendor: item.vendor, settings: item.settings }, values, item.version, item.missing);
    out.push({ item: item.item, id: item.id, version: item.version, values: sealed });
  }
  return out;
}
