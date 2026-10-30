// One session in the sidebar, as the Mac's AgentRow draws it (071 FR-018, #251): the status
// mark (Coming back after a restart too), the title with who or what started it, the agent's own
// last report, labels and the worktree, what it holds or waits for, what runs in the background,
// what it waits on, and whether an agent asks for it to be archived. Only Needs you is ever in
// colour. In the sidebar it is the mark, the title, the time and one grey line (#587): the rest is
// the folder page's and the chat's.
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { leaseMark, lineResource, startedByAgentLabel, waitMark, worktreeHelp, type LeaseMark, type WaitMark } from "../model/rowLines";
import { blockWaitNames, openBlock } from "../model/block";
import { backgroundMark } from "../model/background";
import { drawsUnread, folderPath } from "../model/groups";
import { archiveLine, archiveMark } from "../model/archiveWords";
import { fileToSeeLine, reportLine } from "../model/fileToSeeWords";
import { needsYouLine, queuedLine, rowStatus, type StatusShape } from "../model/status";
import { fromWireDate } from "../protocol/dates";
import { Telling } from "./Telling";
import { folderIsMissing, folderPath as missingFolderPath, missingFolderLabel } from "../model/missingFolder";
import { shortAgo } from "../model/activity";
import { labelKind } from "../model/labels";
import { runningTool, runningToolLabel, sessionMark, type SessionMark } from "../model/sidebar";
import { isMuted, muteMark, mutedHelp, mutedWords } from "../model/mute";
import { callLine } from "../model/turns";

const glyphs: Record<StatusShape, string> = { working: "", needsYou: "!", waiting: "", done: "✓", stopped: "■" };

/** The shape beside a title, with its words for the tooltip and a screen reader. */
export function StatusMark({ agent, comingBack = false }: { agent: Agent; comingBack?: boolean }) {
  const status = rowStatus(agent, comingBack);
  return (
    <span class={`status ${status.shape}${status.tinted ? " tinted" : ""}`} role="img" aria-label={status.words}
      title={status.words}>
      {status.shape === "working" && <WorkingMark tool={runningTool(agent)} />}
      {status.shape === "waiting" && <WaitingMark />}
      {status.shape !== "working" && status.shape !== "waiting"
        && <span class="glyph" aria-hidden="true">{glyphs[status.shape]}</span>}
    </span>
  );
}

const markWords: Record<SessionMark, string> = { needsYou: "Needs you", working: "Working", tool: "Running a tool", queued: "Queued", waiting: "Waiting", paused: "Paused", done: "Done",
  asksToArchive: archiveMark };

/**
 * A session's mark in the sidebar (#495, #499), the window's and the Remote's: an orange hand when
 * it needs the person, the working ring while it thinks, tipping while it runs a tool (#2332), a numbered list while queued, a breathing beacon while it waits (#2456, #2657), a pause mark once
 * stopped (#630), a tick once done, read or not (#1323, #2363). Archived keeps its
 * status mark.
 */
