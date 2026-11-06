// The lineage nodes the web page links to: a session's machine, and a node's address on its forge.
import type { LineageNode } from "../protocol/generated";
import { nodeUrl } from "./value";

/** The machine a session is on, from every machine's sessions, archived ones too: not only the menu's newest (#3156). */
export function sessionHost(agents: Readonly<Record<string, readonly { id: string }[]>>, id: string): string | undefined {
  return Object.keys(agents).find((host) => agents[host]?.some((a) => a.id === id));
}

/** A node's address on GitHub: a PR's is its /pull/ page. */
export function lineageUrl(n: LineageNode): string | undefined {
  const url = nodeUrl(n);
  return url && n.kind === "pr" ? url.replace("/issues/", "/pull/") : url;
}
