// Settings ▸ You ▸ Secrets ▸ On This Machine (#5122): the secrets a machine keeps for itself, which
// agents saved there (ask_secret, capture_secret, generate_secret). The words are LocalSecretWords' in
// Packages/AgentsKit/Sources/AgentsKitCore/Model/LocalSecrets.swift.
import type { LocalSecret } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { setPart, usedPart, type Part } from "./secretInfo";

export const localSecretWords = {
  header: "On This Machine",
  footer: "Agents saved these on this machine, with ask_secret, capture_secret or generate_secret. " +
    "Every session's agent here can use one by its name. They are not sent to your other machines.",
  notBackedUp: "Only on this machine. Not backed up.",
} as const;

/** The line under a secret a machine keeps for itself: "Set 1 h ago · Used 20 min ago". */
export function localLine(secret: Pick<LocalSecret, "setAt" | "lastOp">, now = new Date(), timeZone?: string): Part[] {
  const set = setPart(null, fromWireDate(secret.setAt), now, timeZone);
  return [...(set ? [set] : []), usedPart(secret.lastOp, now, timeZone)];
}
