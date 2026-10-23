// Catalogue governance (#2019, M5): a person asks for an MCP server or skill, an admin approves it
// for a group or the person, or refuses it; and who uses each, at which version. The words and the
// list rules, apart from the views, so the tests read them.
import type { CatalogApproval, CatalogKind, CatalogRequest, CatalogUseRow } from "../protocol/generated";

export const catalogueTitle = "Catalogue";
export const askTitle = "Ask for an MCP Server or Skill";
export const askFoot = "An admin approves it for you or for a group of yours. Once a group has it approved, each of its members has it approved at once.";
export const usageTitle = "Who Uses What";
export const usageFoot = "From what each machine last said it has from a catalogue, each hour. Servers added by hand say so.";
export const approvalsTitle = "Approved";
export const noApprovals = "Nothing is approved yet. Approve a request in Requests, for the person or for a group.";
export const noUsage = "No machine has said what it has yet. A machine says it each hour once it runs this version.";
export const approvalsFoot = "An approval answers a request. The Policy's marketplaces still say what a machine may add.";
export const policyStillBlocks = "Your organisation's Policy still blocks it if no marketplace it allows has it.";
export const kindNames: Record<CatalogKind, string> = { mcp: "MCP server", skills: "Skill" };

/** "the MCP server github" or "the skill review". */
export function itemWords(kind: CatalogKind, name: string): string {
  return kind === "skills" ? `the skill ${name}` : `the MCP server ${name}`;
}

/** An admin's line for a waiting request: "Sam asks for the MCP server github: for reviews". */
export function requestWords(r: CatalogRequest): string {
  const why = r.why ? `: ${r.why}` : "";
  return `${r.userName} asks for ${itemWords(r.kind, r.name)}${why}`;
}

/**
 * A person's line for their own request, by its state. An approval does not add it, nor change what the Policy's
 * marketplaces allow (#2434): the line says how to add it and, when the Policy names marketplaces, that they still decide.
 */
export function mineWords(r: CatalogRequest, marketplacesLimited = false): string {
  const item = itemWords(r.kind, r.name);
  const first = item.charAt(0).toUpperCase() + item.slice(1);
  switch (r.state) {
    case "approved": {
      const add = r.kind === "skills" ? "Add it as you add any skill." : "Add it as you add any MCP server.";
      const still = marketplacesLimited ? ` ${policyStillBlocks}` : "";
      return `${first}: approved for ${r.groupName ?? "you"}. ${add}${still}`;
    }
    case "refused": return `${first}: refused`;
    default: return `${first}: waiting for an admin`;
  }
}

/** Who an approval is for: "Platform" or "Sam". */
export function approvalFor(a: CatalogApproval): string {
  return a.groupName ?? a.group ?? a.userName ?? a.user ?? "";
}

/** What Take Back… asks first (#2438): an approval taken back is asked for and approved again. */
export function takeBackQuestion(kind: CatalogKind, name: string, forWhom: string): string {
  return `Take back the ${kind === "mcp" ? "MCP server" : "skill"} ${name} for ${forWhom}? Their machines lose it, and it must be asked for and approved again.`;
}

/** "3 machines: Bea, Sam": at most 3 names, then "and 2 more". */
export function usersWords(row: CatalogUseRow): string {
  const machines = row.machines === 1 ? "1 machine" : `${row.machines} machines`;
  const names = row.people.map((p) => p.name);
  if (names.length === 0) return machines;
  const shown = names.slice(0, 3).join(", ");
  return names.length > 3 ? `${machines}: ${shown} and ${names.length - 3} more` : `${machines}: ${shown}`;
}

/** The request with that id put in, or replaced; waiting ones only, oldest first. */
export function withGovernanceRequest(list: CatalogRequest[], r: CatalogRequest): CatalogRequest[] {
  const rest = list.filter((x) => x.id !== r.id);
  return (r.state === "waiting" ? [...rest, r] : rest).sort((a, b) => a.at - b.at);
}
