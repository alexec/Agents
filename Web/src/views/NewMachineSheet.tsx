// New Machine (#4634), as the window's NewMachineSheet: the provider (a picker with two or more), the name and the
// provider's form, every field already on what New Machine would make (the options used last on the provider, else
// its first choices) and the next machine-N. Make is the confirmation, and closes the sheet: the Machines group's
// Making row takes over. A make the provider refuses opens it again on the same choices, with the reason.
import { useEffect, useState } from "preact/hooks";
import type { JSONValue, ProviderID } from "../protocol/generated";
import type { NewMachineAsk, Store } from "../model/store";
import { describe } from "../model/errors";
import { choiceLabel, createRequest, formFields, makers, withValues, type FormField } from "../model/machineFromRepository";
import { addMachineWords, validMachineName } from "../model/addMachine";
import { Modal } from "./Modal";

export function NewMachineSheet({ store, ask }: { store: Store; ask: NewMachineAsk }) {
  const providers = store.providers.list.value;
  const choices = makers(providers ?? []);
  const [provider, setProvider] = useState(ask.again?.provider ?? ask.provider ?? "");
  const [name, setName] = useState(ask.again?.name ?? "");
  const [fields, setFields] = useState<FormField[]>([]);
  const [loading, setLoading] = useState(true);
  const [problem, setProblem] = useState(ask.problem);
  useEffect(() => { if (providers === null) void store.providers.load(); }, []);
  const close = () => { store.newMachineAsk.value = null; };
  // The provider's form and what New Machine would make, each time another provider is chosen. The first time, a
  // refused make's own choices are kept.
  const [kept, setKept] = useState(ask.again);
  useEffect(() => {
    let live = true;
    setLoading(true);
    void store.link.call("providers/options", provider ? { id: provider as ProviderID } : {})
      .then((o) => {
        if (!live) return;
        if (o.id) setProvider(o.id);
        const form = formFields(o.schema);
        setFields(withValues(form, kept ? kept.options : o.values));
        if (!kept && (!name || name.startsWith("machine-")) && o.name) setName(o.name);
        setKept(undefined);
      })
      .catch((error: unknown) => { if (live) { setFields([]); setProblem(describe(error)); } })
      .finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [provider]);
  const named = name.trim();
  const ready = !!provider && !loading && validMachineName(named);
  const cost = fields.map((f) => f.costs?.[f.value]).filter((c): c is string => !!c).join(" · ");
  const make = () => {
    if (!ready) return;
    const request = createRequest(provider, named, null, fields);
    close();
    void store.makeMachine({ provider, name: named, options: (request.options ?? {}) as Record<string, JSONValue> });
  };
  const set = (i: number, value: string) => setFields(fields.map((g, j) => (j === i ? { ...g, value } : g)));
  const title = choices.length > 1 || !choices[0] ? "New Machine" : `New Machine on ${choices[0].name}`;
  return (
    <Modal label={title} close={close}>
      <form class="sheet-body connect-sheet provider-sheet" onSubmit={(e) => { e.preventDefault(); make(); }}>
        <h2>{title}</h2>
        <div class="token-form">
          {choices.length > 1 && (
            <label>Provider
              <select value={provider} onChange={(e) => setProvider((e.target as HTMLSelectElement).value)}>
                {choices.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select>
            </label>
          )}
          <label>Name
            <input type="text" value={name} placeholder="machine-1" autofocus
              autocomplete="off" autocapitalize="off" spellcheck={false}
              onInput={(e) => setName((e.target as HTMLInputElement).value)} />
          </label>
          {named && !validMachineName(named) && <p class="small failure">{addMachineWords.nameNote}</p>}
          {loading ? <p class="small quiet">Reading the provider’s choices…</p> : fields.map((f, i) => (
            <label key={f.key} title={f.description}>{f.title}
              {f.choices
                ? <select value={f.value} onChange={(e) => set(i, (e.target as HTMLSelectElement).value)}>
                    {f.choices.map((c) => <option key={c} value={c}>{choiceLabel(f, c)}</option>)}
                  </select>
                : <input type="text" value={f.value} autocomplete="off" spellcheck={false}
                    onInput={(e) => set(i, (e.target as HTMLInputElement).value)} />}
            </label>
          ))}
        </div>
        {problem && <p class="small failure" role="alert">{problem}</p>}
        <p class="small quiet">It joins as a machine by itself once it has started. The provider charges for it from when it is made.</p>
        <div class="sheet-actions">
          {cost && <span class="small quiet">{cost}</span>}
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={!ready}>Make</button>
        </div>
      </form>
    </Modal>
  );
}
