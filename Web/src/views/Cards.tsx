// Permission requests and question cards in the conversation, at its end (071 FR-024, #723, #1995;
// PermissionView.swift and ElicitationView.swift). Answering one here answers it everywhere. One answered somewhere else
// while it is on screen says so, and its buttons do nothing (US2 scenario 5).
//
// The first card takes keys, as the window's do (#256): Return its first real answer when no field
// has the keys, and ⌥1…9 its answers by position. The window's are ⌘1…9; a browser keeps those for
// its tabs, so the page's are on Option.
import type { ComponentChildren } from "preact";
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type {
  ElicitationHandOff, ElicitationRequest, ElicitationSchema, ElicitationSchemaProperty, ElicitationSchemaPropertyChoice, ElicitationSecret, JSONValue,
  PermissionOption, PermissionRequest, UUID,
} from "../protocol/generated";
import type { Store } from "../model/store";
import { CallFailed } from "../wire/link";
import { describe } from "../model/errors";
import { Failure } from "../protocol/generated";
import { isSafeLink } from "../render/markdown";
import { Blocks, EditDiff } from "./chat/Rows";
import { askHead } from "../model/askHead";
import { askerFor } from "../model/asker";
import { planOf } from "../model/plan";
import { Markdown } from "../render/markdown";
import { inputType, momentFromInput, momentToInput, placeholder } from "../model/formInputs";
import { descriptionField, getIt, keeping, secretField } from "../model/secretAsk";
import { descriptionHint, descriptionLabel, descriptionPrompt } from "../model/userScope";
import { handOffAnswer, handOffWindowWords } from "../model/handOff";
import { openTakeOver, route } from "../route";
import { keepingForSession, sessionOnlyField, sessionSecretWords } from "../model/sessionSecrets";
import { askBeforeUseHint, askBeforeUseWords, needsApprovalField } from "../model/askBeforeUse";

type Held = (
  | { kind: "permission"; request: PermissionRequest }
  | { kind: "elicitation"; request: ElicitationRequest }
) & {
  answered: Answered;
  /** The answer on its way, by its button's key (#86). */
  chosen?: string;
  /** Made at the first send and kept, so a retry is the same answer. */
  sendID?: UUID;
};
/**
 * null while it waits; "here" once this page answered; "elsewhere" when another client did;
 * "withdrawn" when the session stopped before anyone answered.
 */
type Answered = null | "sending" | "here" | "elsewhere" | "withdrawn";

/** What the host writes when a question goes because its agent ended (RuntimeNote.swift). */
const questionWentUnanswered = "Nobody answered this question before the agent ended.";

/** How long a card answered elsewhere stays to say so. */
const answeredElsewhereShownFor = 4_000;

/** A card that waits on the person, or the agent's wait on events, at the end of the chat (WaitingCard, #1995). */
export interface WaitingCard { key: string; node: ComponentChildren }

/**
 * The permission and question cards waiting in a session, for the chat to draw at its end. A hook rather than a component, so the cards can sit apart while what
 * they hold (an answer on its way, one answered elsewhere) is kept in one place.
 */
