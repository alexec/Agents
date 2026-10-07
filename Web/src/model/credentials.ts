// A server's key ask (043, #344): what a key a server is lent looks like, and the words the
// window's TokenAskCard says about one, from CredentialKind in AgentsKitCore. The page keeps
// no key: one pasted here is lent on this browser's own connection and goes with it.
import type { CredentialKind } from "../protocol/generated";

/** Each kind's runtime and the prefixes that tell it apart (CredentialKind.prefixes). */
const kinds: Record<CredentialKind, { runtimeID: string; prefixes: string[] }> = {
  geminiAPIKey: { runtimeID: "gemini", prefixes: ["AIza", "AQ."] },
};

/** Whether `runtimeID` takes a key the page can lend (CredentialKind.kinds(for:)). */
export function takesKey(runtimeID: string): boolean {
  return Object.values(kinds).some((kind) => kind.runtimeID === runtimeID);
}

/** The kind of a pasted key for `runtimeID`, or null when it isn't one (`Secret(text)`). */
export function keyKind(text: string, runtimeID: string): CredentialKind | null {
  const trimmed = text.trim();
  for (const [kind, shape] of Object.entries(kinds) as [CredentialKind, (typeof kinds)[CredentialKind]][]) {
    if (shape.runtimeID === runtimeID && shape.prefixes.some((prefix) => trimmed.startsWith(prefix))) return kind;
  }
  return null;
}

/** The runtime a `credentialWanted` failure's data names, or null when it names none. */
export function wantedRuntime(data: unknown): string | null {
  if (typeof data !== "object" || data === null) return null;
  const runtime = (data as { runtime?: unknown }).runtime;
  return typeof runtime === "string" ? runtime : null;
}

/** The card's words, as the Remote says them (TokenAskCard, RemoteModel). */
export const keyWords = {
  title: (name: string, label: string) => `${name} on ${label} needs a key`,
  body: (name: string, label: string) =>
    `${label} has no ${name} sign-in of its own. Paste a key and Agents lends it to ${label} while this browser is connected. It is kept nowhere.`,
  field: (name: string) => `Paste a ${name} key`,
  /** CredentialKind.pasteRefusal(for:). */
  notAKey: "That isn’t a Gemini API key. They start AIza or AQ.",
  /** CredentialKind.source(for:). */
  source: "Get one at aistudio.google.com/apikey.",
  action: "Lend and start",
} as const;
