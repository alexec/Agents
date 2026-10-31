// One turn of the chat, with its steps (069, #1315, #2170), and every kind of line in it, as the
// shared TranscriptRows.swift draws them for the Mac and the phone (071 FR-023). Words come from
// the ported rules; agent text goes through the Markdown renderer and nowhere else.
import { useSignal } from "@preact/signals";
import { hostNeedsUpdate } from "../../model/capabilities";
import { createContext } from "preact";
import { useContext, useEffect, useRef } from "preact/hooks";
import type {
  AgentState, BackgroundItem, ContentBlock, EndedReason, FileReading, JSONValue, Plan, ToolCall, ToolCallContent, ToolCallLocation,
  PolicySetBy, SandboxFailureRecord, TranscriptEntry, WorkReport,
} from "../../protocol/generated";
import { lineDiff } from "../../model/diff";
import { Lines } from "../Changes";
import { backgroundEntryLine } from "../../model/background";
import { outcomeNeedsAPerson } from "../../model/groups";
import { outcomeHeadings, queuedLabel, startingLabel } from "../../model/status";
import {
  callLine, compactionLine, copiedText, drawnInTurn, fields, isSummaryOnly, kindOf, thoughtLine, turnLine, turnParts, type ChatTurn, type Item,
} from "../../model/turns";
import { fileLinkPath, Markdown } from "../../render/markdown";
import { AppView } from "./AppView";
import { FileCard } from "./FileCard";
import { noticeClock, noticeOutcome } from "../../model/notified";
import { fromWireDate } from "../../protocol/dates";
import type { Shown } from "../../model/shownFile";
import { continueWithout, keepStopped, sandboxCard } from "../../model/sandboxWords";
import { OrgPolicyLine } from "../OrgPolicyLine";
import { memo } from "../../render/memo";

/** The text of a message's blocks: text blocks as Markdown, anything else named. */
export function Blocks({ blocks, text }: { blocks: ContentBlock[] | undefined; text: string }) {
  // A file a message links to opens in Files, as a file a call touched does (#548).
  const openFile = useContext(CallActionsContext)?.open;
  if (!blocks?.length) return <Markdown text={text} openFile={openFile} />;
  return (
    <>
      {blocks.map((block, index) => {
        if (block.type === "text") return <Markdown key={index} text={block.text} openFile={openFile} />;
        if (block.type === "resource_link") {
          const path = openFile ? fileLinkPath(block.uri) : null;
          return path && openFile
            ? <p key={index} class="attachment">📎 <button class="link reading" title={path} onClick={() => openFile({ path })}>{block.name}</button></p>
            : <p key={index} class="attachment">📎 {block.name}</p>;
        }
        if (block.type === "resource") return <p key={index} class="attachment">📎 {block.resource.uri.split("/").pop()}</p>;
        // Drawn from its own bytes, as ChatBlocks does; a remote address stays unloaded (071 FR-030).
        if (block.type === "image") {
          return block.data && /^image\/[a-z0-9.+-]+$/i.test(block.mimeType) ? <img key={index} class="message-image" alt="Image" src={`data:${block.mimeType};base64,${block.data}`} />
            : <p key={index} class="attachment">[image]</p>;
        }
        return null;
      })}
    </>
  );
}

const stopWords: Partial<Record<EndedReason, string>> = {
  cancelled: "You stopped it",
  stoppedByAgent: "The agent that started it stopped it",
  stoppedByAdmin: "An admin stopped it in the Console",
  processDied: "The runtime crashed",
  signInRefused: "Its sign-in was refused",
  runtimeError: "The runtime reported an error",
  allowanceSpent: "Its allowance ran out",
  rateLimited: "Rate limited, and still limited after retrying",
  daemonGone: "Stopped when the daemon did",
  maxTokens: "Ran out of room",
  maxTurnRequests: "Hit its limit",
  refusal: "Refused to carry on",
  unrecognised: "Stopped for a reason we do not know",
  costLimit: "Reached its cost limit",
  sandboxFailed: "Its sandbox could not start",
  imported: "Imported from another set-up, so not run here",
};

