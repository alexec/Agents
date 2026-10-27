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
