// Permission requests and question cards above the prompt (071 FR-024; PermissionView.swift and
// ElicitationView.swift). Answering one here answers it everywhere. One answered somewhere else
// while it is on screen says so, and its buttons do nothing (US2 scenario 5).
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type {
  ElicitationRequest, ElicitationSchema, ElicitationSchemaProperty, ElicitationSchemaPropertyChoice, JSONValue,
  PermissionOption, PermissionRequest,
} from "../protocol/generated";
import type { Store } from "../model/store";
import { CallFailed } from "../wire/link";
import { describe } from "../model/errors";
import { Failure } from "../protocol/generated";
import { isSafeLink } from "../render/markdown";
import { elicitationTitle } from "./chat/Rows";

type Held =
  | { kind: "permission"; request: PermissionRequest; answered: Answered }
  | { kind: "elicitation"; request: ElicitationRequest; answered: Answered };
/**
 * null while it waits; "here" once this page answered; "elsewhere" when another client did;
 * "withdrawn" when the session stopped before anyone answered.
 */
type Answered = null | "sending" | "here" | "elsewhere" | "withdrawn";

/** What the host writes when a question goes because its agent ended (RuntimeNote.swift). */
const questionWentUnanswered = "Nobody answered this question before the agent ended.";

/** How long a card answered elsewhere stays to say so. */
const answeredElsewhereShownFor = 4_000;

