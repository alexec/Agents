// Console ▸ Sign-In (#1002, spec 1002 FR-030): the organisation's own sign-in providers (Okta, Entra,
// Google Workspace or any OIDC issuer), each one's claimed domains and its SCIM. The presets fill the
// form only (research R3); the control plane checks the issuer's discovery document on Save and Check.
import type { DomainClaim, OrgProvider, OrgProviderCheck, OrgProviderJoin, OrgProviderPreset, SCIMMatch, SCIMToken,
  SignInDomainPreviewPerson } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { actorName, when } from "./orgPolicy";

export const presets: readonly OrgProviderPreset[] = ["okta", "entra", "googleWorkspace", "oidc"];
export const presetNames: Record<OrgProviderPreset, string> = { okta: "Okta", entra: "Microsoft Entra ID", googleWorkspace: "Google Workspace",
  oidc: "Other OIDC" };
/** What the issuer looks like for each preset, as the field's placeholder. */
export const issuerHints: Record<OrgProviderPreset, string> = { okta: "https://acme.okta.com",
  entra: "https://login.microsoftonline.com/TENANT-ID/v2.0", googleWorkspace: "https://accounts.google.com", oidc: "https://sso.example.com" };

export const joins: readonly OrgProviderJoin[] = ["invite", "anyone", "scim"];
export const joinNames: Record<OrgProviderJoin, string> = { invite: "Only by invite", anyone: "Anyone the provider signs in",
  scim: "Only people from SCIM" };
export const matchNames: Record<SCIMMatch, string> = { externalId: "externalId", userName: "userName" };

export interface ProviderForm {
  preset: OrgProviderPreset;
  name: string;
  issuer: string;
  clientID: string;
  /** Written only: empty keeps the secret there is. */
  secret: string;
  accountClaim: string;
  tenant: string;
  join: OrgProviderJoin;
}

/** A new provider's form, with the preset's defaults (research R3). */
export function newProviderForm(preset: OrgProviderPreset): ProviderForm {
  return { preset, name: "", issuer: preset === "googleWorkspace" ? issuerHints.googleWorkspace : "", clientID: "", secret: "",
    accountClaim: preset === "entra" ? "oid" : "sub", tenant: "", join: "invite" };
}

/** Another preset chosen in the form: its defaults, keeping what was typed that still fits. */
export function withPreset(form: ProviderForm, preset: OrgProviderPreset): ProviderForm {
  const fresh = newProviderForm(preset);
  const issuer = form.issuer.trim() === "" || form.issuer === newProviderForm(form.preset).issuer ? fresh.issuer : form.issuer;
  return { ...form, preset, issuer, accountClaim: fresh.accountClaim, tenant: preset === "entra" ? form.tenant : "" };
}

export function providerFormOf(p: OrgProvider): ProviderForm {
  return { preset: p.preset, name: p.name, issuer: p.issuer, clientID: p.clientID, secret: "", accountClaim: p.accountClaim ?? "sub",
    tenant: p.tenant ?? "", join: p.join ?? "invite" };
}

/** The tenant id in an Entra issuer, as issuerHints.entra has it. */
export function entraTenant(issuer: string): string | undefined {
  return /^https:\/\/login\.microsoftonline\.com\/([0-9a-f-]{36})\/v2\.0\/?$/i.exec(issuer.trim())?.[1];
}

const scopesOf = (preset: OrgProviderPreset) => preset === "googleWorkspace" ? ["openid", "email", "profile"]
  : ["openid", "email", "profile", "offline_access"];

/** The provider to save, and its secret when typed; or what is wrong with the form. */
export function providerOf(form: ProviderForm, old?: OrgProvider): { provider: OrgProvider; secret?: string } | { problem: string } {
  const name = form.name.trim();
  if (name.length < 1 || name.length > 40) return { problem: "Give the provider a name of 1 to 40 characters, as people see it on the button." };
  const issuer = form.issuer.trim();
  if (!/^https:\/\/[^\s/]+/.test(issuer)) return { problem: "The issuer is an https address, such as " + issuerHints[form.preset] + "." };
  const clientID = form.clientID.trim();
  if (clientID === "") return { problem: "Type the client ID that the provider gave this app." };
  const secret = form.secret.trim();
  if (!old && secret === "") return { problem: "Type the client secret. It is not shown again." };
  const tenant = form.preset === "entra" ? form.tenant.trim() || entraTenant(issuer) : undefined;
  if (form.preset === "entra" && !tenant) return { problem: "Type the tenant ID, or use the issuer with the tenant ID in it." };
  const provider: OrgProvider = { ...(old ?? {}), id: old?.id ?? "", name, preset: form.preset, issuer, clientID,
    accountClaim: form.accountClaim.trim() || "sub", scopes: old?.scopes ?? scopesOf(form.preset), join: form.join, on: old?.on ?? true };
  if (tenant) provider.tenant = tenant;
  else delete provider.tenant;
  // Only in answers; the control plane makes them.
  delete provider.redirectURI;
  return secret === "" ? { provider } : { provider, secret };
}

