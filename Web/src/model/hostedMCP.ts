// The words for a hosted MCP server's row on the Resources page (#488), ported from
// HostedMCPWords in AgentsKitCore so the Mac, the Remote and the page say the same.
import type { HostedMCPStatus } from "../protocol/generated";
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
