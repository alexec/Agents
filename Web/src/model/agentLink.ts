// agents://agent/<id>: a link to a session, as the daily summary writes one for each line (#3353).
// On the Mac window and the Remote it selects that session (AttentionLink.swift); a click on one on
// the web page does the same. The page holds one store, so `startAgentLinks` gives the renderer a
// way to it rather than each Markdown view taking one more prop.
import type { Store } from "./store";
import { go } from "../route";
import { folderPath } from "./groups";

const agentPattern = /^agents:\/\/agent\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/?$/i;

/** The session an agents://agent/<id> link names, or null for any other link. */
export function agentLinkID(href: string): string | null {
  return agentPattern.exec(href.trim())?.[1] ?? null;
}

let opener: ((id: string) => void) | undefined;

/** Selects the session a link names; nothing before `startAgentLinks`. */
export function openAgentLink(id: string): void {
  opener?.(id);
}

/** Lets links open sessions: the one the page holds first, then one asked of each host, archived too. */
export function startAgentLinks(store: Store): void {
  opener = (id) => void openIn(store, id);
}

async function openIn(store: Store, id: string): Promise<void> {
  // The Mac writes an id in capitals and Go in small letters: the same session either way.
  const same = (a: { id: string }) => a.id.toLowerCase() === id.toLowerCase();
  for (const [host, agents] of Object.entries(store.agents.value)) {
    const agent = agents.find(same);
    if (agent) return go({ host, folder: folderPath(agent), session: agent.id });
  }
  for (const host of store.hosts.value) {
    const agent = await store.loadEventAgent(host.id, id);
    if (agent) return go({ host: host.id, folder: folderPath(agent), session: agent.id });
  }
}