export function useWaitingCards({ store, host, session, down = false, handOffsOnly = false }: {
  store: Store; host: string; session: string;
  /** Its host is down: the answers are held, greyed, until it is back, as the window's are (#83). */
  down?: boolean;
  /** Only the hand_to_person cards, with no Open the page: the take-over tab, where the page is open already (#4141). */
  handOffsOnly?: boolean;
}): WaitingCard[] {
  // A question taken away because its runtime went is said in the conversation first, then
  // withdrawn (RuntimeNote.questionWentUnanswered): that line, after it was asked, is the tell.
  const unansweredSince = (askedAt: number) => store.entries.value.some((e) =>
    e.at >= askedAt && (e.kind as { runtimeNote?: { _0: string } }).runtimeNote?._0 === questionWentUnanswered);
  const held = useSignal<Held[]>([]);
  const permissions = store.permissionsFor(host, session);
  const elicitations = store.elicitationsFor(host, session);
  const live = new Set([...permissions.map((p) => p.id), ...elicitations.map((e) => e.id)]);

  // What the host holds, merged with what is on screen: a card the host withdrew and this page
  // did not answer was answered somewhere else.
  // Which session `held` is for: a new one starts from nothing, in this same effect. A second
  // effect clearing it ran after this one on the first render and wiped the cards a chat opened
  // with, so a question already waiting when the chat was opened was never shown.
  const heldFor = useRef<string | null>(null);
  const lingering = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => {
    for (const timer of lingering.current) clearTimeout(timer);
    lingering.current = [];
  }, []);
  useEffect(() => {
    if (heldFor.current !== session) {
      heldFor.current = session;
      held.value = [];
    }
    const before = held.value;
    const next: Held[] = [];
    for (const card of before) {
      if (live.has(card.request.id)) next.push(card);
      else if (card.answered === "elsewhere" || card.answered === "withdrawn") next.push(card);
      else if (card.answered === null) {
        next.push({ ...card, answered: unansweredSince(card.request.askedAt) ? "withdrawn" : "elsewhere" });
      }
    }
    const known = new Set(next.map((c) => c.request.id));
    for (const request of permissions) if (!known.has(request.id)) next.push({ kind: "permission", request, answered: null });
    for (const request of elicitations) if (!known.has(request.id)) next.push({ kind: "elicitation", request, answered: null });
    held.value = next;
    const settled = (c: Held) => c.answered === "elsewhere" || c.answered === "withdrawn";
    const gone = next.filter((c) => settled(c) && !before.some((b) => b.request.id === c.request.id && settled(b)));
    if (gone.length) {
      const ids = new Set(gone.map((c) => c.request.id));
      const timer = setTimeout(() => {
        lingering.current = lingering.current.filter((t) => t !== timer);
        held.value = held.value.filter((c) => !(ids.has(c.request.id) && settled(c)));
      }, answeredElsewhereShownFor);
      lingering.current.push(timer);
    }
  }, [[...live].join(","), session]);


  const mark = (id: string, answered: Answered) => {
    held.value = held.value.map((c) => (c.request.id === id ? { ...c, answered } : c));
  };
  /**
   * Sends an answer. The card goes at once, before the host has it (#4786), and comes back with
   * its buttons when the answer did not go, under the line that says why. A refusal means it was
   * no longer waiting: answered somewhere else. One `sendID` for every try, so a retry is the same
   * answer and not a second one (#86).
   */
  const send = async (id: string, chosen: string, call: (sendID: UUID) => Promise<unknown>) => {
    const card = held.value.find((c) => c.request.id === id);
    if (!card || card.answered !== null) return;
    const sendID = card.sendID ?? (crypto.randomUUID().toUpperCase() as UUID);
    held.value = held.value.map((c) => (c.request.id === id ? { ...c, answered: "here", chosen, sendID } : c));
    try {
      await call(sendID);
      held.value = held.value.filter((c) => c.request.id !== id);
    } catch (error) {
      // The host refusing means it was no longer waiting; the link dropping, or the host
      // being away, means try again. So does the host refusing the answer itself (JSON-RPC's
      // invalid params), such as a secret it could not save (#2885): the card still waits.
      const away = !(error instanceof CallFailed) || error.code === Failure.hostOffline || error.code === invalidParams;
      if (away) store.say(describe(error));
      mark(id, away ? null : "elsewhere");
    }
  };

  const cards = held.value.filter((c) => c.answered !== "here" && (!handOffsOnly || (c.kind === "elicitation" && c.request.handOff)));
  if (!cards.length) return [];
  const recipient = store.isMac(host) ? "your Mac" : store.hosts.value.find((h) => h.id === host)?.name ?? "the machine";
  // Who is asking, by title and runtime (#121).
  const runtimeName = (id: string) => (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === id)?.runtime.name;
  const asker = (agentID: string, subagent?: string) =>
    askerFor(store.agents.value[host] ?? [], agentID, runtimeName, subagent);
  return cards.map((card, index) => ({
    key: card.request.id,
    node: card.kind === "permission"
      ? <PermissionCard key={card.request.id} active={index === 0} request={card.request} asker={asker(card.request.agentID, card.request.subagent)}
          // Shown as the host shows it: the page beside the chat, read again (the window's Show plan).
          showPlan={(path) => (store.shownFile.value = { host, agentID: card.request.agentID, path, at: Date.now() })}
          hold={{ answered: card.answered, chosen: card.chosen, recipient, down }}
          answer={(option) => send(card.request.id, option.optionID, (sendID) => store.link.call("permissions/answer",
            { permissionID: card.request.id, optionID: option.optionID, sendID }, host))} />
      : <ElicitationCard key={card.request.id} active={index === 0} request={card.request} asker={asker(card.request.agentID)}
          // The agent browser in a tab of its own, at the agent's tab (#3529, #4141).
          openBrowser={handOffsOnly ? undefined : () => {
            const agent = store.agent(host, session);
            openTakeOver(host, route.peek().folder ?? agent?.worktree?.folder ?? agent?.cwd ?? "", session, "browser");
          }}
          hold={{ answered: card.answered, chosen: card.chosen, recipient, down }}
          answer={(key, action, content, reason) => send(card.request.id, key, (sendID) => store.link.call("elicitations/answer",
            { requestID: card.request.id, action, content, sendID, ...(reason ? { reason } : {}) }, host))} />,
  }));
}