/** StateLine's words. */
function stateWords(state: AgentState, reason: EndedReason | undefined): string {
  switch (state) {
    case "running": return "Working";
    case "starting": return startingLabel;
    case "waitingOnUser": return "Waiting on you";
    case "finished": return "Finished";
    case "stopped": return (reason && stopWords[reason]) ?? "Stopped";
    case "archived": return "Archived";
    case "queued": return queuedLabel(null);
  }
}

function pretty(value: JSONValue): string {
  // A list of bytes, the way some runtimes send a tool's output, read as text.
  if (Array.isArray(value) && value.length && value.every((v) => typeof v === "number" && v >= 0 && v <= 255 && Number.isInteger(v))) {
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(value as number[]));
    } catch { /* not text: drawn as it came */ }
  }
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

/** ChatBlocks' PlanView: a withdrawn plan is struck through, and says the agent dropped it (#252). */
export function PlanView({ plan }: { plan: Plan }) {
  const marks = { pending: "○", in_progress: "◐", completed: "●" } as const;
  const spoken = { pending: "To do", in_progress: "Doing now", completed: "Done" } as const;
  const withdrawn = plan.state === "withdrawn";
  return (
    <div class={`plan-block${withdrawn ? " withdrawn" : ""}`}>
      <ul class="plan" aria-label="Plan">
        {plan.entries.map((entry, index) => (
          <li key={index} class={entry.status} aria-label={`${withdrawn ? "Dropped" : spoken[entry.status]}: ${entry.content}`}>
            <span class="mark" aria-hidden="true">{marks[entry.status]}</span> <span class="content">{entry.content}</span>
          </li>
        ))}
      </ul>
      {withdrawn && <p class="quiet dropped">The agent dropped this plan</p>}
    </div>
  );
}

function ReportLine({ report }: { report: WorkReport }) {
  return (
    <div class="note report">
      <p class={`heading${outcomeNeedsAPerson(report.outcome) ? " tinted" : ""}`}>{outcomeHeadings[report.outcome]}</p>
      <p class="quiet">{report.message}</p>
    </div>
  );
}

/**
 * What a call's detail needs from the page (the window's ChatActions): open a file it touched in
 * the Files pane, and show an edit among the agent's changes. Nothing is offered without them.
 */
export interface CallActions {
  open: (location: ToolCallLocation) => void;
  showEdit: (diff: Extract<ToolCallContent, { type: "diff" }>, toolCallID: string | undefined) => void;
  /** The sandbox failure the open agent waits on an answer to (Agent.pendingSandboxFailure, #253). */
  waitingSandbox?: SandboxFailureRecord | undefined;
  /** The organisation's mark while its policy requires the sandbox (#998): no Continue without sandbox. */
  sandboxSetBy?: PolicySetBy | undefined;
  answerSandbox?: ((carryOn: boolean) => Promise<void>) | undefined;
  /** Open a subagent's own steps (ChatActions.subagentSteps, #544). */
  subagentSteps?: ((item: BackgroundItem) => void) | undefined;
  /** Open a file a card shows in Files at its line (ChatActions.showFile, #836). */
  showFile?: ((file: Shown) => void) | undefined;
  /** Hold a card's chart hint, for the pane to draw its CSV with (#836). */
  noteChart?: ((file: Shown) => void) | undefined;
  /** Read a file for a card's preview (ChatActions.readFile, #836). */
  readFile?: ((path: string) => Promise<FileReading>) | undefined;
  /** Quote in Prompt (ChatActions.quote, #1553): words from a reply, into the prompt bar as a quote. */
  quote?: ((words: string) => void) | undefined;
  /** Branch from Here (#1658): a new session from just before the person's prompt `entryID`. Not on an archived session. */
  branchFrom?: ((entryID: string, text: string) => void) | undefined;
  /** The host is too old to branch (#1748): Branch from Here stays, greyed, and says so (#1866). */
  branchNeedsUpdate?: boolean | undefined;
}
export const CallActionsContext = createContext<CallActions | null>(null);

/** An edit (DiffView): its path at the fine step, then its lines marked + and −, in a well. */
export function EditDiff({ diff }: { diff: Extract<ToolCallContent, { type: "diff" }> }) {
  return (
    <div class="call-diff">
      <p class="path faint small" title={diff.path}><bdi>{diff.path}</bdi></p>
      <Lines lines={lineDiff(diff.oldText, diff.newText)} />
    </div>
  );
}

