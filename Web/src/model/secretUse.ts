// A secret's use waiting on a person (#4017), as NeedRequest.SecretUse words it for the window
// and the Remote: which secret a session wants, where its value goes, and the answers a person gives.
// Never the value: the request has none.
import type { Request as PersonRequest, RequestSecretUse, RequestSecretUseAnswer } from "../protocol/generated";

export type SecretUseAction = RequestSecretUseAnswer["action"];

/** The words on the row's menu, as the banner's buttons say them. */
export const secretUseWords: Record<SecretUseAction, string> = {
  once: "Allow Once", session: "Allow for This Session", always: "Allow Always", deny: "Deny",
};

/** A request's secret use, when it is one. */
export function secretUseOf(request: PersonRequest): RequestSecretUse | undefined {
  return request.source === "secretUse" ? request.detail.secretUse : undefined;
}

/** The row's title: the secret first, as the banner says it, so a narrow sidebar cuts the place, not the name. */
export function secretUseTitle(use: RequestSecretUse): string {
  return `Wants to use ${use.name}`;
}

/** Where the value goes, as the row's grey line says it. */
export function secretUseWhere(use: RequestSecretUse): string {
  if (use.use === "ci") return `CI secret in ${use.place}`;
  return use.use === "mcp" ? `MCP server ${use.place}` : `Fill on ${use.place}`;
}

/** The answers, in order. A session's own secret has no Allow always: it is the same as for this session. */
export function secretUseActions(use: RequestSecretUse): SecretUseAction[] {
  return use.sessionOnly ? ["once", "session", "deny"] : ["once", "session", "always", "deny"];
}