function AnsweredNote({ answered }: { answered: Answered }) {
  if (answered === "elsewhere") return <p class="answered" role="status">Answered on another device.</p>;
  if (answered === "withdrawn") return <p class="answered" role="status">The session stopped before this was answered.</p>;
  return null;
}

/** JSON-RPC's own code for an answer the host would not take, the form still waiting. */
const invalidParams = -32602;

/** Where a card stands: its answer, and while one is on its way, which and to whom. */
interface Hold { answered: Answered; chosen: string | undefined; recipient: string; down: boolean }

/**
 * A button's part in that: the one sent keeps its look and says where it is going; the others
 * are held. Answered elsewhere or withdrawn, the whole card is inert instead.
 */
function holding(hold: Hold, key: string) {
  const sending = hold.answered === "sending";
  const off = hold.down && hold.answered === null;
  return {
    class: (sending && hold.chosen !== key) || off ? "held" : "",
    disabled: hold.answered !== null || off,
    telling: sending && hold.chosen === key
      ? <span class="telling" role="status"><span class="spinner" aria-hidden="true" />telling {hold.recipient}</span>
      : null,
  };
}

/** A card's own class: greyed whole only once it is settled somewhere else. */
const cardClass = (hold: Hold) => `card${hold.answered === "elsewhere" || hold.answered === "withdrawn" ? " inert" : ""}`;

/**
 * The keys for a card while it is the first: ⌥1…9 press its `data-answer` buttons in order, and
 * Return its `data-default` one, unless a field, a menu or a link has the keys.
 */
function useCardKeys(card: { current: HTMLElement | null }, active: boolean) {
  useEffect(() => {
    if (!active) return;
    const press = (e: KeyboardEvent) => {
      const here = card.current;
      if (!here || e.defaultPrevented || e.isComposing) return;
      const digit = /^Digit([1-9])$/.exec(e.code);
      if (digit && e.altKey && !e.metaKey && !e.ctrlKey) {
        const answer = here.querySelectorAll<HTMLElement>("[data-answer]")[Number(digit[1]) - 1];
        if (answer) {
          e.preventDefault();
          answer.click();
        }
        return;
      }
      if (e.key !== "Enter" || e.altKey || e.metaKey || e.ctrlKey || e.shiftKey) return;
      const focused = document.activeElement;
      if (focused instanceof HTMLElement && focused.closest("input, textarea, select, button, a, [contenteditable]")) return;
      const answer = here.querySelector<HTMLElement>("[data-default]");
      if (answer) {
        e.preventDefault();
        answer.click();
      }
    };
    document.addEventListener("keydown", press);
    return () => document.removeEventListener("keydown", press);
  }, [active]);
}

/** The hint a numbered answer carries, as the window's ⌘n. */
const numbered = (n: number) => (n < 9 ? { "data-answer": "", title: `⌥${n + 1}` } : {});

const allows = (option: PermissionOption) => option.kind === "allow_once" || option.kind === "allow_always";

function PermissionCard({ request, asker, hold, answer, active, showPlan }: {
  request: PermissionRequest; asker: string | null; hold: Hold; answer: (option: PermissionOption) => void; active: boolean;
  showPlan: (path: string) => void;
}) {
  const card = useRef<HTMLElement>(null);
  useCardKeys(card, active);
  // A plan's kind is the runtime's word for it (switch_mode), so a plan says the plan instead.
  const plan = planOf(request.toolCall);
  const firstAllowing = request.options.find(allows);
  return (
    <section ref={card} class={cardClass(hold)} aria-label="Permission request">
      <div class="question">
        {asker && <p class="quiet small asker">{asker}</p>}
        <p class="strong">{request.toolCall.title}</p>
        {request.toolCall.kind && !plan && <p class="quiet small">{request.toolCall.kind}</p>}
        {plan?.file && (
          <p class="plan-shown quiet small">The plan is open beside this conversation.{" "}
            <button onClick={() => showPlan(plan.file!)}>Show plan</button></p>
        )}
        {plan?.text && !plan.file && <div class="plan-text"><Markdown text={plan.text} /></div>}
        {/* What it actually wants to do, shown rather than summarised, as the Remote's (#266). */}
        {!plan?.file && !plan?.text && request.toolCall.content.map((piece, index) =>
          piece.type === "diff" ? <EditDiff key={index} diff={piece} />
          : piece.type === "content" && piece.content.type === "text" ? <Markdown key={index} text={piece.content.text} />
          : piece.type === "content" ? <Blocks key={index} blocks={[piece.content]} text="" />
          : null)}
      </div>
      <div class="options">
        {request.options.map((option, index) => {
          const h = holding(hold, option.optionID);
          return (
            <button key={option.optionID} class={`${allows(option) ? "prominent" : ""} ${h.class}`.trim()} aria-disabled={h.disabled}
              {...numbered(index)} {...(option === firstAllowing ? { "data-default": "" } : {})}
              onClick={() => !h.disabled && answer(option)}>{option.name}{h.telling}</button>
          );
        })}
      </div>
      <AnsweredNote answered={hold.answered} />
    </section>
  );
}

