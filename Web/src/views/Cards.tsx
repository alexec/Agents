// Permission requests and question cards above the prompt (071 FR-024; PermissionView.swift and
// ElicitationView.swift). Answering one here answers it everywhere. One answered somewhere else
// while it is on screen says so, and its buttons do nothing (US2 scenario 5).
//
// The first card takes keys, as the window's do (#256): Return its first real answer when no field
// has the keys, and ⌥1…9 its answers by position. The window's are ⌘1…9; a browser keeps those for
// its tabs, so the page's are on Option.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type {
  ElicitationRequest, ElicitationSchema, ElicitationSchemaProperty, ElicitationSchemaPropertyChoice, JSONValue,
  PermissionOption, PermissionRequest, UUID,
} from "../protocol/generated";
import type { Store } from "../model/store";
import { CallFailed } from "../wire/link";
import { describe } from "../model/errors";
import { Failure } from "../protocol/generated";
import { isSafeLink } from "../render/markdown";
import { elicitationTitle } from "./chat/Rows";
import { askerFor } from "../model/asker";
import { planOf } from "../model/plan";
import { Markdown } from "../render/markdown";
import { inputType, momentFromInput, momentToInput, placeholder } from "../model/formInputs";

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

export function Cards({ store, host, session, down = false }: {
  store: Store; host: string; session: string;
  /** Its host is down: the answers are held, greyed, until it is back, as the window's are (#83). */
  down?: boolean;
}) {
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
      setTimeout(() => (held.value = held.value.filter((c) => !(ids.has(c.request.id) && settled(c)))),
        answeredElsewhereShownFor);
    }
  }, [[...live].join(","), session]);


  const mark = (id: string, answered: Answered) => {
    held.value = held.value.map((c) => (c.request.id === id ? { ...c, answered } : c));
  };
  /**
   * Sends an answer. A refusal means it was no longer waiting: answered somewhere else. While it
   * is on its way the button that sent it says so and every other answer is held, so a second
   * click is not a second answer; they come back if it fails (#86).
   */
  const send = async (id: string, chosen: string, call: (sendID: UUID) => Promise<unknown>) => {
    const card = held.value.find((c) => c.request.id === id);
    if (!card || card.answered !== null) return;
    const sendID = card.sendID ?? (crypto.randomUUID().toUpperCase() as UUID);
    held.value = held.value.map((c) => (c.request.id === id ? { ...c, answered: "sending", chosen, sendID } : c));
    try {
      await call(sendID);
      mark(id, "here");
      held.value = held.value.filter((c) => c.request.id !== id);
    } catch (error) {
      // The host refusing means it was no longer waiting; the link dropping, or the host
      // being away, means try again.
      const away = !(error instanceof CallFailed) || error.code === Failure.hostOffline;
      if (away) store.say(describe(error));
      mark(id, away ? null : "elsewhere");
    }
  };

  const cards = held.value.filter((c) => c.answered !== "here");
  if (!cards.length) return null;
  const recipient = host === "mac" ? "your Mac" : store.hosts.value.find((h) => h.id === host)?.name ?? "the host";
  // Who is asking, by title and runtime (#121).
  const runtimeName = (id: string) => (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === id)?.runtime.name;
  const asker = (agentID: string, subagent?: string) =>
    askerFor(store.agents.value[host] ?? [], agentID, runtimeName, subagent);
  return (
    <div class="cards" aria-label="Waiting for you">
      {cards.map((card, index) => card.kind === "permission"
        ? <PermissionCard key={card.request.id} active={index === 0} request={card.request} asker={asker(card.request.agentID, card.request.subagent)}
            // Shown as the host shows it: the page beside the chat, read again (the window's Show plan).
            showPlan={(path) => (store.shownFile.value = { host, agentID: card.request.agentID, path, at: Date.now() })}
            hold={{ answered: card.answered, chosen: card.chosen, recipient, down }}
            answer={(option) => send(card.request.id, option.optionID, (sendID) => store.link.call("permissions/answer",
              { permissionID: card.request.id, optionID: option.optionID, sendID }, host))} />
        : <ElicitationCard key={card.request.id} active={index === 0} request={card.request} asker={asker(card.request.agentID)}
            hold={{ answered: card.answered, chosen: card.chosen, recipient, down }}
            answer={(key, action, content) => send(card.request.id, key, (sendID) => store.link.call("elicitations/answer",
              { requestID: card.request.id, action, content, sendID }, host))} />)}
    </div>
  );
}

