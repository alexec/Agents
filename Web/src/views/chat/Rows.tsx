// One turn of the chat at the level it is drawn at (069), and every kind of line in it, as the
// shared TranscriptRows.swift draws them for the Mac and the phone (071 FR-023). Words come from
// the ported rules; agent text goes through the Markdown renderer and nowhere else.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type {
  AgentState, BackgroundItem, ContentBlock, EndedReason, JSONValue, Plan, ToolCall, TranscriptEntry, WorkReport,
} from "../../protocol/generated";
import { backgroundEnding } from "../../model/background";
import { outcomeNeedsAPerson } from "../../model/groups";
import { outcomeHeadings, startingLabel } from "../../model/status";
import {
  callLine, drawnInTurn, fields, isSummaryOnly, isThought, kindOf, turnLine, turnParts, type ChatTurn, type Item,
} from "../../model/turns";
import { Markdown } from "../../render/markdown";

/** How much of a turn is drawn (TurnDetail). */
export type TurnDetail = "outcome" | "steps" | "details";
export const detailTitles: Record<TurnDetail, string> = { outcome: "Outcome", steps: "Steps", details: "Details" };
export const detailSummaries: Record<TurnDetail, string> = {
  outcome: "What was asked and how it went",
  steps: "Every step, one line each",
  details: "Every call opened, and thinking",
};

/** The text of a message's blocks: text blocks as Markdown, anything else named. */
function Blocks({ blocks, text }: { blocks: ContentBlock[] | undefined; text: string }) {
  if (!blocks?.length) return <Markdown text={text} />;
  return (
    <>
      {blocks.map((block, index) => {
        if (block.type === "text") return <Markdown key={index} text={block.text} />;
        if (block.type === "resource_link") return <p key={index} class="attachment">📎 {block.name}</p>;
        if (block.type === "resource") return <p key={index} class="attachment">📎 {block.resource.uri.split("/").pop()}</p>;
        if (block.type === "image") return <p key={index} class="attachment">[image]</p>;
        return null;
      })}
    </>
  );
}