// ElicitationSchema's rules (Model/Elicitation.swift): one-click forms, pages, and what will not do.

function choicesOf(property: ElicitationSchemaProperty): ElicitationSchemaPropertyChoice[] | undefined {
  return "string" in property.kind ? property.kind.string.choices : undefined;
}

function singleChoice(schema: ElicitationSchema) {
  const only = schema.properties.length === 1 ? schema.properties[0] : undefined;
  const choices = only ? choicesOf(only) : undefined;
  return only && choices?.length ? { property: only, choices } : undefined;
}

/** An optional free-text box named after the question before it travels on its page. */
function isNote(property: ElicitationSchemaProperty, previous: ElicitationSchemaProperty): boolean {
  if (property.isRequired || !property.name.startsWith(previous.name + "_") || !("string" in property.kind)) return false;
  const s = property.kind.string;
  return s.format === undefined && s.minLength === undefined && s.maxLength === undefined && s.choices === undefined;
}

function pagesOf(schema: ElicitationSchema): ElicitationSchemaProperty[][] {
  const pages: ElicitationSchemaProperty[][] = [];
  for (const property of schema.properties) {
    const page = pages[pages.length - 1];
    const previous = page?.[page.length - 1];
    if (page && previous && isNote(property, previous)) page.push(property);
    else pages.push([property]);
  }
  return pages;
}

function problem(property: ElicitationSchemaProperty, value: JSONValue | undefined): string | null {
  const missing = value === undefined || value === null || value === "" || (Array.isArray(value) && value.length === 0);
  if (missing) return property.isRequired ? `${property.title ?? property.name} is needed` : null;
  const kind = property.kind;
  if ("string" in kind) {
    if (typeof value !== "string") return `${property.name} must be text`;
    const length = [...value].length;
    if (kind.string.minLength !== undefined && length < kind.string.minLength) return `At least ${kind.string.minLength} characters`;
    if (kind.string.maxLength !== undefined && length > kind.string.maxLength) return `At most ${kind.string.maxLength} characters`;
    if (kind.string.choices && !kind.string.choices.some((c) => c.value === value)) return "Not one of the choices";
  } else if ("number" in kind || "integer" in kind) {
    const bounds = "number" in kind ? kind.number : kind.integer;
    if (typeof value !== "number" || ("integer" in kind && !Number.isInteger(value))) {
      return "integer" in kind ? `${property.name} must be a whole number` : `${property.name} must be a number`;
    }
    if (bounds.minimum !== undefined && value < bounds.minimum) return `At least ${bounds.minimum}`;
    if (bounds.maximum !== undefined && value > bounds.maximum) return `At most ${bounds.maximum}`;
  } else if ("boolean" in kind) {
    if (typeof value !== "boolean") return `${property.name} must be yes or no`;
  } else if ("multiSelect" in kind) {
    if (!Array.isArray(value)) return `${property.name} must be a list`;
    if (kind.multiSelect.minItems !== undefined && value.length < kind.multiSelect.minItems) return `Choose at least ${kind.multiSelect.minItems}`;
    if (kind.multiSelect.maxItems !== undefined && value.length > kind.multiSelect.maxItems) return `Choose at most ${kind.multiSelect.maxItems}`;
  }
  return null;
}

type Action = "accept" | "decline" | "cancel";

