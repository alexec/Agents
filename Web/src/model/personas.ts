// Personas (#760): a kind of session picked on the New Agent page. Persona.choices
// (Model/Persona.swift) ported by hand: each key the persona names that the runtime offers, on its
// own, so a model this runtime lacks leaves the model as the form has it and the rest still apply.
import type { ConfigOption, JSONValue, Persona } from "../protocol/generated";
import { choices, modeOption } from "./options";
import { effortOption, fileBoolean, modelOption } from "./workflowSettings";

/** The advertised choice a file's word names (WorkflowSettings.choice). */
function named(option: ConfigOption | undefined, word: string): JSONValue | undefined {
  return option && choices(option).find((c) => c.value === word)?.value;
}

/** The option values to lay over the form's choices, by option id. */
export function personaChoices(persona: Persona, advertised: readonly ConfigOption[]): Record<string, JSONValue> {
  const values: Record<string, JSONValue> = {};
  const { permissionMode, model, effort, options } = persona.settings;
  for (const [option, word] of [[modeOption(advertised), permissionMode], [modelOption(advertised), model],
    [effortOption(advertised), effort]] as const) {
    if (word === undefined || !option) continue;
    const value = named(option, word);
    if (value !== undefined) values[option.id] = value;
  }
  for (const id of Object.keys(options ?? {}).sort()) {
    const word = options![id]!;
    const option = advertised.find((o) => o.id === id);
    if (!option) continue;
    if (option.type === "boolean") {
      const flag = fileBoolean(word);
      if (flag !== null) values[id] = flag;
    } else if (option.type === "select") {
      const value = named(option, word);
      if (value !== undefined) values[id] = value;
    }
  }
  return values;
}

/** The form's labels when the picked persona changes (#2649): the last one's go, unless the new
 *  one names them too, and the new one's go beside the rest, each once. */
export function withPersonaLabels(labels: readonly string[], last: Persona | undefined, persona: Persona | undefined): string[] {
  const kept = new Set((persona?.settings.labels ?? []).map((l) => l.toLowerCase()));
  const gone = new Set((last?.settings.labels ?? []).map((l) => l.toLowerCase()).filter((l) => !kept.has(l)));
  const left = labels.filter((l) => !gone.has(l.toLowerCase()));
  const have = new Set(left.map((l) => l.toLowerCase()));
  return [...left, ...(persona?.settings.labels ?? []).filter((l) => !have.has(l.toLowerCase()) && have.add(l.toLowerCase()))];
}

/** The live pick on the New Agent page (#4559, #4721), always on until a hand pick: the persona the first prompt's words name, and the word.
 *  Persona.autoPick (Model/PersonaAutoPick.swift) ported by hand: a keyword counts once it is a
 *  whole word, followed by a space or punctuation; most matches wins, the earliest breaks a tie. */
export interface AutoPick { persona: Persona; word: string }

/** The keyword that stands for any issue number, such as `#123`. */
export const issueNumberKeyword = "#<n>";

const commonWords = new Set(["about", "after", "before", "every", "other", "their", "there",
  "these", "those", "until", "where", "which", "while", "would"]);
const isWord = (c: string | undefined) => c !== undefined && /[\p{L}\p{N}]/u.test(c);

/** Its `keywords:`, else the longer words of its name and description. */
export function autoWords(persona: Persona): string[] {
  if (persona.keywords && persona.keywords.length > 0) return persona.keywords;
  const seen = new Set<string>();
  return [persona.name, persona.description ?? ""].flatMap((s) => s.split(/[^\p{L}\p{N}]+/u))
    .filter((w) => [...w].length >= 5 && !commonWords.has(w.toLowerCase()))
    .filter((w) => !seen.has(w.toLowerCase()) && seen.add(w.toLowerCase()));
}

function matches(keyword: string, text: string[]): { at: number; word: string }[] {
  const wanted = keyword.trim();
  const found: { at: number; word: string }[] = [];
  if (wanted === issueNumberKeyword) {
    text.forEach((c, i) => {
      if (c !== "#" || isWord(text[i - 1])) return;
      let end = i + 1;
      while (end < text.length && /[0-9]/.test(text[end]!)) end++;
      if (end > i + 1 && end < text.length && !isWord(text[end])) found.push({ at: i, word: text.slice(i, end).join("") });
    });
    return found;
  }
  const word = [...wanted.toLowerCase()];
  if (word.length === 0 || word.length >= text.length) return found;
  for (let i = 0; i + word.length < text.length; i++) {
    if (word.every((c, j) => text[i + j] === c) && !isWord(text[i - 1]) && !isWord(text[i + word.length])) {
      found.push({ at: i, word: wanted });
    }
  }
  return found;
}

/** The persona `prompt` names, or undefined when none matches. */
export function autoPersona(prompt: string, personas: readonly Persona[]): AutoPick | undefined {
  const text = [...prompt.toLowerCase()];
  let best: { pick: AutoPick; count: number; first: number } | undefined;
  for (const persona of personas) {
    if (persona.problem !== undefined) continue;
    let count = 0;
    let first: { at: number; word: string } | undefined;
    for (const keyword of autoWords(persona)) {
      for (const match of matches(keyword, text)) {
        count++;
        if (!first || match.at < first.at) first = match;
      }
    }
    if (!first) continue;
    if (!best || count > best.count || (count === best.count && first.at < best.first)) {
      best = { pick: { persona, word: first.word }, count, first: first.at };
    }
  }
  return best?.pick;
}

/** The grey line under the control while the pick is live: what it picked, and the word. */
export const autoLine = (pick: AutoPick | undefined) =>
  pick ? `Auto picked ${pick.persona.name}: "${pick.word}"` : "Auto picks a persona from the words you type";
