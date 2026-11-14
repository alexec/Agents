// A machine page's Agent Loops section (#5273, spec 5239 board 6): the words, the same as AgentsKit's
// AgentsVersionWords on the Mac and the Remote.
import type { AgentsChange, AgentsChanges, AgentsChangesRequest, MachineAgents, MachineAgentsOther, WireDate } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

/** The section's title: the product's name (#5297). */
export const agentsTitle = "Agent Loops";

/** The repo Agent Loops is built from, for a change's link. */
export const agentsRepo = "agentloops-dev/agent-loops";

/** What the section says when the machine has said no version yet. */
export const noVersion = "This machine has not said its version yet.";

/** A version as the page draws it: `0.18.1-dev.544`, then `+g8162a5a06` after it. */
export function versionParts(version: string): { name: string; build: string | null } {
  const plus = version.indexOf("+");
  return plus < 0 ? { name: version, build: null } : { name: version.slice(0, plus), build: version.slice(plus) };
}

/** A version without its build. */
export const shortVersion = (version: string) => versionParts(version).name;

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const two = (n: number) => String(n).padStart(2, "0");

/** `13 Nov, 15:22`, in this browser's zone. */
export function whenWords(at: WireDate): string {
  const d = fromWireDate(at);
  return `${d.getDate()} ${months[d.getMonth()]}, ${two(d.getHours())}:${two(d.getMinutes())}`;
}

/** `13 Nov`: a change's day. */
export function dayWords(at: WireDate): string {
  const d = fromWireDate(at);
  return `${d.getDate()} ${months[d.getMonth()]}`;
}

/** `1 change`, `544 changes`. */
export const changeCount = (n: number) => n === 1 ? "1 change" : `${n} changes`;

/** The line under the version: `since 13 Nov, 15:22 · 544 changes since 0.18.0, the version before`. */
export function sinceLine(agents: MachineAgents): string {
  const parts: string[] = [];
  if (agents.since !== undefined) parts.push(`since ${whenWords(agents.since)}`);
  if (agents.previous !== undefined) {
    parts.push(agents.changes
      ? `${changeCount(agents.changes.ahead)} since ${shortVersion(agents.previous)}, the version before`
      : `the version before was ${shortVersion(agents.previous)}; its changes can’t be read now`);
  }
  return parts.join(" · ");
}

/** The list's heading: `544 changes since 0.18.0 · newest first`. */
export const listHeading = (changes: AgentsChanges) => `${changeCount(changes.ahead)} since ${shortVersion(changes.base)} · newest first`;

/** `Show all 544`, or null when every change is shown. */
export const showAllWords = (changes: AgentsChanges) => changes.complete ? null : `Show all ${changes.ahead}`;

/** Another machine's second line: `0.18.0 · since 8 Nov, 11:02`. */
export const otherLine = (other: MachineAgentsOther) =>
  other.since === undefined ? shortVersion(other.version) : `${shortVersion(other.version)} · since ${whenWords(other.since)}`;

/** How far another machine is from this one, or null when it runs the same commit or GitHub could not say. */
export function behindLine(other: MachineAgentsOther): string | null {
  const { ahead, behind } = other;
  if (ahead === undefined || behind === undefined || (ahead === 0 && behind === 0)) return null;
  if (ahead === 0) return `${changeCount(behind)} behind this one`;
  if (behind === 0) return `${changeCount(ahead)} ahead of this one`;
  return `${ahead} ahead of and ${behind} behind this one`;
}

/** Whether another machine is behind, so its line is in the warning tint. */
export const isBehind = (other: MachineAgentsOther) => (other.behind ?? 0) > 0;

/** The compare another machine's line opens: what this one has that it has not, else what it has that this one has not. */
export const compareWith = (other: MachineAgentsOther, version: string, limit?: number): AgentsChangesRequest => {
  const pair = (other.behind ?? 0) > 0 ? { base: other.version, head: version } : { base: version, head: other.version };
  return limit === undefined ? pair : { ...pair, limit };
};

/** How many changes a list shows before its Show all, as the control plane's page answer. */
export const changesShown = 6;

/** A change's link: its PR, else its commit. */
const github = "https://github.com/";
export const changeLink = (change: AgentsChange) =>
  github + agentsRepo + (change.number !== undefined ? `/pull/${change.number}` : `/commit/${change.sha}`);

/** A change's label before its title: `#5250`, or the commit's first 7. */
export const changeLabel = (change: AgentsChange) => change.number !== undefined ? `#${change.number}` : change.sha.slice(0, 7);