export function SidebarMark({ agent, comingBack = false }: { agent: Agent; comingBack?: boolean }) {
  if (agent.state === "archived") {
    return <span class="sidebar-mark archived" role="img" aria-label="Archived" title="Archived">▣</span>;
  }
  const status = rowStatus(agent, comingBack);
  const mark = comingBack ? null : sessionMark(agent);
  if (!mark) return <StatusMark agent={agent} comingBack={comingBack} />;
  const tool = mark === "tool" ? runningTool(agent) : null;
  const words = tool !== null ? runningToolLabel(tool) : mark === "needsYou" ? status.words : markWords[mark];
  return (
    <span class={`sidebar-mark ${mark}`} role="img" aria-label={words} title={words}>
      {mark === "needsYou" && <span class="glyph" aria-hidden="true">✋&#xFE0E;</span>}
      {(mark === "working" || mark === "tool") && <WorkingMark tool={tool} />}
      {mark === "queued" && <span class="glyph" aria-hidden="true">≡</span>}
      {mark === "waiting" && <WaitingMark />}
      {mark === "paused" && <span class="glyph" aria-hidden="true">⏸&#xFE0E;</span>}
      {mark === "done" && <span class="glyph" aria-hidden="true">✓&#xFE0E;</span>}
      {mark === "asksToArchive" && <span class="glyph" aria-hidden="true">🗃&#xFE0E;</span>}
    </span>
  );
}

/**
 * A working session's mark (#2044, #2332), the window's `WorkingRing`: three dots on a ring seen
 * edge on, spinning while it thinks or replies, and pivoting as well while it runs a tool. One
 * element for both, so a tool changes the keyframes on the same dots. In step on the page
 * (spinnerClock.ts), in the colour around it.
 */
export function WorkingMark({ tool }: { tool: string | null }) {
  return <span class={tool !== null ? "working-ring doing" : "working-ring"} aria-hidden="true"><i /><i /><i /></span>;
}

/**
 * The beacon (#2657), the SF Symbol `dot.radiowaves.left.and.right` the window and the Remote draw
 * for waiting: a dot with two arcs on each side, in the colour around it. The waiting mark and the
 * waiting card's icon (`Chat.tsx`), so one icon says waiting everywhere.
 */
export function Beacon() {
  return (
    <svg class="beacon" viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="2.4" />
      <path d="M15.5 7.8A5.5 5.5 0 0 1 15.5 16.2M8.5 16.2A5.5 5.5 0 0 1 8.5 7.8M18.1 4.7A9.5 9.5 0 0 1 18.1 19.3M5.9 19.3A9.5 9.5 0 0 1 5.9 4.7" />
    </svg>
  );
}

/**
 * A waiting session's mark (#2456, #2657), the window's `WaitingBeacon`: the beacon, breathing
 * between dim and full once in 4 s, in step on the page (spinnerClock.ts) and slower under Reduce
 * Motion. In the colour around it: the accent, where the unread dot is grey, round and still.
 */
export function WaitingMark() {
  return <span class="waiting-beacon" aria-hidden="true"><Beacon /></span>;
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

/** What a row says that its host's other state decides: who started it, its leases, its waits. */
export interface RowExtras {
  comingBack: boolean;
  startedByWorkflow: string | null;
  startedByAgent: string | null;
  leases: LeaseMark | null;
  /** What it waits for, on one line (#582): its block, its wait on events, the resources it is in line for. */
  wait: WaitMark | null;
  /** A queued helper's place in its folder's queue (#362), "Queued, 2nd". */
  queued: string | null;
  /** While the sidebar searches: the line it said that matches (#1585). */
  said?: string | null;
  /** The first question this session is waiting for an answer to (#1324). */
  question?: string | null;
}

/** A row's extras, read from the store: only what this agent names is looked up. */
export function rowExtras(store: Store, host: string, agent: Agent): RowExtras {
  const title = (id: string) => store.agent(host, id)?.title;
  const workflowID = agent.startedByWorkflow;
  const snapshot = store.leases.value[host];
  // A place in line that its wait says is said once, by the wait (#2361).
  const leases = leaseMark(agent.id, snapshot, title, lineResource(agent));
  const permission = store.permissionsFor(host, agent.id)[0];
  const elicitation = store.elicitationsFor(host, agent.id)[0];
  const question = permission ? callLine(permission.toolCall)
    : elicitation?.message ?? (elicitation && ("form" in elicitation.mode
      ? elicitation.mode.form._0.title : elicitation.mode.url._0));
  return {
    comingBack: store.isComingBack(host, agent.id),
    // Its id when the file has since gone, so the mark never goes with it, as the window's.
    startedByWorkflow: workflowID === undefined ? null
      : store.folderWorkflows(host, folderPath(agent))
        .find((w) => w.workflow.workflowID === workflowID)?.workflow.name ?? workflowID,
    startedByAgent: startedByAgentLabel(agent, title),
    leases,
    wait: waitMark(agent, openBlock(agent)
      ? { names: blockWaitNames(agent, store.agents.value[host] ?? []), lines: store.waitsOf(host, agent) }
      : { names: [], lines: [] }, leases, title, snapshot),
    queued: agent.state === "queued" ? queuedLine(agent, store.folderAgents(host, folderPath(agent))) : null,
    said: store.saidLines.value[agent.id] ?? null,
    question: question ?? null,
  };
}

export function SessionRow({ agent, chosen, onPick, going, extras, inSidebar = false, place, markAgent }: {
  agent: Agent; chosen: boolean; onPick: () => void;
  /** A folded parent's: the most urgent of it and the sessions it started, whose mark it shows (#835). */
  markAgent?: Agent | undefined;
  /**
   * In the sidebar (#495): the state is the row's mark, unread among them, rather than a dot, and
   * the row is its title, time and one grey line (#587).
   */
  inSidebar?: boolean;
  /** Which folder it is in, after the title: under a smart group, which gathers every folder's. */
  place?: string | undefined;
  /** What the window's row says from beyond the agent's record (#251). */
  extras?: RowExtras | undefined;
  /** Stop or archive on its way (#87): what it is doing, and to whom. */
  going?: { doing: string; recipient: string } | undefined;
}) {
  const running = backgroundMark(agent.background ?? []);
  // The mark alone: the row is a button, so Archive is the menu's and the strip's, Keep Session the menu's (#584, #773).
  const asks = archiveLine(agent);
  const fileToSee = fileToSeeLine(agent);
  const report = reportLine(agent);
  const reason = needsYouLine(agent, extras?.question, extras?.comingBack);
  const activity = fromWireDate(agent.lastActivityAt);
  const labels = agent.labels ?? [];
  return (
    <button class={`row session${chosen ? " chosen" : ""}`} aria-current={chosen} onClick={onPick}>
      {inSidebar ? <SidebarMark agent={markAgent ?? agent} comingBack={extras?.comingBack ?? false} />
        : <StatusMark agent={agent} comingBack={extras?.comingBack ?? false} />}
      <span class="body">
        {/* Unread is a mark, as in Mail (#70): a dot (two rings in the sidebar) and a heavier title, gone once opened. */}
        <span class={`title${drawsUnread(agent) ? " unread" : ""}${place ? " placed" : ""}`} aria-description={drawsUnread(agent) ? "unread" : undefined}>
          {drawsUnread(agent) && !inSidebar && <span class="unread-dot" aria-hidden="true" />}
          {/* The title gives way before its folder's name, which is whole (#587). */}
          {place ? <span class="name">{agent.title ?? "Untitled"}</span> : agent.title ?? "Untitled"}
          {place && <span class="place"> {place}</span>}
          {/* Started by a workflow or another agent, not typed for by the person (028). */}
          {extras?.startedByWorkflow && (
            <span class="started-by" role="img" title={`Started by the workflow ${extras.startedByWorkflow}`}
              aria-label={`started by the workflow ${extras.startedByWorkflow}`}>⧉</span>
          )}
          {extras?.startedByAgent && (
            <span class="started-by" role="img" title={extras.startedByAgent} aria-label={extras.startedByAgent}>⇆</span>
          )}
          {/* Mute Notifications (#2003): a bell with a slash, as the window's row has it. */}
          {isMuted(agent) && <span class="started-by muted" role="img" title={mutedHelp} aria-label={mutedWords}>{muteMark}</span>}
          {/* A file it showed that the person has not looked at (#1802): a mark, never Needs you. */}
          {fileToSee && <span class="started-by file-to-see" role="img" title={fileToSee} aria-label={fileToSee}>🗎&#xFE0E;</span>}
        </span>
        {/* In the report's place, as the window's row has it (#87). */}
        {going ? <span class="subtitle"><Telling recipient={going.recipient} doing={going.doing} /></span>
          : extras?.queued ? <span class="subtitle queued">{extras.queued}</span>
          // While the sidebar searches: the line it said that matches, in the report's place,
          // so a row found by what it said says why (#1663). The page's row has it below.
          : inSidebar && reason ? <span class="subtitle needs-you-reason">{reason}</span>
          : inSidebar && extras?.said && !folderIsMissing(agent) ? <span class="subtitle said" title={extras.said}>{extras.said}</span>
          : report && !(inSidebar && folderIsMissing(agent)) && <span class="subtitle report">{report}</span>}
        {/* Its folder gone (#119), as a folder's row says it. */}
        {folderIsMissing(agent) && <span class="subtitle missing-folder" title={missingFolderPath(agent)}>⚠ {missingFolderLabel}</span>}
        {/* In the sidebar, that one line is all (#587): what it holds, waits on, runs or is
            labelled with is the chat's to say. */}
        {!inSidebar && <>
          {(agent.worktree || labels.length > 0) && (
            <span class="chips">
              {agent.worktree && <span class={`chip worktree${folderIsMissing(agent) ? " gone" : ""}`} title={worktreeHelp(agent.worktree, folderIsMissing(agent))}>⑂ {agent.worktree.name}</span>}
              {labels.map((label) => <span key={label.value} class={`chip label ${labelKind(label.value)}`}>{label.value}</span>)}
            </span>
          )}
          {/* What it holds (036), so an idle agent still holding the screen can be seen. What it waits for is the wait line's. */}
          {extras?.leases?.holds && (
            <span class="subtitle lease-mark" role="note" aria-label={extras.leases.holds.full} title={extras.leases.holds.full}>
              {extras.leases.holds.mark}{extras.leases.holds.more > 0 && <span class="quiet"> · and {extras.leases.holds.more} more</span>}
            </span>
          )}
          {running && <span class="subtitle">{running}</span>}
          {/* What it waits for (#582): agents, events and resources on one line; each in full is its title, and the chat's. */}
          {extras?.wait && <span class="subtitle wait-line" title={extras.wait.detail}>{extras.wait.line}</span>}
          {/* While the sidebar searches: the line it said that matches (#1585). */}
          {extras?.said && <span class="subtitle" title={extras.said}>{extras.said}</span>}
          {asks && <span class="subtitle quiet archive-mark">{asks}</span>}
        </>}
      </span>
      <time class="when" dateTime={activity.toISOString()} title={activity.toLocaleString()}>{shortAgo(activity)}</time>
    </button>
  );
}
