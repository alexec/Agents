// Sign-in's words and lists (#995, spec 736 T2), as the window's and the Remote's (AgentsKitCore's
// SignInWords): a GitHub sign-in on a new client waits for Approve on one of the person's clients,
// and an admin turns providers on and allows Google Workspace domains and GitHub organisations.
// A browser does not sign in with a provider: it pairs with a code from a signed-in client (FR-014).
import type { SignIn, SignInRequest } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export const paneTitle = "Sign-in";
export const signInsTitle = "Sign-ins";

const titles: Record<string, string> = { google: "Google", apple: "Apple", github: "GitHub", local: "This control plane", code: "Invite code" };

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

/** One sign-in as Settings lists it: "GitHub · sam", "Google · sam@example.com". */
export function row(signIn: SignIn): string {
  const detail = signIn.email ?? signIn.login ?? (isOutside(signIn.provider) ? signIn.account : undefined);
  return [providerTitle(signIn.provider), detail].filter(Boolean).join(" · ");
}

export function removeTitle(signIn: SignIn): string {
  return `Remove ${row(signIn)}?`;
}

export const removeMessage = "You can no longer pair a client with this sign-in. Your clients stay paired.";
export const signInsFoot = "Sign in with one of these on a Mac, iPhone or iPad to pair it with no code. Add one there, under Account. A browser pairs with a code.";
export const paneFoot = "People sign in with these to pair a window or a phone with no code. A person not known joins only through an allowed Google Workspace domain; everyone else is invited first, and adds the sign-in under Account.";
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