/** A form's own defaults, as it is first shown. */
function defaultsOf(request: ElicitationRequest): Record<string, JSONValue> {
  const defaults: Record<string, JSONValue> = {};
  if ("form" in request.mode) {
    for (const p of request.mode.form._0.properties) if (p.defaultValue !== undefined) defaults[p.name] = p.defaultValue;
  }
  return defaults;
}

function ElicitationCard({ request, asker, hold, answer, active, openBrowser }: {
  request: ElicitationRequest; asker: string | null; hold: Hold;
  answer: (key: string, action: Action, content: Record<string, JSONValue>, reason?: string) => void;
  active: boolean;
  /** Open the page; none where the page is open already (#4141). */
  openBrowser: (() => void) | undefined;
}) {
  const card = useRef<HTMLElement>(null);
  useCardKeys(card, active);
  const inert = hold.answered !== null || hold.down;
  // Each card is its own request (keyed by its id above), so its defaults are where it starts.
  // Filled in an effect instead, they landed after the first paint, and a choice made before
  // then was wiped: the form went back empty (the closing walk, T071).
  const values = useSignal<Record<string, JSONValue>>(defaultsOf(request));
  const step = useSignal(0);
  // No, because… (#4039): the decline being explained, by its key, while the card asks why.
  const because = useSignal<string | null>(null);
  // The one question of a confirm card is its title (#5028).
  const { title, message } = askHead(request);
  const go = (key: string, action: Action, content: Record<string, JSONValue> = {}, reason?: string) =>
    !inert && answer(key, action, content, reason?.trim() || undefined);
  /** One of the card's answers, by its key: its class beside `base`, held state and pending mark. */
  const button = (key: string, base = "") => {
    const h = holding(hold, key);
    return { class: `${base} ${h.class}`.trim() || undefined, disabled: h.disabled, telling: h.telling };
  };
  const done = button("done"), gaveUp = button("gave-up"), none = button("none"), decline = button("decline");
  /** No, because…, beside the decline it explains. */
  const sayWhy = (key: string, attrs: Record<string, string> = {}) => (
    <button aria-disabled={inert} {...attrs} onClick={() => !inert && (because.value = key)}>{declineReasonOpener}</button>
  );

  let body;
  if (because.value !== null) {
    const key = because.value;
    // The question stays in view; the answers give way to the reason.
    body = <DeclineReason inert={inert} sent={button(key, "prominent")} back={() => (because.value = null)}
      send={(reason) => go(key, "decline", {}, reason)} />;
  } else if (request.handOff) {
    // A step on the page in the machine's browser (#3529): Open the page shows it in a tab of its own (#4141).
    body = <HandOffField handOff={request.handOff} inert={inert} open={openBrowser} recipient={hold.recipient}
      done={button("done")} cannot={button("cannot", "prominent")}
      send={(isDone, note) => go(isDone ? "done" : "cannot", "accept", handOffAnswer(isDone, note))} />;
  } else if (request.secret) {
    // A masked field of its own (#2885), never the form's open one.
    const reason = "form" in request.mode ? request.mode.form._0.properties[0]?.title : undefined;
    body = <SecretField secret={request.secret} reason={reason} recipient={hold.recipient} inert={inert}
      save={button("save", "prominent")} decline={decline} sayWhy={sayWhy("decline")}
      send={(typed, sessionOnly, ask, description) => (typed === null ? go("decline", "decline")
        : go("save", "accept", {
          [secretField]: typed,
          ...(sessionOnly ? { [sessionOnlyField]: true } : {}),
          ...(ask === null ? {} : { [needsApprovalField]: ask }),
          [descriptionField]: description,
        }))} />;
  } else if ("url" in request.mode) {
    const url = request.mode.url._0;
    body = (
      <div class="options row-options">
        {isSafeLink(url) && <a class="button prominent" href={url} target="_blank" rel="noopener noreferrer" data-default="">Open</a>}
        <button class={done.class} aria-disabled={done.disabled} {...numbered(0)} onClick={() => go("done", "accept")}>Done{done.telling}</button>
        <button class={gaveUp.class} aria-disabled={gaveUp.disabled} {...numbered(1)} onClick={() => go("gave-up", "decline")}>Gave up{gaveUp.telling}</button>
        {sayWhy("gave-up", numbered(2))}
      </div>
    );
  } else {
    const schema = request.mode.form._0;
    const single = singleChoice(schema);
    if (single) {
      body = (
        <>
          {schema.description && <p class="quiet">{schema.description}</p>}
          {/* The choices scroll on their own in a short window; No answer and No thanks stay under them (#381). */}
          <div class="options choices">
            {single.choices.map((choice, index) => {
              const b = button(`choice:${choice.value}`, "prominent");
              return (
                <button key={choice.value} class={b.class} aria-disabled={b.disabled}
                  {...numbered(index)} {...(index === 0 ? { "data-default": "" } : {})}
                  onClick={() => go(`choice:${choice.value}`, "accept", { [single.property.name]: choice.value })}>
                  {choice.title}{choice.description && <span class="small quiet">{choice.description}</span>}{b.telling}
                </button>
              );
            })}
          </div>
          <div class="options">
            {!single.property.isRequired && (
              <button class={none.class} aria-disabled={none.disabled} {...numbered(single.choices.length)}
                onClick={() => go("none", "accept", { [single.property.name]: "" })}>No answer{none.telling}</button>
            )}
            <button class={decline.class} aria-disabled={decline.disabled}
              {...numbered(single.choices.length + (single.property.isRequired ? 0 : 1))}
              onClick={() => go("decline", "decline")}>No thanks{decline.telling}</button>
            {sayWhy("decline", numbered(single.choices.length + (single.property.isRequired ? 1 : 2)))}
          </div>
        </>
      );
    } else {
      const pages = pagesOf(schema);
      const last = pages.length - 1;
      const page = Math.min(Math.max(step.value, 0), last);
      const problems = schema.properties.map((p) => problem(p, values.value[p.name])).filter((p): p is string => p !== null);
      const set = (name: string, value: JSONValue) => (values.value = { ...values.value, [name]: value });
      body = (
        <>
          {schema.description && <p class="quiet">{schema.description}</p>}
          <div class={`page${hold.answered === "sending" ? " held" : ""}`}>
            {pages[page]!.map((property) => (
              <Field key={property.name} property={property} value={values.value[property.name]} inert={inert}
                set={(value) => set(property.name, value)}
                chose={() => { if (page < last) step.value = page + 1; }} />
            ))}
          </div>
          <div class="form-row">
            {last > 0 && (
              <>
                <button aria-label="Previous question" disabled={page === 0} onClick={() => (step.value = page - 1)}>‹</button>
                <span class="quiet small">{page + 1}/{pages.length}</span>
              </>
            )}
            <span class="spacer" />
            {page === last && problems[0] && <span class="quiet small">{problems[0]}</span>}
            <button class={decline.class} aria-disabled={decline.disabled} onClick={() => go("decline", "decline")}>No thanks{decline.telling}</button>
            {sayWhy("decline")}
            {page < last && <button onClick={() => (step.value = page + 1)}>Next</button>}
            {page === last && (() => {
              const submit = button("submit", "prominent");
              return (
                <button class={submit.class} disabled={problems.length > 0} aria-disabled={submit.disabled} data-default=""
                  onClick={() => go("submit", "accept", values.value)}>Submit{submit.telling}</button>
              );
            })()}
          </div>
        </>
      );
    }
  }
  return (
    <section ref={card} class={cardClass(hold)} aria-label="Question">
      {asker && <p class="quiet small asker">{asker}</p>}
      {((!request.secret && !request.handOff) || because.value !== null) && <div class="strong"><Markdown text={title} /></div>}
      {!request.secret && !request.handOff && because.value === null && message && <Markdown text={message} />}
      {body}
      <AnsweredNote answered={hold.answered} />
    </section>
  );
}

