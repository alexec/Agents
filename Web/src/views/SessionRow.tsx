// One session in the sidebar, as the Mac's AgentRow draws it (071 FR-018, #251): the status
// mark (Coming back after a restart too), the title with who or what started it, the agent's own
// last report, labels and the worktree, what it holds or waits for, what runs in the background,
// what it waits on, and parking. Only Needs you is ever in colour.
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { eventWaitMark, leaseMark, startedByAgentLabel, worktreeHelp, type LeaseMark } from "../model/rowLines";
import { backgroundMark } from "../model/background";
import { parkedAt, projectFolder, showsUnread } from "../model/groups";
import { queuedLine, rowStatus, type StatusShape } from "../model/status";
import { fromWireDate } from "../protocol/dates";
import { Telling } from "./Telling";
import { folderIsMissing, folderPath, missingFolderLabel } from "../model/missingFolder";
import { shortAgo } from "../model/activity";
import { sessionMark, type SessionMark } from "../model/sidebar";

const glyphs: Record<StatusShape, string> = { working: "", needsYou: "!", waiting: "⧗", done: "✓", stopped: "■" };

/** The shape beside a title, with its words for the tooltip and a screen reader. */
export function StatusMark({ agent, comingBack = false }: { agent: Agent; comingBack?: boolean }) {
  const status = rowStatus(agent, comingBack);
  return (
    <span class={`status ${status.shape}${status.tinted ? " tinted" : ""}`} role="img" aria-label={status.words}
      title={status.words}>
      <span class="glyph" aria-hidden="true">{glyphs[status.shape]}</span>
    </span>
  );
}

const markWords: Record<SessionMark, string> = { needsYou: "Needs you", working: "Working", unread: "Unread", read: "Done" };

/**
 * A session's mark in the sidebar (#495, #499), the window's and the Remote's: an orange hand when
 * it needs the person, a spinner while it works, two rings when it finished unread, an empty ring
 * once read. Any other state keeps its status mark.
 */