/** One tool call: its line, and what it did once asked (ToolCallLine). Gone to from elsewhere, opened (#1315). */
export function ToolCallLine({ call, text, focused = false, background, onClick }: {
  call: ToolCall; text?: string; focused?: boolean; background: readonly BackgroundItem[]; onClick?: () => void;
}) {
  const expanded = useSignal(false);
  useEffect(() => {
    if (focused) expanded.value = true;
  }, [focused]);
  const actions = useContext(CallActionsContext);
  const runsOn = call.toolCallID !== undefined
    && background.some((item) => item.toolCallID === call.toolCallID && (item.state === "running" || item.state === "paused"))
    ? " · running in the background" : "";
  const hasDetail = (call.content ?? []).length > 0 || (call.locations ?? []).length > 0
    || call.rawInput !== undefined || call.rawOutput !== undefined;
  const words = (text ?? callLine(call)) + runsOn;
  const showsDetail = expanded.value;
  return (
    <div class="call">
      {onClick || hasDetail ? (
        <button class="call-line" aria-expanded={onClick ? undefined : showsDetail}
          title={onClick ? "Show the whole run" : showsDetail ? "Hide the argument and the return" : "Show the argument and the return"}
          onClick={onClick ?? (() => (expanded.value = !expanded.value))}>
          {words}
        </button>
      ) : <p class="call-line">{words}</p>}
      {showsDetail && !onClick && (
        <div class="call-detail">
          {(call.content ?? []).map((piece, index) => {
            if (piece.type === "diff") {
              // A link under the edit rather than the edit as a button: the lines stay
              // selectable, and the way in is said in words.
              return (
                <div key={index} class="edit">
                  <EditDiff diff={piece} />
                  {actions && (
                    <button class="link reading" title="See this edit among everything the agent changed"
                      onClick={() => actions.showEdit(piece, call.toolCallID)}>Show in Changes</button>
                  )}
                </div>
              );
            }
            if (piece.type === "content" && piece.content.type === "text") return <Markdown key={index} text={piece.content.text} openFile={actions?.open} />;
            // Any other block as a message draws it: a picture, an attachment (#252).
            if (piece.type === "content") return <div key={index} class="quiet"><Blocks blocks={[piece.content]} text="" /></div>;
            if (piece.type === "terminal") return <p key={index} class="quiet">Terminal output is shown in the Mac window.</p>;
            // Kept rather than dropped: what the runtime sent, as the window shows it.
            return <pre key={index} class="raw faint">{pretty(piece as unknown as JSONValue).split("\n").slice(0, 6).join("\n")}</pre>;
          })}
          {/* Where it did its work, each a way in, wrapped: file names are long. */}
          {(call.locations ?? []).length > 0 && (
            <p class="locations">
              {(call.locations ?? []).map((l, i) => {
                const words = `${l.path.split("/").pop()}${l.line ? `:${l.line}` : ""}`;
                return actions
                  ? <button key={i} class="link reading" aria-label={`Open ${l.path.split("/").pop()}`} title={l.path}
                    onClick={() => actions.open(l)}>{words}</button>
                  : <span key={i}>{words}</span>;
              })}
            </p>
          )}
          {call.rawInput !== undefined && <div><p class="faint">Argument</p><pre>{pretty(call.rawInput)}</pre></div>}
          {call.rawOutput !== undefined && <div><p class="faint">Return</p><pre>{pretty(call.rawOutput)}</pre></div>}
        </div>
      )}
    </div>
  );
}

/** A run of tool calls: the latest line, the rest behind a click (ToolRunRow). */
function ToolRun({ calls, background }: { calls: ToolCall[]; background: readonly BackgroundItem[] }) {
  const expanded = useSignal(false);
  if (expanded.value || calls.length === 1) {
    return <div class="run">{calls.map((call, i) => <ToolCallLine key={i} call={call} background={background} />)}</div>;
  }
  return <div class="run"><ToolCallLine call={calls[calls.length - 1]!} background={background} onClick={() => (expanded.value = true)} /></div>;
}