/** "Secret a1b2c3d4, set by Alex on 12 Oct at 09:30", or "No secret". */
export function secretWords(p: OrgProvider, now: Date = new Date()): string {
  if (!p.secret) return "No secret";
  const by = p.secret.setBy ? ` by ${actorName(p.secret.setBy)}` : "";
  return `Secret ${p.secret.fingerprint}, set${by} ${when(fromWireDate(p.secret.setAt), now)}`;
}

/** What Check found. */
export function checkWords(name: string, c: OrgProviderCheck): string {
  const keys = c.jwksKeys === 1 ? "1 signing key" : `${c.jwksKeys} signing keys`;
  if (c.ok) return `${name}: the discovery document has what sign-in needs, and ${keys}.`;
  return `${name}: the discovery document lacks ${c.missing.join(", ")}. ${keys}.`;
}

/** The providers in sign-in order, as the buttons show them. */
export function inOrder<T extends { provider: OrgProvider }>(list: readonly T[]): T[] {
  return [...list].sort((a, b) => (a.provider.order ?? 0) - (b.provider.order ?? 0) || a.provider.name.localeCompare(b.provider.name));
}

/** The orders after moving one provider up (-1) or down (+1): every provider numbered 0, 1, 2… */
export function moved(ids: readonly string[], id: string, by: -1 | 1): string[] {
  const at = ids.indexOf(id);
  const to = at + by;
  if (at < 0 || to < 0 || to >= ids.length) return [...ids];
  const next = [...ids];
  [next[at], next[to]] = [next[to]!, next[at]!];
  return next;
}

/** A domain's state. */
export function domainWords(d: DomainClaim, now: Date = new Date()): string {
  if (d.state === "notProved") return "Not proved yet. Add the TXT record at your DNS host, then Check.";
  if (d.failingSince) return `The TXT record has not been found since ${when(fromWireDate(d.failingSince), now)}. The claim is dropped after 7 days.`;
  return d.lastGood ? `Proved, last checked ${when(fromWireDate(d.lastGood), now)}` : "Proved";
}

/** What Require changes, before it is saved (FR-012). */
export function previewWords(domain: string, provider: string, people: readonly SignInDomainPreviewPerson[]): string {
  const head = `Require ${provider} for ${domain}?`;
  if (people.length === 0) return `${head}\n\nNobody signs in with another provider at ${domain} now. New sign-ins at ${domain} must use ${provider}.`;
  const lines = people.slice(0, 20).map((p) => `• ${p.name}: ${p.signIns.map((s) => s.email ?? s.provider).join(", ")}`);
  const more = people.length > 20 ? `\n…and ${people.length - 20} more.` : "";
  return `${head}\n\nThese people sign in at ${domain} with another provider. Their next sign-in, pairing or key renewal must use ${provider}. `
    + `The local owner is never refused.\n\n${lines.join("\n")}${more}`;
}

/** SCIM's base URL, beside the redirect URI: <https address>/scim/v2/. */
export function scimBaseURL(redirectURI: string | undefined): string | undefined {
  if (!redirectURI) return undefined;
  try {
    return `${new URL(redirectURI).origin}/scim/v2/`;
  } catch {
    return undefined;
  }
}

/** "Made by Alex on 12 Oct at 09:30 · last used just now from 10.0.0.4", or with "Revoked". */
export function tokenWords(t: SCIMToken, now: Date = new Date()): string {
  const parts = [`Made by ${actorName(t.made.by)} ${when(fromWireDate(t.made.at), now)}`];
  if (t.revoked) parts.push(`revoked ${when(fromWireDate(t.revoked.at), now)}`);
  else if (t.lastUse) parts.push(`last used ${when(fromWireDate(t.lastUse.at), now)}${t.lastUse.address ? ` from ${t.lastUse.address}` : ""}`);
  else parts.push("not used yet");
  if (t.ends && !t.revoked) parts.push(`ends ${when(fromWireDate(t.ends), now)}`);
  return parts.join(" · ");
}

export const noOrgProviders = "No providers of your own yet. Add one so people sign in with your organisation’s account: Okta, Microsoft Entra ID, Google Workspace or another OIDC provider.";
export const orgFoot = "People see each provider on the sign-in screen, in this order, before Google, Apple and GitHub. Register the redirect URI at the provider. The secret is never shown again, also to an admin.";
export const domainsFoot = "Claim a domain to prove your organisation owns it. Send people here starts this provider when someone types an email at the domain. Require this provider refuses Google, Apple and GitHub sign-ins at the domain.";
export const scimFoot = "SCIM lets the provider add, change and suspend people and groups here. Give the provider the base URL and a token. A token is shown once; at most two are live at a time.";
export const groupRoleWords = "Gives the admin role";
export const groupRoleFoot = "Each person in the group is an admin while they are in it. The control plane never lets SCIM remove its last admin.";