export function SidebarMark({ agent, comingBack = false }: { agent: Agent; comingBack?: boolean }) {
  const mark = comingBack ? null : sessionMark(agent);
  if (!mark) return <StatusMark agent={agent} comingBack={comingBack} />;
  return (
    <span class={`sidebar-mark ${mark}`} role="img" aria-label={markWords[mark]} title={markWords[mark]}>
      {mark === "needsYou" && <span class="glyph" aria-hidden="true">✋&#xFE0E;</span>}
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

/** What a row says that its host's other state decides: who started it, its leases, its waits. */
export interface RowExtras {
  comingBack: boolean;
  startedByWorkflow: string | null;
  startedByAgent: string | null;
  leases: LeaseMark | null;
  eventWait: string | null;
  /** A queued helper's place in its project's queue (#362), "Queued, 2nd". */
  queued: string | null;
}

/** A row's extras, read from the store: only what this agent names is looked up. */
export function rowExtras(store: Store, host: string, agent: Agent): RowExtras {
  const title = (id: string) => store.agent(host, id)?.title;
  const workflowID = agent.startedByWorkflow;
  return {
    comingBack: store.isComingBack(host, agent.id),
    // Its id when the file has since gone, so the mark never goes with it, as the window's.
    startedByWorkflow: workflowID === undefined ? null
      : store.projectWorkflows(host, projectFolder(agent))
        .find((w) => w.workflow.workflowID === workflowID)?.workflow.name ?? workflowID,
    startedByAgent: startedByAgentLabel(agent, title),
    leases: leaseMark(agent.id, store.leases.value[host], title),
    eventWait: eventWaitMark(agent, title),
    queued: agent.state === "queued" ? queuedLine(agent, store.projectAgents(host, projectFolder(agent))) : null,
  };
}

export function SessionRow({ agent, chosen, onPick, going, waits = [], extras, inSidebar = false, place }: {
  agent: Agent; chosen: boolean; onPick: () => void;
  /** In the sidebar (#495): the state is the row's mark, unread among them, rather than a dot. */
  inSidebar?: boolean;
  /** Which project it is in, after the title: under a smart group, which gathers every project's. */
  place?: string | undefined;
  /** What the window's row says from beyond the agent's record (#251). */
  extras?: RowExtras | undefined;
  /** A blocked agent's wait lines (039, #157): blockLines over its host's agents. */
  waits?: string[];
  /** Stop, park or archive on its way (#87): what it is doing, and to whom. */
  going?: { doing: string; recipient: string } | undefined;
}) {
  const running = backgroundMark(agent.background ?? []);
  const park = parkLine(agent);
  const activity = fromWireDate(agent.lastActivityAt);
  const labels = agent.labels ?? [];
  return (
    <button class={`row session${chosen ? " chosen" : ""}`} aria-current={chosen} onClick={onPick}>
      {inSidebar ? <SidebarMark agent={agent} comingBack={extras?.comingBack ?? false} />
        : <StatusMark agent={agent} comingBack={extras?.comingBack ?? false} />}
      <span class="body">
        {/* Unread is a mark, as in Mail (#70): a dot (two rings in the sidebar) and a heavier title, gone once opened. */}
        <span class={`title${showsUnread(agent) ? " unread" : ""}`} aria-description={showsUnread(agent) ? "unread" : undefined}>
          {showsUnread(agent) && !inSidebar && <span class="unread-dot" aria-hidden="true" />}{agent.title ?? "Untitled"}
          {place && <span class="place"> {place}</span>}
          {/* Started by a workflow or another agent, not typed for by the person (028). */}
          {extras?.startedByWorkflow && (
            <span class="started-by" role="img" title={`Started by the workflow ${extras.startedByWorkflow}`}
              aria-label={`started by the workflow ${extras.startedByWorkflow}`}>↻</span>
          )}
          {extras?.startedByAgent && (
            <span class="started-by" role="img" title={extras.startedByAgent} aria-label={extras.startedByAgent}>⇆</span>
          )}
        </span>
        {/* In the report's place, as the window's row has it (#87). */}
        {going ? <span class="subtitle"><Telling recipient={going.recipient} doing={going.doing} /></span>
          : extras?.queued ? <span class="subtitle queued">{extras.queued}</span>
          : agent.report && <span class="subtitle report">{agent.report.message}</span>}
        {/* Its folder gone (#119), as a project's row says it. */}
        {folderIsMissing(agent) && <span class="subtitle missing-folder" title={folderPath(agent)}>⚠ {missingFolderLabel}</span>}
        {(agent.worktree || labels.length > 0) && (
          <span class="chips">
            {agent.worktree && <span class={`chip worktree${folderIsMissing(agent) ? " gone" : ""}`} title={worktreeHelp(agent.worktree, folderIsMissing(agent))}>⑂ {agent.worktree.name}</span>}
            {labels.map((label) => <span key={label.value} class="chip label">{label.value}</span>)}
          </span>
        )}
        {/* What it holds or waits for (036), so an idle agent still holding the screen can be seen. */}
        {extras?.leases && (
          <span class="subtitle lease-mark" role="note" aria-label={extras.leases.full} title={extras.leases.full}>
            {extras.leases.mark}{extras.leases.more > 0 && <span class="quiet"> · and {extras.leases.more} more</span>}
          </span>
        )}
        {running && <span class="subtitle">{running}</span>}
        {/* Waiting on events (042), then on agents, one line an agent (039, #152). */}
        {extras?.eventWait && <span class="subtitle wait-line">{extras.eventWait}</span>}
        {waits.map((line) => <span key={line} class="subtitle wait-line">{line}</span>)}
        {park && <span class="subtitle quiet">{park}</span>}
      </span>
      <time class="when" dateTime={activity.toISOString()} title={activity.toLocaleString()}>{shortAgo(activity)}</time>
    </button>
  );
}