/**
 * SandboxFailureCard (064, #253): what happened, what Continue without sandbox would change, and
 * the two answers while the card waits. An answered or superseded card keeps saying what happened.
 */
function SandboxFailureCard({ record }: { record: SandboxFailureRecord }) {
  const actions = useContext(CallActionsContext);
  const sending = useSignal(false);
  const waiting = actions?.answerSandbox !== undefined && actions.waitingSandbox !== undefined
    && JSON.stringify(actions.waitingSandbox) === JSON.stringify(record);
  const words = sandboxCard(record);
  const answer = (carryOn: boolean) => {
    sending.value = true;
    void actions!.answerSandbox!(carryOn).finally(() => (sending.value = false));
  };
  return (
    <div class={`note switch sandbox-failure${waiting ? " waiting" : ""}`} role={waiting ? "alert" : undefined}>
      <p class="strong">{words.title}</p>
      <p>{words.body}</p>
      {record.detail && <details><summary class="quiet">Show error details</summary><pre>{record.detail}</pre></details>}
      {(waiting || !record.recoveryOffered) && <p class="quiet">{words.offer}</p>}
      <OrgPolicyLine mark={actions?.sandboxSetBy} />
      {waiting && (
        <p class="answers">
          <button disabled={sending.value} onClick={() => answer(false)}>{keepStopped}</button>
          {record.recoveryOffered && !actions?.sandboxSetBy && (
            <button class="prominent" disabled={sending.value} onClick={() => answer(true)}>{continueWithout}</button>
          )}
        </p>
      )}
    </div>
  );
}

/** Who another agent's message is from (#560), as the queued bubble says it too. */
export function fromLine(title: string | undefined): string {
  return `From \u201C${title ?? "another agent"}\u201D`;
}

/**
 * Copy Message (#519): the whole message, as written, onto the clipboard. Shown while the pointer
 * is on the message or the button has focus; the Mac and the phone have it on the message's menu.
 */
function CopyMessage({ entry, quotes = false, branches = false }: { entry: TranscriptEntry; quotes?: boolean; branches?: boolean }) {
  const copied = useSignal(false);
  const actions = useContext(CallActionsContext);
  const quote = actions?.quote;
  // The person's own prompt (#1658): a new session from just before it, with it to change and send.
  const branchFrom = branches ? actions?.branchFrom : undefined;
  const selected = useRef("");
  const text = copiedText(entry);
  if (!text) return null;
  const copy = () => {
    void navigator.clipboard?.writeText(text).then(() => {
      copied.value = true;
      setTimeout(() => { copied.value = false; }, 1500);
    }, () => {});
  };
  const greyedBranch = branches && !branchFrom && !!actions?.branchNeedsUpdate;
  const grouped = (quotes && !!quote) || !!branchFrom || greyedBranch;
  const copyButton = (
    <button class={grouped ? "steps-control" : "steps-control copy-message"} onClick={copy} title="Copy this message, as written">
      {copied.value ? "Copied" : "Copy"}
    </button>
  );
  if (branchFrom) {
    const words = fields(entry, "userMessage")?._0 ?? text;
    return (
      <span class="copy-message message-actions">
        <button class="steps-control" title="Start a new session from just before this prompt, with the prompt in its bar to change. The files stay as they are now."
          onClick={() => branchFrom(entry.id, words)}>Branch from Here</button>
        {copyButton}
      </span>
    );
  }
  if (greyedBranch) {
    return (
      <span class="copy-message message-actions">
        <button class="steps-control" title={hostNeedsUpdate} disabled>Branch from Here</button>
        {copyButton}
      </span>
    );
  }
  if (!quotes || !quote) return copyButton;
  // Quote in Prompt (#1553): the words selected in this reply, or all of it. Taken on the press,
  // before the click can move the selection.
  return (
    <span class="copy-message message-actions">
      <button class="steps-control" title="Quote the selected words (or all of this reply) in the prompt"
        onMouseDown={(e) => {
          const reply = (e.currentTarget as HTMLElement).closest(".reply");
          const selection = window.getSelection();
          selected.current = selection && !selection.isCollapsed && reply?.contains(selection.anchorNode) && reply.contains(selection.focusNode)
            ? selection.toString() : "";
        }}
        onClick={() => quote(selected.current.trim() ? selected.current : text)}>Quote</button>
      {copyButton}
    </span>
  );
}

