// The words for an MCP server's row on the MCP Servers pages (#488, #589, #753), ported from
// HostedMCPWords and MCPHealthWords in AgentsKitCore so the Mac, the Remote and the page say the same.
import type { HostedMCPStatus, MCPHealthSnapshot, MCPLevels, MCPServerHealth } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

/** "14:05", twenty-four hours, as LeaseWords.clock says it. */
function clock(at: number): string {
  const date = fromWireDate(at as never);
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

/** Whose file names it: the project's folder name, or the person's own. */
export function hostedPlace(status: HostedMCPStatus): string {
  if (status.project == null) return "Your own (~/.agents/mcp.json)";
  const name = status.project.replace(/\/+$/, "").split("/").pop() ?? "";
  return name || status.project;
}

/** What it is doing, in a line. */
export function hostedLine(status: HostedMCPStatus): string {
  const using = status.users === 1 ? "1 using it" : `${status.users} using it`;
  switch (status.state) {
    case "running":
      return `${status.since != null ? `Running since ${clock(status.since)}` : "Running"} · ${using}`;
    case "starting":
      return "Starting…";
    case "restarting": {
      const when = status.retryAt != null ? ` at ${clock(status.retryAt)}` : "";
      const times = status.restarts === 1 ? "once" : `${status.restarts} times`;
      return `Stopped; starting again${when}` + (status.restarts > 0 ? ` · restarted ${times}` : "");
    }
    case "idle":
      return status.users > 0 ? "Idle · starts on the next call" : "Idle · nothing uses it";
  }
}

/** Why it last stopped, when it has: shown under the line. */
export function hostedLastError(status: HostedMCPStatus): string | undefined {
  if (!status.lastError) return undefined;
  return status.state === "restarting" ? status.lastError : `Last stopped: ${status.lastError}`;
}

/** The Activity row's count: how many run, or how many stopped while in use, which is the one
 * worth a red dot. Null with none hosted. As HostedMCPWords.tally. */
export function hostedTally(servers: HostedMCPStatus[]): { words: string; stopped: boolean } | null {
  if (servers.length === 0) return null;
  const stopped = servers.filter((s) => s.state === "restarting").length;
  if (stopped > 0) return { words: `${stopped} stopped`, stopped: true };
  return { words: `${servers.filter((s) => s.state === "running").length} running`, stopped: false };
}

// Every server in one mcp.json and how each is doing (#753), ported from MCPHealthWords in
// AgentsKitCore so the Mac, the Remote and the page say the same.

export type MCPTone = "good" | "failing" | "quiet";

/** A folder URL, or a path, as the path the host writes in MCPServerHealth.project. */
export function projectPath(folder: string): string {
  if (!folder.startsWith("file:")) return folder.replace(/\/+$/, "");
  try {
    return decodeURIComponent(new URL(folder).pathname).replace(/\/+$/, "");
  } catch {
    return folder;
  }
}

/** The person's own servers, for Activity. */
export function personalServers(snapshot: MCPHealthSnapshot | undefined): MCPServerHealth[] {
  return (snapshot?.servers ?? []).filter((s) => s.project == null);
}

/** One project's, for its page in the sidebar; `folder` as the host writes the project's. */
export function projectServers(snapshot: MCPHealthSnapshot | undefined, folder: string): MCPServerHealth[] {
  const path = projectPath(folder);
  return (snapshot?.servers ?? []).filter((s) => s.project != null && projectPath(s.project) === path);
}

/** Why one file could not be read: the person's (no folder) or a project's. */
export function fileProblem(snapshot: MCPHealthSnapshot | undefined, folder?: string): string | undefined {
  const path = folder === undefined ? undefined : projectPath(folder);
  return snapshot?.problems.find((p) => (p.project == null ? undefined : projectPath(p.project)) === path)?.message;
}

/** How it runs, beside its name. */
export function healthKind(server: MCPServerHealth): string {
  switch (server.transport) {
    case "stdio": return server.hosted ? "stdio · hosted" : "stdio · run in each session";
    case "http": return "http";
    case "sse": return "sse";
  }
}

/** How it is doing, in a line. */
export function healthLine(server: MCPServerHealth): string {
  if (server.hosted) return server.live ? hostedLine(server.live) : "Hosted · starts on the first call";
  const checked = server.checkedAt != null ? ` · checked ${clock(server.checkedAt)}` : "";
  switch (server.check) {
    case "unchecked": return "Not checked yet";
    case "checking": return "Checking…";
    case "answered": {
      const tools = server.tools == null ? "" : server.tools === 1 ? " · 1 tool" : ` · ${server.tools} tools`;
      return "Answered" + tools + checked;
    }
    case "failed": return "Didn't answer" + checked;
    case "waiting": return "Waiting for approval in this project's settings, so it is not started";
    case "missingSecret": return "Needs a secret that isn't set here, so it is not started";
    case "signIn": return "Wants a sign-in first, in Settings";
    case "oldTransport": return "Uses the old sse transport, which isn't checked";
  }
}

/** Why it last failed, when it has: shown under the line. */
export function healthLastError(server: MCPServerHealth): string | undefined {
  if (server.hosted) return server.live ? hostedLastError(server.live) : undefined;
  return server.check === "failed" && server.lastError ? server.lastError : undefined;
}

export function healthTone(server: MCPServerHealth): MCPTone {
  if (server.hosted) {
    switch (server.live?.state) {
      case "running": case "starting": return "good";
      case "restarting": return "failing";
      default: return "quiet";
    }
  }
  return server.check === "answered" ? "good" : server.check === "failed" ? "failing" : "quiet";
}

/** The sidebar row's count: how many do not answer, the one worth a red icon, or how many there
 * are. Null with none. As MCPHealthWords.tally. */
export function healthTally(servers: MCPServerHealth[]): { words: string; failing: boolean } | null {
  if (servers.length === 0) return null;
  const failing = servers.filter((s) => healthTone(s) === "failing").length;
  if (failing > 0) return { words: `${failing} not answering`, failing: true };
  return { words: servers.length === 1 ? "1 connector" : `${servers.length} connectors`, failing: false };
}

/** The five levels in order (#1428), each with whether it is reached, as `MCPHealthWords.levels`. */
export function connectorLevels(levels: MCPLevels | undefined): { name: string; reached: boolean }[] {
  return [
    { name: "Tools", reached: levels?.tools ?? false },
    { name: "Events", reached: levels?.events ?? false },
    { name: "Views", reached: levels?.views ?? false },
    { name: "Workflows", reached: levels?.workflows ?? false },
    { name: "Tested", reached: levels?.tested ?? false },
  ];
}

/** The levels as a sentence, for a screen reader and the tooltip, as `MCPHealthWords.levelsSentence`. */
export function levelsSentence(levels: MCPLevels | undefined): string {
  if (!levels) return "Its levels show once its machine has checked it.";
  const each = connectorLevels(levels);
  const reached = each.filter((l) => l.reached).map((l) => l.name);
  const not = each.filter((l) => !l.reached).map((l) => l.name);
  if (not.length === 0) return "Reaches all five levels.";
  if (reached.length === 0) return "Reaches none of the five levels yet.";
  return `Reaches ${reached.join(", ")}. Not yet ${not.join(", ")}.`;
}

/** The mark on the connectors that Agents makes (#1428). */
export const madeByAgents = "Made by Agents";

export const personalIntro = "Every connector in your own ~/.agents/mcp.json, which every agent has. "
  + "A hosted one runs once on this machine; any other is checked every four hours, and when its entry changes. "
  + "Edit them in the Mac's Settings ▸ Agent Configuration ▸ Connectors.";
export const projectIntro = "Every connector in this project's .agents/mcp.json. "
  + "A hosted one runs once on its machine; any other is checked every four hours, and when its entry changes. "
  + "Edit them in the project's settings.";
export const personalEmpty = "No connectors in ~/.agents/mcp.json yet.";
export const projectEmpty = "No connectors in this project's .agents/mcp.json yet.";
