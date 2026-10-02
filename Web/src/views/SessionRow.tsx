// One session in the sessions column, as the Mac's AgentRow draws it (071 FR-018): the status
// mark, the title, the agent's own last report, labels and the worktree, what runs in the
// background, and parking. Only Needs you is ever in colour.
import type { Agent } from "../protocol/generated";
import { backgroundMark } from "../model/background";
import { parkedAt, showsUnread } from "../model/groups";
import { rowStatus, type StatusShape } from "../model/status";
import { fromWireDate } from "../protocol/dates";
import { Telling } from "./Telling";
import { folderIsMissing, folderPath, missingFolderLabel } from "../model/missingFolder";

const glyphs: Record<StatusShape, string> = { working: "", needsYou: "!", waiting: "⧗", done: "✓", stopped: "■" };

/** The shape beside a title, with its words for the tooltip and a screen reader. */
export function StatusMark({ agent }: { agent: Agent }) {
  const status = rowStatus(agent);
  return (
    <span class={`status ${status.shape}${status.tinted ? " tinted" : ""}`} role="img" aria-label={status.words}
      title={status.words}>
      <span class="glyph" aria-hidden="true">{glyphs[status.shape]}</span>
    </span>
  );
}

const relative = new Intl.RelativeTimeFormat("en", { numeric: "always" });

/** "3 days ago", as Foundation's numeric, wide relative style says it. */
export function ago(date: Date, now = new Date()): string {
  const seconds = (date.getTime() - now.getTime()) / 1000;
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ["year", 31_536_000], ["month", 2_592_000], ["week", 604_800], ["day", 86_400], ["hour", 3_600], ["minute", 60],
  ];
  for (const [unit, size] of units) {
    if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
  }
  return relative.format(Math.round(seconds), "second");
}

/** ParkWords.line: "Parked 3 days ago", or "Parks when this turn ends". */
export function parkLine(agent: Agent): string | null {
  if (!agent.parking) return null;
  if ("whenTurnEnds" in agent.parking) return "Parks when this turn ends";
  const at = fromWireDate(parkedAt(agent)!);
  if (Date.now() - at.getTime() < 60_000) return "Parked just now";
  return "Parked " + ago(at);
}

/** "5m", "3h", "2d": when it last did anything, in the corner of the row. */
export function shortAgo(date: Date, now = new Date()): string {
  const minutes = Math.max(0, Math.floor((now.getTime() - date.getTime()) / 60_000));
  if (minutes < 1) return "now";
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

export function SessionRow({ agent, chosen, onPick, going }: {
  agent: Agent; chosen: boolean; onPick: () => void;
  /** Stop, park or archive on its way (#87): what it is doing, and to whom. */
  going?: { doing: string; recipient: string } | undefined;
}) {
  const running = backgroundMark(agent.background ?? []);
  const park = parkLine(agent);
  const activity = fromWireDate(agent.lastActivityAt);
  const labels = agent.labels ?? [];
  return (
    <button class={`row session${chosen ? " chosen" : ""}`} aria-current={chosen} onClick={onPick}>
      <StatusMark agent={agent} />
      <span class="body">
        {/* Unread is a mark, as in Mail (#70): a dot and a heavier title, gone once opened. */}
        <span class={`title${showsUnread(agent) ? " unread" : ""}`} aria-description={showsUnread(agent) ? "unread" : undefined}>
          {showsUnread(agent) && <span class="unread-dot" aria-hidden="true" />}{agent.title ?? "Untitled"}
        </span>
        {/* In the report's place, as the window's row has it (#87). */}
        {going ? <span class="subtitle"><Telling recipient={going.recipient} doing={going.doing} /></span>
          : agent.report && <span class="subtitle report">{agent.report.message}</span>}
        {/* Its folder gone (#119), as a project's row says it. */}
        {folderIsMissing(agent) && <span class="subtitle missing-folder" title={folderPath(agent)}>⚠ {missingFolderLabel}</span>}
        {(agent.worktree || labels.length > 0) && (
          <span class="chips">
            {agent.worktree && <span class={`chip worktree${folderIsMissing(agent) ? " gone" : ""}`} title={agent.worktree.branch ?? "detached"}>⑂ {agent.worktree.name}</span>}
            {labels.map((label) => <span key={label.value} class="chip label">{label.value}</span>)}
          </span>
        )}
        {running && <span class="subtitle">{running}</span>}
        {park && <span class="subtitle quiet">{park}</span>}
      </span>
      <time class="when" dateTime={activity.toISOString()} title={activity.toLocaleString()}>{shortAgo(activity)}</time>
    </button>
  );
}
