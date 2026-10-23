// Sign-in's words and lists (#995, spec 736 T2), as the window's and the Remote's (AgentsKitCore's
// SignInWords): a GitHub sign-in on a new client waits for Approve on one of the person's clients,
// and an admin turns providers on and allows Google Workspace domains and GitHub organisations.
// A browser does not sign in with a built-in provider: it pairs with a code from a signed-in client
// (FR-014), by approval on one of the person's clients with the code it shows (#2097), or with its
// organisation's provider (#1002, slice 3), in the same tab.
import type { SignIn, SignInOrgProvider, SignInRequest } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export const paneTitle = "Sign-in Providers";
export const signInsTitle = "Sign-ins";
/** Where a person adds a sign-in: the group and pane every client lists it under (#2157, #2256), as SignInWords.signInsPlace. */
export const signInsPlace = `Control plane ▸ ${signInsTitle}`;

const titles: Record<string, string> = { google: "Google", apple: "Apple", github: "GitHub", local: "This control plane", code: "Invite code",
  browser: "Browser" };

/** A provider as the screen names it. */
export function providerTitle(provider: string): string {
  return titles[provider] ?? provider;
}

/** The providers a person adds or takes off: never the local owner's or a code. */
export function isOutside(provider: string): boolean {
  return provider === "google" || provider === "apple" || provider === "github";
}

/** After the client's name: "Sam's iPhone wants to sign in as you." */
export const wants = "wants to sign in as you.";

/** The card's second line: "GitHub · sam". */
export function account(request: SignInRequest): string {
  return [providerTitle(request.provider), request.login].filter(Boolean).join(" · ");
}

/** A browser that asked by an account (#2097): the person types the code it shows, and the card has none. */
export function needsCode(request: SignInRequest): boolean {
  return request.provider === "browser";
}

export const typeCode = "Type the code that the browser shows.";

// Pairing this browser by approval (#2097), on the pairing page.
export const askTitle = "Sign in with your account";
export const askPlaceholder = "Email or GitHub login";
export const askFoot = "One of your signed-in Macs, iPhones or iPads asks you to type the code this page shows.";
export const askWaiting = "On one of your signed-in clients, type this code and approve. This page waits for 10 minutes.";
export const askExpired = "Nobody approved this browser within 10 minutes. Try again.";

/** One sign-in as Settings lists it: "GitHub · sam", "Google · sam@example.com". */
export function row(signIn: SignIn): string {
  const detail = signIn.email ?? signIn.login ?? (isOutside(signIn.provider) ? signIn.account : undefined);
  return [providerTitle(signIn.provider), detail].filter(Boolean).join(" · ");
}

export function removeTitle(signIn: SignIn): string {
  return `Remove ${row(signIn)}?`;
}

export const removeMessage = "You can no longer pair a client with this sign-in. Your clients stay paired.";
export const signInsFoot = `Sign in with one of these on a Mac, iPhone or iPad to pair it with no code. Add one there, under ${signInsPlace}. A browser pairs with its email or GitHub login, and your approval.`;
/** Control plane ▸ Sign-ins with none yet: where one is added (#2080). */
export const signInsNone = `No sign-ins yet. Add one on a Mac, iPhone or iPad, under ${signInsPlace}.`;
export const paneFoot = `People sign in with these to pair a window or a phone with no code. A person not known joins only through an allowed Google Workspace domain; everyone else is invited first, and adds their sign-in under ${signInsPlace}.`;
export const domainsTitle = "Allowed Google Workspace domains";
export const domainsFoot = "Anyone with a Workspace account on one of these joins as a member with no invite.";
export const organisationsTitle = "Allowed GitHub organisations";
export const organisationsFoot = "A GitHub sign-in must be in one of these. It does not let anyone join with no invite.";

/** "example.com, example.org" as a list, with nothing empty. */
export function list(text: string): string[] {
  return text.split(",").map((s) => s.trim()).filter((s) => s.length > 0);
}

/** A request said again replaces the one before it; a new one goes at the end. */
export function withSignIn(list: readonly SignInRequest[], request: SignInRequest): SignInRequest[] {
  const at = list.findIndex((r) => r.request === request.request);
  if (at < 0) return [...list, request];
  const out = [...list];
  out[at] = request;
  return out;
}

/** A request decided or answered goes. */
export function withoutSignIn(list: readonly SignInRequest[], request: string): SignInRequest[] {
  return list.filter((r) => r.request !== request);
}

/** The requests not yet expired at `now`. */
export function liveSignIns(list: readonly SignInRequest[], now: Date = new Date()): SignInRequest[] {
  return list.filter((r) => fromWireDate(r.expires).getTime() > now.getTime());
}