/** One of a card's answers, as ElicitationCard's `button` gives it. */
interface AnswerButton { class: string | undefined; disabled: boolean; telling: ComponentChildren }

/** The control that opens DeclineReason, as the window's and the Remote's DeclineReasonField.opener. */
const declineReasonOpener = "No, because…";

/**
 * Why the person declines a form (#4039): one line, Back and Send. Return sends and Escape goes
 * back. The agent reads what is typed; an empty line declines with no reason, as No thanks does.
 * As the window's and the Remote's DeclineReasonField.
 */
function DeclineReason({ inert, sent, back, send }: {
  inert: boolean; sent: AnswerButton; back: () => void; send: (reason: string) => void;
}) {
  const reason = useSignal("");
  return (
    <>
      <label class="field">
        <input type="text" autofocus disabled={inert} placeholder="Why not? The agent reads this" aria-label="Why not? The agent reads this"
          value={reason.value} onInput={(e) => (reason.value = (e.currentTarget as HTMLInputElement).value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              send(reason.value);
            } else if (e.key === "Escape") {
              e.preventDefault();
              back();
            }
          }} />
      </label>
      <div class="form-row">
        <span class="spacer" />
        <button disabled={inert} onClick={back}>Back</button>
        <button class={sent.class} aria-disabled={sent.disabled} onClick={() => send(reason.value)}>Send{sent.telling}</button>
      </div>
    </>
  );
}

