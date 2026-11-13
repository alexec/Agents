// Reveal and Copy of a person's own secret (#5112, specs/5112-view-copy-secrets-accounts/wireframes.md), as the
// window's SecretRevealWords and ClientSealing.reveal: the page asks the control plane for its own sealed copy
// (user/sealedSecret, which writes the audit entry first), opens it with the browser's own key, shows or copies the
// value, and forgets it.
import type { OutsideAccount, UserSealedSecretAccount, UserSealedSecretPart, UserSealedSecretRequest, UserSecretRow }
  from "../protocol/generated";
import { CallFailed, type Link } from "../wire/link";
import { clientRecipient, open, userSecretAD, userSecretPurpose } from "../wire/sealing";
import { describe, methodNotFound } from "./errors";
import type { Card } from "./userScope";

/** A value shown hides again after this (section 2). */
export const shownSeconds = 30;
/** A copied secret is written over after this, when the tab is still in front (section 3). */
export const clipboardSeconds = 90;
/** How long Copy says "Copied" (section 3). */
export const copiedSeconds = 2;

export const revealWords = {
  shown: "Shown for 30 s. Your reveal is in the audit log.",
  copied: "Copied. The clipboard clears in 90 s.",
  copiedPlain: "Copied.",
  noCopy: "This app has no copy yet. It gets one when another app of yours is online.",
  didNotOpen: "This app's copy did not open. Replace the secret to seal it again.",
  notCard: "This secret is not a card.",
  noClipboard: "This browser did not let the page copy.",
};

/** user/sealedSecret's code when the control plane keeps no copy for this page yet. */
export const noClientCopy = -32108;

/** The copy did not open with this page's key (a changed key). */
export class RevealFailed extends Error {}

/** What went wrong, in one line for the row (section 6). */
export function revealFailure(error: unknown): string {
  if (error instanceof RevealFailed) return revealWords.didNotOpen;
  if (error instanceof CallFailed && error.code === noClientCopy) return revealWords.noCopy;
  if (error instanceof CallFailed && error.code === methodNotFound) return "The control plane needs an update to do this.";
  return describe(error);
}

/** What the reveal needs of the page: its link to the control plane and its key. */
export type Revealer = Pick<Link, "call" | "keyRecord">;

/** This page's own copy of one secret, opened here: in memory only. */
export async function revealSecret(link: Revealer, request: UserSealedSecretRequest): Promise<string> {
  const record = await link.keyRecord();
  if (!record) throw new RevealFailed();
  const { user } = await link.call("user/secretRecipients", {});
  const sealed = await link.call("user/sealedSecret", request);
  try {
    const ad = userSecretAD(user ?? "", clientRecipient(record.client), sealed.name, sealed.version, sealed.needsApproval === true);
    return new TextDecoder().decode(await open(record, userSecretPurpose, ad, sealed.sealed));
  } catch {
    throw new RevealFailed();
  }
}

/** The card a card secret's value holds, or null when it is not one. */
export function parseCard(value: string): Card | null {
  try {
    const c = JSON.parse(value) as Partial<Card>;
    return typeof c.number === "string" && typeof c.expiry === "string" ? c as Card : null;
  } catch {
    return null;
  }
}

export interface CardPart { part: UserSealedSecretPart; label: string; text: string; value: string }

/** The five parts, in the order a payment form asks for them; the number shown in groups of four. */
export function cardParts(c: Card): CardPart[] {
  return [
    { part: "number", label: "Card number", text: c.number.replace(/(.{4})(?=.)/g, "$1 "), value: c.number },
    { part: "expiry", label: "Expiry", text: c.expiry, value: c.expiry },
    { part: "cvc", label: "CVC", text: c.cvc, value: c.cvc },
    { part: "name", label: "Name on card", text: c.name, value: c.name },
    { part: "zip", label: "Billing ZIP", text: c.zip, value: c.zip },
  ];
}

/**
 * Puts a value on the clipboard. A secret is written over with an empty string after 90 s, when the tab is still
 * open and in front (a browser lets a page write only then); the line says so only when that can happen.
 */
export async function copyText(value: string, secret: boolean): Promise<string> {
  try {
    await navigator.clipboard.writeText(value);
  } catch {
    throw new Error(revealWords.noClipboard);
  }
  if (!secret) return revealWords.copiedPlain;
  setTimeout(() => {
    if (document.visibilityState === "visible" && document.hasFocus()) void navigator.clipboard.writeText("").catch(() => undefined);
  }, clipboardSeconds * 1000);
  return document.visibilityState === "visible" ? revealWords.copied : revealWords.copiedPlain;
}

// Settings ▸ You ▸ Accounts ▸ Details… (#5116, section 7), as the window's AccountsWords.

export const detailsLabel = "Details…";
export const noSecretLine = "No secret. Add one in Secrets, then name it in Edit….";
export const notInSecrets = "not in Secrets";

/** One line of the sheet; Copy copies text, which is never a secret. */
export interface DetailField { label: string; text: string; copies: boolean }

/** What an account names for its secret or its card. */
export type Named = { kind: "none" } | { kind: "elsewhere"; text: string } | { kind: "secret"; row: UserSecretRow };

export function named(name: string | undefined, rows: readonly UserSecretRow[]): Named {
  const n = name?.trim();
  if (!n) return { kind: "none" };
  const row = rows.find((r) => r.name === n);
  return row ? { kind: "secret", row } : { kind: "elsewhere", text: n };
}

const text = (s: string | undefined) => s?.trim() || undefined;

function money(usd: number): string {
  return Number.isInteger(usd) ? `$${usd}` : `$${usd.toFixed(2)}`;
}

/** The first part: who and what it is. */
export function identityFields(a: OutsideAccount, about: string): DetailField[] {
  const out: DetailField[] = [{ label: "Service", text: a.service, copies: true }];
  const address = text(a.address);
  if (address) out.push({ label: "Address", text: address, copies: true });
  const username = text(a.username);
  if (username) out.push({ label: "User name", text: username, copies: true });
  out.push({ label: "Description", text: about, copies: false });
  const plan = [text(a.plan), a.monthlyCostUsd === undefined ? undefined : `${money(a.monthlyCostUsd)} a month`].filter((v) => v).join(" · ");
  if (plan) out.push({ label: "Plan", text: plan, copies: false });
  out.push({ label: "Two-factor", text: text(a.twoFactor) ?? "None", copies: false });
  return out;
}

/** "2027-02-01 (in 81 d)", or null when it has no date. */
export function tokenExpiry(a: OutsideAccount, now: number): string | null {
  const day = text(a.tokenExpires);
  if (!day) return null;
  const at = /^\d{4}-\d{2}-\d{2}$/.test(day) ? Date.parse(`${day}T00:00:00Z`) : NaN;
  if (Number.isNaN(at)) return day;
  const days = Math.ceil((at - now) / 86_400_000);
  return days < 0 ? `${day} (expired)` : `${day} (in ${days} d)`;
}

/** The last part: notes, the issue and the projects. */
export function recordFields(a: OutsideAccount): DetailField[] {
  const out: DetailField[] = [];
  const notes = text(a.notes);
  if (notes) out.push({ label: "Notes", text: notes, copies: true });
  const issue = text(a.issue);
  if (issue) out.push({ label: "Issue", text: issue, copies: false });
  out.push({ label: "Projects", text: a.projects?.length ? a.projects.join(", ") : "All", copies: false });
  return out;
}

/** The account it was opened from, for the audit entry. */
export function auditAccount(a: OutsideAccount): UserSealedSecretAccount {
  const address = text(a.address);
  return address ? { service: a.service, address } : { service: a.service };
}
