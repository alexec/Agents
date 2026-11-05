// Secrets for this session only (#3548): set on the ask_secret card or in Settings ▸ Secrets for one
// session. Only that session's agent can use one, and its host deletes it when the session is archived.
// The words are SessionSecretWords' in Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionSecrets.swift.
import type { Agent, SessionSecret } from "../protocol/generated";

export const sessionSecretWords = {
  toggle: "For this session only",
  header: "For One Session",
  footer: "Only that session's agent can use one, and it is deleted when the session is archived. " +
    "It stays on this machine and is not sent to your other machines.",
  none: "No secrets for one session.",
  add: "Add for a Session…",
  sheetTitle: "Add a Secret for a Session",
  session: "Session",
  noSessions: "No session to add one for.",
  removeMessage: "Its agent is told it expired.",
} as const;

/** The answer's choice beside the card's one field, as the host names it. */
export const sessionOnlyField = "sessionOnly";

/** Under the card's field, with the checkbox on. */
export function keepingForSession(recipient: string): string {
  return `Kept on ${recipient} for this session only, and deleted when it is archived. The agent gets its name, never the value.`;
}

export function removeQuestion(secret: SessionSecret): string {
  return `Remove ${secret.name} from “${secret.title}”?`;
}

/** The sessions on a machine that can take a secret for one session: not archived, latest first. */
export function sessionsForSecrets(agents: readonly Agent[]): Agent[] {
  return agents.filter((a) => a.state !== "archived").sort((a, b) => b.lastActivityAt - a.lastActivityAt);
}