/**
 * An agent's hand_to_person (#3529): the step, why, Open the page, Done, and Can't do it with a
 * line for what stopped the person. As the window's and the Remote's HandOffCard.
 */
function HandOffField({ handOff, inert, open, recipient, done, cannot, send }: {
  handOff: ElicitationHandOff; inert: boolean; open: (() => void) | undefined; recipient: string; done: AnswerButton; cannot: AnswerButton;
  send: (done: boolean, note: string) => void;
}) {
  const saying = useSignal(false);
  const note = useSignal("");
  return (
    <>
      <p class="strong secret"><span aria-hidden="true">✋ </span>{handOff.step}</p>
      {handOff.reason && <p class="secret">{handOff.reason}</p>}
      {/* A step in one of the agents' own Chrome windows (#5095): no page here, so say where. */}
      {handOff.window && <p class="small quiet">{handOffWindowWords(handOff.window, recipient)}</p>}
      {saying.value && (
        <label class="field">
          <input type="text" autofocus disabled={inert} placeholder="What stopped you (optional)" aria-label="What stopped you (optional)"
            value={note.value} onInput={(e) => (note.value = (e.currentTarget as HTMLInputElement).value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                send(false, note.value);
              }
            }} />
        </label>
      )}
      <div class="form-row">
        {!saying.value && open && !handOff.window && <button class="prominent" disabled={inert} data-default="" onClick={open}>Open the page</button>}
        <span class="spacer" />
        {saying.value ? (
          <>
            <button disabled={inert} onClick={() => (saying.value = false)}>Back</button>
            <button class={cannot.class} aria-disabled={cannot.disabled} onClick={() => send(false, note.value)}>Send{cannot.telling}</button>
          </>
        ) : (
          <>
            <button disabled={inert} onClick={() => (saying.value = true)}>Can't do it</button>
            <button class={done.class} aria-disabled={done.disabled} onClick={() => send(true, "")}>Done{done.telling}</button>
          </>
        )}
      </div>
    </>
  );
}

/**
 * An agent's ask_secret (#2885): its name, why, where to get it, and a masked field. What is
 * typed goes to the host, which seals it in the person's store, or keeps it for this
 * session only (#3548); the chat, the agent and every other client get the name only. Ask before
 * use (#4016) is on unless the person turns it off. As the window's and the Remote's SecretAskCard.
 */
function SecretField({ secret, reason, recipient, inert, save, decline, sayWhy, send }: {
  secret: ElicitationSecret; reason: string | undefined; recipient: string; inert: boolean;
  save: AnswerButton; decline: AnswerButton; sayWhy: ComponentChildren;
  send: (typed: string | null, sessionOnly: boolean, askBeforeUse: boolean | null, description: string) => void;
}) {
  const text = useSignal("");
  // The agent's description (#4167), for the person to change.
  const description = useSignal(secret.description ?? "");
  const sessionOnly = useSignal(false);
  const askBeforeUse = useSignal(true);
  const forSession = sessionOnly.value && secret.canBeSessionOnly === true;
  // A host with no such flag is sent none.
  const ask = secret.canAskBeforeUse === true ? askBeforeUse.value : null;
  const typed = text.value.trim();
  const link = getIt(secret.url);
  return (
    <>
      <p class="strong secret"><span aria-hidden="true">🔒 </span><code>{secret.name}</code></p>
      {reason && <p class="secret">{reason}</p>}
      {link && secret.url && <p class="secret"><a href={secret.url} target="_blank" rel="noopener noreferrer">{link}</a></p>}
      <label class="field">
        <input type="password" autocomplete="off" spellcheck={false} autofocus disabled={inert}
          aria-label={secret.name} placeholder={`Paste ${secret.name}`} value={text.value}
          onInput={(e) => (text.value = (e.currentTarget as HTMLInputElement).value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && typed) {
              e.preventDefault();
              send(typed, forSession, ask, description.value.trim());
            }
          }} />
        <span class="quiet small">{forSession ? keepingForSession(recipient) : keeping(secret, recipient)}</span>
      </label>
      <label class="field">
        <textarea aria-label={descriptionLabel} placeholder={descriptionPrompt} rows={2} disabled={inert} value={description.value}
          onInput={(e) => (description.value = (e.currentTarget as HTMLTextAreaElement).value)} />
        <span class="quiet small">{descriptionHint}</span>
      </label>
      {secret.canBeSessionOnly && (
        <label class="field check">
          <input type="checkbox" checked={sessionOnly.value} disabled={inert}
            onChange={(e) => (sessionOnly.value = (e.currentTarget as HTMLInputElement).checked)} />
          {" "}{sessionSecretWords.toggle}
        </label>
      )}
      {secret.canAskBeforeUse && (
        <div class="field">
          <label>
            <input type="checkbox" checked={askBeforeUse.value} disabled={inert}
              onChange={(e) => (askBeforeUse.value = (e.currentTarget as HTMLInputElement).checked)} />
            {" "}{askBeforeUseWords.toggle}
          </label>
          <span class="quiet small">{askBeforeUseHint(askBeforeUse.value)}</span>
        </div>
      )}
      <div class="form-row">
        <span class="spacer" />
        <button class={decline.class} aria-disabled={decline.disabled} onClick={() => send(null, false, null, "")}>No thanks{decline.telling}</button>
        {sayWhy}
        <button class={save.class} disabled={!typed} aria-disabled={save.disabled} data-default=""
          onClick={() => send(typed, forSession, ask, description.value.trim())}>Save securely{save.telling}</button>
      </div>
    </>
  );
}

