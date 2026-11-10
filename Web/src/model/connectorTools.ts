// The words for Allow, Ask or Off on a connector's tools (#4099), as the window's ConnectorToolWords.
import type { ConnectorToolLevel, MCPToolRow } from "../protocol/generated";

export const toolLevels: ConnectorToolLevel[] = ["allow", "ask", "off"];

export function toolLevelTitle(level: ConnectorToolLevel): string {
  switch (level) {
    case "allow": return "Allow";
    case "ask": return "Ask";
    case "off": return "Off";
  }
  return level;
}

/** What a level does, for its title. */
export function toolLevelHelp(level: ConnectorToolLevel): string {
  switch (level) {
    case "allow": return "Agents use it without asking.";
    case "ask": return "Agents ask you first.";
    case "off": return "Agents never use it.";
  }
  return "";
}

export const writesTitle = "Tools that write";
/** The switch's choice when the layer sets nothing for it. */
export const eachTool = "Each tool's own";
export const writesChip = "writes";
export const noTools = "It has no tools.";

/** Tighter is later: Allow, Ask, Off. An unknown level is Ask. */
export function toolLevelOrder(level: ConnectorToolLevel | undefined): number {
  const i = toolLevels.indexOf(level as ConnectorToolLevel);
  return i < 0 ? 1 : i;
}

/** The level a tool has with its own cleared: the switch for one that writes, else Ask for one that
 * writes and Allow for one that only reads, never looser than a cap. */
export function defaultToolLevel(row: MCPToolRow, writes: ConnectorToolLevel | undefined): ConnectorToolLevel {
  let level: ConnectorToolLevel = row.writes ? (writes ?? "ask") : "allow";
  if (row.cap && toolLevelOrder(row.cap) > toolLevelOrder(level)) level = row.cap;
  return level;
}

/** A tool's choice when the layer sets nothing for it, with what applies then. */
export function byDefault(level: ConnectorToolLevel): string {
  return `Default (${toolLevelTitle(level)})`;
}

/** Whether a row's cap line applies: its own level is looser than the layer above allows. */
export function capped(row: MCPToolRow): boolean {
  return row.own !== undefined && row.cap !== undefined && toolLevelOrder(row.own) < toolLevelOrder(row.cap);
}