export function Cards({ store, host, session }: { store: Store; host: string; session: string }) {
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
  useEffect(() => {
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

  useEffect(() => { held.value = []; }, [session]);

  const mark = (id: string, answered: Answered) => {
    held.value = held.value.map((c) => (c.request.id === id ? { ...c, answered } : c));
  };
  /** Sends an answer. A refusal means it was no longer waiting: answered somewhere else. */
  const send = async (id: string, call: () => Promise<unknown>) => {
    const card = held.value.find((c) => c.request.id === id);
    if (!card || card.answered !== null) return;
    mark(id, "sending");
    try {
      await call();
      mark(id, "here");
      held.value = held.value.filter((c) => c.request.id !== id);
    } catch (error) {
      // The host refusing means it was no longer waiting; the link dropping, or the host
      // being away, means try again.
      const away = !(error instanceof CallFailed) || error.code === Failure.hostOffline;
      if (away) store.problem.value = describe(error);
      mark(id, away ? null : "elsewhere");
    }
  };

  const cards = held.value.filter((c) => c.answered !== "here");
  if (!cards.length) return null;
  return (
    <div class="cards" aria-label="Waiting for you">
      {cards.map((card) => card.kind === "permission"
        ? <PermissionCard key={card.request.id} request={card.request} answered={card.answered}
            answer={(option) => send(card.request.id, () => store.link.call("permissions/answer",
              { permissionID: card.request.id, optionID: option.optionID }, host))} />
        : <ElicitationCard key={card.request.id} request={card.request} answered={card.answered}
            answer={(action, content) => send(card.request.id, () => store.link.call("elicitations/answer",
              { requestID: card.request.id, action, content }, host))} />)}
    </div>
  );
}

function AnsweredNote({ answered }: { answered: Answered }) {
  if (answered === "elsewhere") return <p class="answered" role="status">Answered on another device.</p>;
  if (answered === "withdrawn") return <p class="answered" role="status">The session stopped before this was answered.</p>;
  if (answered === "sending") return <p class="answered" role="status">Sending…</p>;
  return null;
}

const allows = (option: PermissionOption) => option.kind === "allow_once" || option.kind === "allow_always";

function PermissionCard({ request, answered, answer }: {
  request: PermissionRequest; answered: Answered; answer: (option: PermissionOption) => void;
}) {
  const inert = answered !== null;
  return (
    <section class={`card${inert ? " inert" : ""}`} aria-label="Permission request">
      <div class="question">
        {request.subagent && <p class="quiet small">Subagent “{request.subagent}” asks</p>}
        <p class="strong">{request.toolCall.title}</p>
        {request.toolCall.kind && <p class="quiet small">{request.toolCall.kind}</p>}
      </div>
      <div class="options">
        {request.options.map((option) => (
          <button key={option.optionID} class={allows(option) ? "prominent" : ""} aria-disabled={inert}
            onClick={() => !inert && answer(option)}>{option.name}</button>
        ))}
      </div>
      <AnsweredNote answered={answered} />
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

function ElicitationCard({ request, answered, answer }: {
  request: ElicitationRequest; answered: Answered; answer: (action: Action, content: Record<string, JSONValue>) => void;
}) {
  const inert = answered !== null;
  const values = useSignal<Record<string, JSONValue>>({});
  const step = useSignal(0);
  const title = elicitationTitle(request);
  const go = (action: Action, content: Record<string, JSONValue> = {}) => !inert && answer(action, content);
  useEffect(() => {
    step.value = 0;
    const defaults: Record<string, JSONValue> = {};
    if ("form" in request.mode) {
      for (const p of request.mode.form._0.properties) if (p.defaultValue !== undefined) defaults[p.name] = p.defaultValue;
    }
    values.value = defaults;
  }, [request.id]);

  let body;
  if ("url" in request.mode) {
    const url = request.mode.url._0;
    body = (
      <div class="options row-options">
        {isSafeLink(url) && <a class="button prominent" href={url} target="_blank" rel="noopener noreferrer">Open</a>}
        <button aria-disabled={inert} onClick={() => go("accept")}>Done</button>
        <button aria-disabled={inert} onClick={() => go("decline")}>Gave up</button>
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
            {single.choices.map((choice) => (
              <button key={choice.value} class="prominent" aria-disabled={inert}
                onClick={() => go("accept", { [single.property.name]: choice.value })}>
                {choice.title}{choice.description && <span class="small quiet">{choice.description}</span>}
              </button>
            ))}
            {!single.property.isRequired && (
              <button aria-disabled={inert} onClick={() => go("accept", { [single.property.name]: "" })}>No answer</button>
            )}
            <button aria-disabled={inert} onClick={() => go("decline")}>No thanks</button>
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
          <div class="page">
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
            <button aria-disabled={inert} onClick={() => go("decline")}>No thanks</button>
            {page < last && <button onClick={() => (step.value = page + 1)}>Next</button>}
            {page === last && (
              <button class="prominent" disabled={problems.length > 0} aria-disabled={inert}
                onClick={() => go("accept", values.value)}>Submit</button>
            )}
          </div>
        </>
      );
    }
  }
  return (
    <section class={`card${inert ? " inert" : ""}`} aria-label="Question">
      <p class="strong">{title}</p>
      {request.message && request.message !== title && <p>{request.message}</p>}
      {body}
      <AnsweredNote answered={answered} />
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
  if (choices) {
    return (
      <div class="field">
        {asked}
        {property.description && <p class="quiet small">{property.description}</p>}
        <div class="options">
          {choices.map((choice) => (
            <button key={choice.value} class={value === choice.value ? "prominent" : ""} aria-pressed={value === choice.value}
              aria-disabled={inert} onClick={() => { if (!inert) { set(choice.value); chose(); } }}>
              {choice.title}{choice.description && <span class="small quiet">{choice.description}</span>}
            </button>
          ))}
        </div>
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
                onClick={() => !inert && set(on ? picked.filter((v) => v !== item.value) : [...picked, item.value])}>
                {item.title}{item.description && <span class="small quiet">{item.description}</span>}
              </button>
            );
          })}
        </div>
      </div>
    );
  }
  if ("boolean" in kind) {
    return (
      <label class="field check">
        <input type="checkbox" checked={value === true} disabled={inert}
          onChange={(e) => set((e.currentTarget as HTMLInputElement).checked)} /> {label}
        {property.description && <span class="quiet small"> {property.description}</span>}
      </label>
    );
  }
  const numeric = "number" in kind || "integer" in kind;
  return (
    <label class="field">
      {asked}
      <input type={(numeric ? "number" : "text") as "text"} disabled={inert}
        value={typeof value === "string" || typeof value === "number" ? String(value) : ""}
        onInput={(e) => {
          const text = (e.currentTarget as HTMLInputElement).value;
          if (!numeric || text === "") set(text);
          else set("integer" in kind ? (Number.isInteger(Number(text)) ? Number(text) : text) : Number(text));
        }} />
      {property.description && <span class="quiet small">{property.description}</span>}
      {value !== undefined && problem(property, value) && <span class="failure small">{problem(property, value)}</span>}
    </label>
  );
}