function AnsweredNote({ answered }: { answered: Answered }) {
  if (answered === "elsewhere") return <p class="answered" role="status">Answered on another device.</p>;
  if (answered === "withdrawn") return <p class="answered" role="status">The session stopped before this was answered.</p>;
  return null;
}

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

function ElicitationCard({ request, asker, hold, answer, active }: {
  request: ElicitationRequest; asker: string | null; hold: Hold; answer: (key: string, action: Action, content: Record<string, JSONValue>) => void;
  active: boolean;
}) {
  const card = useRef<HTMLElement>(null);
  useCardKeys(card, active);
  const inert = hold.answered !== null || hold.down;
  // Each card is its own request (keyed by its id above), so its defaults are where it starts.
  // Filled in an effect instead, they landed after the first paint, and a choice made before
  // then was wiped: the form went back empty (the closing walk, T071).
  const values = useSignal<Record<string, JSONValue>>(defaultsOf(request));
  const step = useSignal(0);
  const title = elicitationTitle(request);
  const go = (key: string, action: Action, content: Record<string, JSONValue> = {}) => !inert && answer(key, action, content);
  /** One of the card's answers, by its key: its class beside `base`, held state and pending mark. */
  const button = (key: string, base = "") => {
    const h = holding(hold, key);
    return { class: `${base} ${h.class}`.trim() || undefined, disabled: h.disabled, telling: h.telling };
  };
  const done = button("done"), gaveUp = button("gave-up"), none = button("none"), decline = button("decline");

  let body;
  if ("url" in request.mode) {
    const url = request.mode.url._0;
    body = (
      <div class="options row-options">
        {isSafeLink(url) && <a class="button prominent" href={url} target="_blank" rel="noopener noreferrer" data-default="">Open</a>}
        <button class={done.class} aria-disabled={done.disabled} {...numbered(0)} onClick={() => go("done", "accept")}>Done{done.telling}</button>
        <button class={gaveUp.class} aria-disabled={gaveUp.disabled} {...numbered(1)} onClick={() => go("gave-up", "decline")}>Gave up{gaveUp.telling}</button>
      </div>
    );
  } else {
    const schema = request.mode.form._0;
    const single = singleChoice(schema);
    if (single) {
      body = (
        <>
          {schema.description && <p class="quiet">{schema.description}</p>}
          <div class="options row-options">
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
            {!single.property.isRequired && (
              <button class={none.class} aria-disabled={none.disabled} {...numbered(single.choices.length)}
                onClick={() => go("none", "accept", { [single.property.name]: "" })}>No answer{none.telling}</button>
            )}
            <button class={decline.class} aria-disabled={decline.disabled}
              {...numbered(single.choices.length + (single.property.isRequired ? 0 : 1))}
              onClick={() => go("decline", "decline")}>No thanks{decline.telling}</button>
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
      <p class="strong">{title}</p>
      {request.message && request.message !== title && <p>{request.message}</p>}
      {body}
      <AnsweredNote answered={hold.answered} />
    </section>
  );
}

function Field({ property, value, inert, set, chose }: {
  property: ElicitationSchemaProperty; value: JSONValue | undefined; inert: boolean;
  set: (value: JSONValue) => void; chose: () => void;
}) {
  const label = property.title ?? property.name;
  const asked = (
    <p class="asked"><span class="strong">{label}</span>{property.isRequired && <span class="small faint"> needed</span>}</p>
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