// Org providers (#1002, slice 3), as SignInWords has them on the window and the Remote.

/** An org provider's button, first on the pairing page (FR-026). */
export function orgButton(name: string): string {
  return `Sign in with ${name}`;
}

/** Opens the email field when a claimed domain sends people to its provider (FR-011). */
export const useEmail = "Use an Email";
export const emailPlaceholder = "you@example.com";
export const noOrgForEmail = "No organisation sends people with that email here. Sign in another way, or use a code.";
/** A sign-in that came back after its pending key went (10 minutes), or to another browser. */
export const signInExpired = "This sign-in took too long, or started in another browser. Start it again.";

/** The only page a client of a suspended person shows (FR-029). */
export const suspendedLine = "Your organisation's sign-in turned your access off.";
export const suspendedFoot = "Ask your IT team to turn it on again. This browser stays paired, and connects again when they do.";
/** The same, for a browser that the suspension stopped before it paired. */
export const suspendedFootUnpaired = "Ask your IT team to turn it on again, then sign in again.";

/** A built-in sign-in at a domain that requires its org provider (FR-012, FR-029). */
export function required(name: string): string {
  return `Your organisation asks you to sign in with ${name}.`;
}

/** The failures of the org flow, as the wire numbers them. */
export const orgSignInRequired = -32077;
export const personSuspended = -32078;
export const managedByProvider = -32079;

/** The org provider an `orgSignInRequired` refusal asks for, from its data `{provider, name}`. */
export function requiredProvider(code: number, data: unknown): SignInOrgProvider | null {
  if (code !== orgSignInRequired || typeof data !== "object" || data === null) return null;
  const { provider, name } = data as { provider?: unknown; name?: unknown };
  if (typeof provider !== "string" || provider === "") return null;
  return { id: provider, name: typeof name === "string" && name !== "" ? name : provider, order: 0 };
}

/** The org providers in the order an admin set. */
export function byOrder(list: readonly SignInOrgProvider[] | undefined): SignInOrgProvider[] {
  return [...(list ?? [])].sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));
}

/** A provider's name by its id, from `signIn/providers`' org providers: the id when it is not there. */
export function orgName(id: string, names: Readonly<Record<string, string>>): string {
  return names[id] ?? id;
}

/** "id → name" for each org provider. */
export function orgNames(list: readonly SignInOrgProvider[] | undefined): Record<string, string> {
  return Object.fromEntries((list ?? []).map((p) => [p.id, p.name]));
}

/** What the provider sent the page back with (FR-027): `#oidc-ticket=<t>`, or `#oidc-error=<code>&oidc-message=<words>`. */
export interface OIDCReturn {
  ticket?: string;
  error?: string;
  message?: string;
}

/** The return in the address's fragment, or null when it holds none. */
export function oidcReturn(hash: string): OIDCReturn | null {
  if (!hash.startsWith("#oidc-")) return null;
  const values = new URLSearchParams(hash.slice(1));
  const ticket = values.get("oidc-ticket") ?? "";
  const error = values.get("oidc-error") ?? "";
  const message = values.get("oidc-message") ?? "";
  if (!ticket && !error) return null;
  const read: OIDCReturn = {};
  if (ticket) read.ticket = ticket;
  if (error) read.error = error;
  if (message) read.message = message;
  return read;
}

/** The words for a return with an error: the provider's own, or its code. */
export function oidcErrorWords(back: OIDCReturn): string {
  return back.message ?? `The sign-in did not work (${back.error ?? "unknown"}). Try again, or use a code.`;
}

/** Whether a pending sign-in, made at `made` (ms), is still good at `now`: 10 minutes, as orgStart's address. */
export function pendingLive(made: number, now: number = Date.now()): boolean {
  return now >= made && now - made < 10 * 60_000;
}

/** Whether the text looks like an email: something, an @, a domain with a dot. */
export function looksLikeEmail(text: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text.trim());
}

// People's org lines (FR-028), as PeopleWords has them. Edit in Console is orgPolicy.ts's.

export function managedBy(name: string): string {
  return `Managed by ${name}`;
}
export const waitingFirstSignIn = "Waiting for first sign-in";
export function suspendedBy(name: string): string {
  return `Suspended by ${name}`;
}
/** On a role or a group that the provider controls (FR-020). */
export function setBy(name: string): string {
  return `Set by ${name}`;
}
/** A SCIM group's line: where it comes from. */
export function fromProvider(name: string): string {
  return `From ${name}`;
}
