// Who is asking, at the head of a question or permission card (#121), as AgentsKitCore's
// AgentsModel.askerLine says it, so the page names the asker as the window and the Remote do.
import type { Agent } from "../protocol/generated";

const quoted = (text: string) => `“${text}”`;

/** "Asked by “#116 helper” (Claude), started by “Project lead”"; an untitled agent by its runtime. */
export function askerLine(title: string | undefined, runtime: string, startedBy?: string, subagent?: string): string {
  const named = title?.trim();
  let asker = named ? `${quoted(named)} (${runtime})` : runtime;
  if (subagent) asker = `subagent ${quoted(subagent)} of ${asker}`;
  return `Asked by ${asker}${startedBy ? `, ${startedBy}` : ""}`;
}

/** The line for one agent on a host: its starter by title, or "another agent" once it has none or has gone. */
export function askerFor(agents: Agent[], agentID: string, runtimeName: (id: string) => string | undefined,
  subagent?: string): string | null {
  const agent = agents.find((a) => a.id === agentID);
  if (!agent) return null;
  let startedBy: string | undefined;
  if (agent.startedByAgent) {
    const title = agents.find((a) => a.id === agent.startedByAgent)?.title?.trim();
    startedBy = `started by ${title ? quoted(title) : "another agent"}`;
  }
  return askerLine(agent.title, runtimeName(agent.runtimeID) ?? agent.runtimeID, startedBy, subagent);
}