function Field({ property, value, inert, set, chose }: {
  property: ElicitationSchemaProperty; value: JSONValue | undefined; inert: boolean;
  set: (value: JSONValue) => void; chose: () => void;
}) {
  const label = property.title ?? property.name;
  const asked = (
    <div class="asked"><div class="strong"><Markdown text={label} /></div>{property.isRequired && <span class="small faint"> needed</span>}</div>
  );
  const choices = choicesOf(property);
  const kind = property.kind;
  // Under every field once it has an answer, as the window's (#256), not only in the footer.
  const wrong = value !== undefined ? problem(property, value) : null;
  const said = wrong && <span class="failure small">{wrong}</span>;
  if (choices) {
    return (
      <div class="field">
        {asked}
        {property.description && <p class="quiet small">{property.description}</p>}
        <div class="options">
          {choices.map((choice, index) => (
            <button key={choice.value} class={value === choice.value ? "prominent" : ""} aria-pressed={value === choice.value}
              {...numbered(index)}
              aria-disabled={inert} onClick={() => { if (!inert) { set(choice.value); chose(); } }}>
              {choice.title}{choice.description && <span class="small quiet">{choice.description}</span>}
            </button>
          ))}
        </div>
        {said}
      </div>
    );
  }
  if ("multiSelect" in kind) {
    const picked = Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
    return (
      <div class="field">
        {asked}
        {property.description && <p class="quiet small">{property.description}</p>}
        <div class="options">
          {kind.multiSelect.items.map((item) => {
            const on = picked.includes(item.value);
            return (
              <button key={item.value} class={on ? "prominent" : ""} aria-pressed={on} aria-disabled={inert}
                {...numbered(kind.multiSelect.items.indexOf(item))}
                onClick={() => !inert && set(on ? picked.filter((v) => v !== item.value) : [...picked, item.value])}>
                {item.title}{item.description && <span class="small quiet">{item.description}</span>}
              </button>
            );
          })}
        </div>
        {said}
      </div>
    );
  }
  if ("boolean" in kind) {
    return (
      <label class="field check">
        <input type="checkbox" checked={value === true} disabled={inert}
          onChange={(e) => set((e.currentTarget as HTMLInputElement).checked)} /> {label}
        {property.description && <span class="quiet small"> {property.description}</span>}
        {said}
      </label>
    );
  }
  const numeric = "number" in kind || "integer" in kind;
  // A date, a date-time, an email address or a link gets the browser's own input for it (#265).
  const format = "string" in kind ? kind.string.format : undefined;
  const type = numeric ? "number" : inputType(format);
  const shown = typeof value === "string" || typeof value === "number" ? String(value) : "";
  return (
    <label class="field">
      {asked}
      <input type={type as "text"} disabled={inert} placeholder={placeholder(format)}
        value={type === "datetime-local" ? momentToInput(shown) : shown}
        onInput={(e) => {
          const text = (e.currentTarget as HTMLInputElement).value;
          if (type === "datetime-local") set(text === "" ? "" : momentFromInput(text));
          else if (!numeric || text === "") set(text);
          else set("integer" in kind ? (Number.isInteger(Number(text)) ? Number(text) : text) : Number(text));
        }} />
      {property.description && <span class="quiet small">{property.description}</span>}
      {said}
    </label>
  );
}
