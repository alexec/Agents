// A secret's use waiting on a person (#4017), as NeedRequest.SecretUse words it for the window
// and the Remote: which secret a session wants, where its value goes, and the answers a person gives.
// Never the value: the request has none.
import type { Request as PersonRequest, RequestSecretUse, RequestSecretUseAnswer } from "../protocol/generated";

export type SecretUseAction = RequestSecretUseAnswer["action"];

/** The words on the row's menu, as the banner's buttons say them. */
export const secretUseWords: Record<SecretUseAction, string> = {
  once: "Approve", session: "Approve for This Session", always: "Always Approve", hour: "Approve for 1 Hour", deny: "Deny",
};

/** The known gap (#4179), as agentsd's banner and NeedRequest.SecretUse.terminalCaveat say it. */
export const terminalCaveat = "Agents cannot tell a terminal from an agent outside its session.";

/** A terminal's agents-secret NAME (#4179): a secret's use that no session asked. */
export function isTerminalRequest(request: PersonRequest): boolean {
  return request.askedBy === undefined && secretUseOf(request)?.use === "terminal";
}

/** A request's secret use, when it is one. */
export function secretUseOf(request: PersonRequest): RequestSecretUse | undefined {
  return request.source === "secretUse" ? request.detail.secretUse : undefined;
}

/** The uses of a secret a session waits on (#4918), in the list's order: its chat's cards. A terminal's has no session, so none is. */
export function secretUsesAskedBy(requests: PersonRequest[], session: string): PersonRequest[] {
  return requests.filter((r) => r.askedBy === session && secretUseOf(r) !== undefined);
}

/** The row's title: the secret first, as the banner says it, so a narrow sidebar cuts the place, not the name. */
export function secretUseTitle(use: RequestSecretUse): string {
  return `Wants to ${use.use === "account" ? "read" : "use"} ${use.name}`;
}

/** Where the value goes, as the row's grey line says it. */
export function secretUseWhere(use: RequestSecretUse): string {
  if (use.use === "ci") return `CI secret in ${use.place}`;
  if (use.use === "terminal") return `Terminal: ${use.place} · ${terminalCaveat}`;
  if (use.use === "account") return `Account: manage_accounts ${use.call ?? "get"}`;
  if (use.use === "browser") return `Browser on ${use.place}`;
  if (use.use === "screen") return use.app ? `Screen: ${use.app} on ${use.place}` : `Screen on ${use.place}`;
  return use.use === "mcp" ? `MCP server ${use.place}` : `Fill on ${use.place}`;
}

/** The answers, in order. A session's own secret has no Always Approve: it is the same as for this session.
 * A terminal's are once, for 1 hour and deny (#4179). */
export function secretUseActions(use: RequestSecretUse): SecretUseAction[] {
  if (use.use === "terminal") return ["once", "hour", "deny"];
  return use.sessionOnly ? ["once", "session", "deny"] : ["once", "session", "always", "deny"];
}

/** The method a signed answer names (#4058). */
export const approveSecretUse = "secrets/approveUse";

/** Whether an answer goes signed (#4149): it allows the use, on a Linux machine, which opens the value only then. */
export function secretUseSigns(use: RequestSecretUse, action: SecretUseAction): boolean {
  return use.needsSignature === true && action !== "deny";
}

/** What a signed answer signs, as Go's secretrelease.Approval reads it: the request and what it names. */
export function secretUseApprovalParams(request: string, use: RequestSecretUse, action: SecretUseAction): string {
  return JSON.stringify({ request, name: use.name, use: use.use, place: use.place, action });
}

/** The row's words when this page has no lock key to sign with: a person answers on a device that has one. */
export const answerElsewhere = "Answer on the Mac or the Remote";