const stopWords: Partial<Record<EndedReason, string>> = {
  cancelled: "You stopped it",
  stoppedByAgent: "The agent that started it stopped it",
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

function PlanView({ plan }: { plan: Plan }) {
  const marks = { pending: "○", in_progress: "◐", completed: "●" } as const;
  return (
    <ul class="plan" aria-label="Plan">
      {plan.entries.map((entry, index) => (
        <li key={index} class={entry.status}><span class="mark" aria-hidden="true">{marks[entry.status]}</span> {entry.content}</li>
      ))}
    </ul>
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

/** One tool call: its line, and what it did once asked (ToolCallLine). */
export function ToolCallLine({ call, text, open = false, background, onClick }: {
  call: ToolCall; text?: string; open?: boolean; background: readonly BackgroundItem[]; onClick?: () => void;
}) {
  const expanded = useSignal(false);
  const runsOn = call.toolCallID !== undefined
    && background.some((item) => item.toolCallID === call.toolCallID && (item.state === "running" || item.state === "paused"))
    ? " · running in the background" : "";
  const hasDetail = (call.content ?? []).length > 0 || (call.locations ?? []).length > 0
    || call.rawInput !== undefined || call.rawOutput !== undefined;
  const line = (text ?? callLine(call)) + runsOn;
  const showsDetail = open || expanded.value;
  return (
    <div class="call">
      {onClick || hasDetail ? (
        <button class="call-line" aria-expanded={onClick ? undefined : showsDetail}
          title={onClick ? "Show the whole run" : showsDetail ? "Hide the argument and the return" : "Show the argument and the return"}
          onClick={onClick ?? (() => (expanded.value = !expanded.value))}>
          {hasDetail && !onClick && <span class="chevron" aria-hidden="true">{showsDetail ? "▾" : "▸"}</span>}
          {line}
        </button>
      ) : <p class="call-line">{line}</p>}
      {showsDetail && !onClick && (
        <div class="call-detail">
          {(call.content ?? []).map((piece, index) => {
            if (piece.type === "diff") {
              return (
                <div key={index} class="diff">
                  <p class="quiet">{piece.path.split("/").pop()}</p>
                  {piece.oldText !== undefined && <pre class="removed">{piece.oldText}</pre>}
                  <pre class="added">{piece.newText}</pre>
                </div>
              );
            }
            if (piece.type === "content" && piece.content.type === "text") return <Markdown key={index} text={piece.content.text} />;
            if (piece.type === "terminal") return <p key={index} class="quiet">Terminal output is shown in the Mac window.</p>;
            return null;
          })}
          {(call.locations ?? []).length > 0 && (
            <p class="locations">{(call.locations ?? []).map((l) => `${l.path.split("/").pop()}${l.line ? `:${l.line}` : ""}`).join("  ")}</p>
          )}
          {call.rawInput !== undefined && <div><p class="quiet">Argument</p><pre>{pretty(call.rawInput)}</pre></div>}
          {call.rawOutput !== undefined && <div><p class="quiet">Return</p><pre>{pretty(call.rawOutput)}</pre></div>}
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

function poolSwitchLine(entry: TranscriptEntry): string {
  const record = fields(entry, "poolSwitch")!._0;
  const name = (id: string) => id.charAt(0).toUpperCase() + id.slice(1);
  const from = name(record.from.runtimeID);
  const to = name(record.to.runtimeID);
  switch (record.reason) {
    case "allowanceSpent": return `${from}’s allowance ran out. Carried on with ${to}.`;
    case "overage": return `${from} started using paid extra usage. Carried on with ${to}.`;
    case "creditUsedUp": return `${from}’s credit was used up. Carried on with ${to}.`;
    case "rateLimitPersisted": return `${from} stayed rate limited. Carried on with ${to}.`;
    case "runtimeFailed": return `${from} failed. Carried on with ${to}.`;
    case "everyoneOutResumed": return `${to}’s allowance came back. Carried on.`;
    default: return `Continued with ${to}.`;
  }
}

/** One entry, drawn as its kind is (EntryRow). */
export function EntryRow({ entry }: { entry: TranscriptEntry }) {
  switch (kindOf(entry)) {
    case "userMessage": {
      const message = fields(entry, "userMessage")!;
      if (message.from === "app") {
        return <div class="note"><p class="faint">Agents asked</p><div class="quiet"><Blocks blocks={message.blocks} text={message._0} /></div></div>;
      }
      return <div class="bubble"><Blocks blocks={message.blocks} text={message._0} /></div>;
    }
    case "agentMessage": {
      const message = fields(entry, "agentMessage")!;
      return <div class="reply"><Blocks blocks={message.blocks} text={message.text} /></div>;
    }
    case "agentThought":
      return <p class="thought quiet">{fields(entry, "agentThought")!.text}</p>;
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
          <p class="quiet">{compaction.status === "completed" ? "Made room by summarising the conversation so far"
            : "Summarising the conversation so far…"}</p>
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
    case "poolSwitch":
      return <div class="note switch"><p class="strong">⇄ {poolSwitchLine(entry)}</p></div>;
    case "sandboxFailure": {
      const record = fields(entry, "sandboxFailure")!._0;
      return (
        <div class="note switch">
          <p class="strong">Its sandbox could not start</p>
          <details><summary class="quiet">Show error details</summary><pre>{record.detail}</pre></details>
        </div>
      );
    }
    case "settingsChanged": {
      const record = fields(entry, "settingsChanged")!._0;
      const carried = record.carried.flatMap((s) => (typeof s.to === "string" ? [`${s.name} ${s.to}`] : []));
      return <p class="quiet">Changed what it carried on with: {carried.join(", ")}</p>;
    }
    case "handoff": {
      const handoff = fields(entry, "handoff")!;
      return (
        <details class="note">
          <summary class="faint">What it was handed ({handoff.characters.toLocaleString()} characters)</summary>
          <div class="quiet"><Markdown text={handoff.markdown} /></div>
        </details>
      );
    }
    case "background":
      return <p class="quiet">{backgroundEnding(fields(entry, "background")!._0)}</p>;
    default:
      // Written by a newer build: kept in the record, drawn as nothing.
      return null;
  }
}

export function elicitationTitle(request: { message?: string; mode: { form: { _0: { title?: string } } } | { url: { _0: string } } }): string {
  if ("form" in request.mode) return request.mode.form._0.title ?? request.message ?? "The agent needs something";
  return "The agent wants you to open a page";
}

/** An item of a turn: a call a line of its own, anything else as it is drawn (StepRow). */
function StepRow({ item, open, background }: { item: Item; open: boolean; background: readonly BackgroundItem[] }) {
  if (item.kind === "run") {
    return <div class="run">{item.calls.map((call, i) => <ToolCallLine key={i} call={call} text={turnLine(call)} open={open} background={background} />)}</div>;
  }
  const call = fields(item.entry, "toolCall");
  if (call) return <ToolCallLine call={call._0} text={turnLine(call._0)} open={open} background={background} />;
  return <EntryRow entry={item.entry} />;
}

/** An item outside a turn's steps, as TranscriptRow draws it. */
export function ItemRow({ item, background }: { item: Item; background: readonly BackgroundItem[] }) {
  return item.kind === "run" ? <ToolRun calls={item.calls} background={background} /> : <EntryRow entry={item.entry} />;
}

function stepsWords(count: number | undefined, open: boolean): string {
  if (open) return "Hide steps";
  if (count === undefined) return "Show steps";
  return count === 1 ? "1 step" : `${count} steps`;
}

/** One turn: the ask, the control into its steps, and its outcome (TurnView). */
export function TurnView({ turn, detail, fetched, isLive, background, toggle, fetch }: {
  turn: ChatTurn; detail: TurnDetail; fetched: Item[] | undefined; isLive: boolean;
  background: readonly BackgroundItem[]; toggle: () => void; fetch: () => void;
}) {
  const waiting = isSummaryOnly(turn) && fetched === undefined;
  const items = isSummaryOnly(turn) ? fetched ?? [] : turn.items;
  const parts = waiting ? undefined : turnParts(items, isLive);
  const outcome = parts?.outcome ?? turn.storedOutcome ?? [];
  const stepCount = parts?.stepCount ?? turn.storedStepCount;
  const open = detail !== "outcome";
  const outcomeIDs = new Set((parts?.outcome ?? []).map((i) => i.id));
  const steps = drawnInTurn(items, isLive).filter((i) => !outcomeIDs.has(i.id) && (detail === "details" || !isThought(i)));
  useEffect(() => {
    if (open && waiting) fetch();
  }, [open, waiting]);
  return (
    <article class="turn" aria-label="Turn">
      {turn.ask && <ItemRow item={turn.ask} background={background} />}
      {stepCount !== 0 && (
        <button class="steps-control" aria-expanded={open} onClick={toggle}
          title={open ? "Hide this turn's steps" : "Show every step of this turn"}>
          <span aria-hidden="true">{open ? "▾" : "▸"}</span> {stepsWords(stepCount, open)}
        </button>
      )}
      {open && stepCount !== 0 ? (
        waiting ? <p class="quiet">Loading…</p> : (
          <>
            <div class="steps">{steps.map((item) => <StepRow key={item.id} item={item} open={detail === "details"} background={background} />)}</div>
            {outcome.map((item) => <StepRow key={item.id} item={item} open={false} background={background} />)}
          </>
        )
      ) : (
        <>
          {parts?.live && (parts.live.kind === "run"
            ? <p class="live quiet">{turnLine(parts.live.calls[parts.live.calls.length - 1]!)}</p>
            : <StepRow item={parts.live} open={false} background={background} />)}
          {outcome.map((item) => <StepRow key={item.id} item={item} open={false} background={background} />)}
        </>
      )}
    </article>
  );
}