/** One entry, drawn as its kind is (EntryRow). Marked so Exchanged can bring it into view. */
export function EntryRow({ entry }: { entry: TranscriptEntry }) {
  return <div class="entry-mark" data-entry={entry.id}>{entryBody(entry)}</div>;
}

function entryBody(entry: TranscriptEntry) {
  switch (kindOf(entry)) {
    case "userMessage": {
      const message = fields(entry, "userMessage")!;
      if (message.from === "app") {
        return <div class="note copyable"><p class="faint">From the app</p><div class="quiet"><Blocks blocks={message.blocks} text={message._0} /></div><CopyMessage entry={entry} /></div>;
      }
      if (message.from === "agent") {
        // Another agent's message (#560): the person's bubble, named as the sender's.
        return <div class="from-agent"><p class="faint">{fromLine(entry.sender?.title)}</p><div class="bubble copyable"><Blocks blocks={message.blocks} text={message._0} /><CopyMessage entry={entry} /></div></div>;
      }
      return <div class="bubble copyable"><Blocks blocks={message.blocks} text={message._0} /><CopyMessage entry={entry} branches /></div>;
    }
    case "agentMessage": {
      const message = fields(entry, "agentMessage")!;
      return <div class="reply copyable"><Blocks blocks={message.blocks} text={message.text} /><CopyMessage entry={entry} quotes /></div>;
    }
    case "agentThought":
      return <ThoughtLine text={fields(entry, "agentThought")!.text} />;
    case "toolCall":
    case "toolCallUpdate":
      return <p class="quiet">{callLine((fields(entry, "toolCall") ?? fields(entry, "toolCallUpdate"))!._0)}</p>;
    case "planUpdated":
      return <PlanView plan={fields(entry, "planUpdated")!._0} />;
    case "servedRequest": {
      const request = fields(entry, "servedRequest")!._0;
      const what = "readFile" in request.kind ? `Read ${request.kind.readFile.path.split("/").pop()}`
        : "writeFile" in request.kind ? `Wrote ${request.kind.writeFile.path.split("/").pop()}`
        : [request.kind.runCommand.command, ...request.kind.runCommand.args].join(" ");
      const how = "refused" in request.outcome ? ` — refused: ${request.outcome.refused.reason}`
        : "failed" in request.outcome ? ` — failed: ${request.outcome.failed.message}` : "";
      return <p class={`quiet${how ? " failure" : ""}`}>{what}{how}</p>;
    }
    case "elicitationAsked":
      return <p class="quiet">Asked: {elicitationTitle(fields(entry, "elicitationAsked")!._0)}</p>;
    case "elicitationAnswered": {
      const answered = fields(entry, "elicitationAnswered")!;
      if (!answered.answers?.length) return <p class="quiet">{answered.summary}</p>;
      return (
        <div class="answers">
          {answered.answers.map((answer, i) => (
            <div key={i}><p class="quiet">{answer.question}</p><p>{answer.answer}</p></div>
          ))}
        </div>
      );
    }
    case "compaction": {
      const compaction = fields(entry, "compaction")!;
      return (
        <div class="note">
          <p class="quiet">{compactionLine(compaction.status, compaction.error)}</p>
          {compaction.summary.length > 0 && <div class="quiet"><Blocks blocks={compaction.summary} text="" /></div>}
        </div>
      );
    }
    case "notice": {
      const notice = fields(entry, "notice")!._0;
      const error = notice.severity === "error";
      return (
        <div class="note">
          <p class={error ? "failure strong" : notice.severity === "warning" ? "quiet strong" : "quiet"}>{notice.title}</p>
          {notice.detail && <p class="quiet">{notice.detail}</p>}
        </div>
      );
    }
    case "permissionAsked":
      return <p class="quiet">Asked: {fields(entry, "permissionAsked")!._0.toolCall.title}</p>;
    case "permissionAnswered": {
      const answered = fields(entry, "permissionAnswered")!;
      return <p class="quiet">You chose {answered.optionName ?? answered.optionID}</p>;
    }
    case "stateChanged": {
      const state = fields(entry, "stateChanged")!;
      const failed = state.reason === "processDied" || state.reason === "daemonGone";
      return <p class={failed ? "failure" : "quiet"}>{stateWords(state._0, state.reason)}</p>;
    }
    case "workReported":
      return <ReportLine report={fields(entry, "workReported")!._0} />;
    case "runtimeNote":
      return <p class="quiet">{fields(entry, "runtimeNote")!._0}</p>;
    case "sandboxFailure":
      return <SandboxFailureCard record={fields(entry, "sandboxFailure")!._0} />;
    case "appView":
      return <AppView call={fields(entry, "appView")!._0} />;
    case "fileShown":
      return <FileCard file={fields(entry, "fileShown")!._0} />;
    case "notified": {
      // What the agent told the person (#2805): Shared/UI/Chat/NotifiedLine.swift.
      const notice = fields(entry, "notified")!._0;
      return (
        <div class="notice-line">
          <span class="notice-bell" aria-hidden="true">🔔︎</span>
          <div>
            <p class="notice-title">{notice.title}</p>
            {notice.body !== undefined && <p class="notice-body">{notice.body}</p>}
            <p class="quiet-line">{noticeClock(fromWireDate(entry.at))} · {noticeOutcome(notice)}</p>
          </div>
        </div>
      );
    }
    case "background": {
      // As the window's line: how it started or ended, a failure in the failure tint (#253).
      return <BackgroundEntryLine item={fields(entry, "background")!._0} />;
    }
    default:
      // Written by a newer build: kept in the record, drawn as nothing.
      return null;
  }
}

/** BackgroundEntryLine: how it started or ended, and a subagent's Steps (#544). */
function BackgroundEntryLine({ item }: { item: BackgroundItem }) {
  const steps = useContext(CallActionsContext)?.subagentSteps;
  return (
    <p class={item.state === "failed" ? "failure" : "quiet"}>
      {backgroundEntryLine(item)}
      {item.kind === "subagent" && steps && (
        <> <button class="link" title="See what this subagent did" onClick={() => steps(item)}>Steps</button></>
      )}
    </p>
  );
}

export function elicitationTitle(request: { message?: string; mode: { form: { _0: { title?: string } } } | { url: { _0: string } } }): string {
  if ("form" in request.mode) return request.mode.form._0.title ?? request.message ?? "The agent needs something";
  return "The agent wants you to open a page";
}

/**
 * The agent's thinking (ThoughtLine, #1315): one line, "Thought:" and its first words, and the
 * whole of it a click away, as a call's argument and return are.
 */
function ThoughtLine({ text }: { text: string }) {
  const expanded = useSignal(false);
  return (
    <div class="thought">
      <button class="call-line" aria-expanded={expanded.value}
        title={expanded.value ? "Hide the thought" : "Show the whole thought"}
        onClick={() => (expanded.value = !expanded.value)}>
        {thoughtLine(text)}
      </button>
      {expanded.value && <p class="quiet">{text}</p>}
    </div>
  );
}

/** A running turn's latest call, in one line, until the turn has its outcome (LiveLine). */
function LiveRunLine({ call }: { call: ToolCall }) {
  return <p class="live quiet">{turnLine(call)}</p>;
}

/**
 * An item of a turn: a call a line of its own, anything else as it is drawn (StepRow). A run of
 * calls is its last until it is clicked (#759); gone to from elsewhere, it is opened with its
 * first call (#1315).
 */
function StepRow({ item, focused = false, background }: {
  item: Item; focused?: boolean; background: readonly BackgroundItem[];
}) {
  const unrolled = useSignal(false);
  useEffect(() => {
    if (focused) unrolled.value = true;
  }, [focused]);
  if (item.kind === "run" && !unrolled.value && !focused && item.calls.length > 1) {
    const last = item.calls[item.calls.length - 1]!;
    return <div class="run" data-entry={item.id}><ToolCallLine call={last} text={turnLine(last)} background={background} onClick={() => (unrolled.value = true)} /></div>;
  }
  if (item.kind === "run") {
    return <div class="run" data-entry={item.id}>{item.calls.map((call, i) => <ToolCallLine key={i} call={call} text={turnLine(call)} focused={focused && i === 0} background={background} />)}</div>;
  }
  const call = fields(item.entry, "toolCall");
  if (call) return <ToolCallLine call={call._0} text={turnLine(call._0)} focused={focused} background={background} />;
  const thought = fields(item.entry, "agentThought");
  if (thought) return <div class="entry-mark" data-entry={item.entry.id}><ThoughtLine text={thought.text} /></div>;
  return <EntryRow entry={item.entry} />;
}

/** An item outside a turn's steps, as TranscriptRow draws it. */
export function ItemRow({ item, background }: { item: Item; background: readonly BackgroundItem[] }) {
  return item.kind === "run" ? <ToolRun calls={item.calls} background={background} /> : <EntryRow entry={item.entry} />;
}

/**
 * One turn: the ask, its steps and its outcome (TurnView). Every turn draws its steps, with no
 * control to hide them (#2170): each run of calls is one line already (#1315). Drawn again only
 * when one of its props changes: the chat keeps a turn the same object until an entry lands in
 * it, and hands every turn the same `loadDetail` (#170).
 *
 * A stored turn loads its last page once, and only near the end: every turn at once would fetch
 * them all. One the chat has let go shows Load steps instead of fetching itself (#291).
 */
export const TurnView = memo(function TurnView({ turn, focusedRun, fetched, fetchFailed, hasEarlier, auto, isLive, background, loadDetail: loadTurn, loadEarlier }: {
  turn: ChatTurn; focusedRun: string | null; fetched: readonly Item[] | undefined; fetchFailed: boolean; hasEarlier: boolean; auto: boolean; isLive: boolean;
  background: readonly BackgroundItem[];
  loadDetail: (turn: ChatTurn) => Promise<void>; loadEarlier: (turn: ChatTurn) => Promise<void>;
}) {
  const asked = useRef(false);
  const loading = useSignal(false);
  const load = useRef(loadTurn);
  load.current = loadTurn;
  const ask = () => {
    asked.current = true;
    loading.value = true;
    void load.current(turn).finally(() => { loading.value = false; });
  };
  const waiting = isSummaryOnly(turn) && fetched === undefined;
  const items = isSummaryOnly(turn) ? fetched ?? [] : turn.items;
  const parts = waiting ? undefined : turnParts(items, isLive);
  const outcome = parts?.outcome ?? turn.storedOutcome ?? [];
  const stepCount = parts?.stepCount ?? turn.storedStepCount ?? 0;
  const outcomeIDs = new Set((parts?.outcome ?? []).map((i) => i.id));
  // Thinking too, each a folded line in its place (#1315).
  const steps = drawnInTurn(items, isLive).filter((i) => !outcomeIDs.has(i.id));
  useEffect(() => {
    // Once, and only while this turn is among the ones the chat will keep. A later eviction
    // leaves `asked` set, so the effect does not fetch it straight back (#291).
    if (!(waiting && auto) || asked.current) return;
    ask();
  }, [waiting, auto]);
  return (
    <article class="turn" aria-label="Turn" data-turn={turn.id}>
      {turn.ask && <ItemRow item={turn.ask} background={background} />}
      {stepCount !== 0 ? (
        waiting ? (loading.value || (auto && !asked.current) ? <p class="quiet">Loading…</p>
          // A read that failed says so, as the window's turn does, rather than a bare Load steps (#544).
          : fetchFailed ? <p class="load-failure" role="status"><span>These steps did not load.</span>
            <button class="link" onClick={ask}>Try Again</button></p>
          : <button class="steps-control" onClick={ask}>Load steps</button>) : (
          <>
            {hasEarlier && <button class="steps-control" onClick={() => void loadEarlier(turn)}>Earlier steps</button>}
            <div class="steps">{steps.map((item) => <StepRow key={item.id} item={item} focused={item.id === focusedRun} background={background} />)}</div>
            {outcome.map((item) => <StepRow key={item.id} item={item} background={background} />)}
          </>
        )
      ) : (
        <>
          {parts?.live && (parts.live.kind === "run"
            ? <LiveRunLine call={parts.live.calls[parts.live.calls.length - 1]!} />
            : <StepRow item={parts.live} background={background} />)}
          {outcome.map((item) => <StepRow key={item.id} item={item} background={background} />)}
        </>
      )}
    </article>
  );
});
