// Start a Machine from a Repository (#1809): the repository, a provider that makes machines, its
// New Workspace form, and Start. What comes next is said in the sheet: joining on its first boot,
// or made but to add as a host in the Mac app.
import { useEffect, useState } from "preact/hooks";
import type { ProviderID } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import {
  createRequest, formFields, machineName, machineWords as words, makers, nameSuffix, repositoryOf, type FormField,
} from "../model/machineFromRepository";
import { Modal } from "./Modal";

export function MachineDialog({ store, close }: { store: Store; close: () => void }) {
  const providers = store.providers.list.value;
  const [text, setText] = useState("");
  const [provider, setProvider] = useState("");
  const [fields, setFields] = useState<FormField[]>([]);
  const [suffix] = useState(nameSuffix);
  const [step, setStep] = useState<{ kind: "asking" } | { kind: "starting" } | { kind: "said"; words: string; failed?: true }>({ kind: "asking" });
  useEffect(() => { if (providers === null) void store.providers.load(); }, []);
  const choices = makers(providers ?? []);
  const chosen = provider || choices[0]?.id || "";
  // The provider's form, each time another is chosen.
  useEffect(() => {
    if (!chosen) return;
    let live = true;
    void store.link.call("providers/options", { id: chosen as ProviderID })
      .then((o) => { if (live) setFields(formFields(o.schema)); })
      .catch(() => { if (live) setFields([]); });
    return () => { live = false; };
  }, [chosen]);
  const repository = repositoryOf(text);
  const name = repository ? machineName(repository.name, suffix) : "";
  const start = async () => {
    if (!repository || !chosen) return;
    setStep({ kind: "starting" });
    try {
      const made = await store.link.call("providers/create", createRequest(chosen, name, repository, fields));
      const by = choices.find((p) => p.id === chosen)?.name ?? "The provider";
      setStep({ kind: "said", words: made.joining ? words.joining(made.workspace.name, repository) : words.notJoining(made.workspace.name, by) });
    } catch (error) {
      setStep({ kind: "said", words: describe(error), failed: true });
    }
  };
  const busy = step.kind === "starting";
  const done = step.kind === "said" && !step.failed;
  return (
    <Modal label={words.title} close={close}>
      <form class="sheet-body connect-sheet provider-sheet" onSubmit={(e) => { e.preventDefault(); void start(); }}>
        <h2>{words.title}</h2>
        {providers !== null && choices.length === 0 ? <p class="sheet-note">{words.noMakers}</p> : (
          <div class="token-form">
            <label>Repository
              <input type="url" value={text} placeholder={words.repositoryPrompt} disabled={busy || done} autofocus
                autocomplete="off" autocapitalize="off" spellcheck={false}
                onInput={(e) => setText((e.target as HTMLInputElement).value)} />
            </label>
            <p class={`small ${repository || !text.trim() ? "quiet" : "failure"}`}>{words.repositoryNote(repository, !!text.trim())}</p>
            <label>Provider
              <select value={chosen} disabled={busy || done} onChange={(e) => setProvider((e.target as HTMLSelectElement).value)}>
                {choices.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select>
            </label>
            {fields.map((f, i) => (
              <label key={f.key} title={f.description}>{f.title}
                {f.choices
                  ? <select value={f.value} disabled={busy || done}
                      onChange={(e) => setFields(fields.map((g, j) => (j === i ? { ...g, value: (e.target as HTMLSelectElement).value } : g)))}>
                      {f.choices.map((c) => <option key={c} value={c}>{c}</option>)}
                    </select>
                  : <input type="text" value={f.value} disabled={busy || done} autocomplete="off" spellcheck={false}
                      onInput={(e) => setFields(fields.map((g, j) => (j === i ? { ...g, value: (e.target as HTMLInputElement).value } : g)))} />}
              </label>
            ))}
            {name && <p class="small quiet">Its name: {name}. {words.privateNote}</p>}
          </div>
        )}
        {busy && <p class="quiet small">{words.starting(name)}</p>}
        {step.kind === "said" && <p class={`small${step.failed ? " failure" : ""}`}>{step.words}</p>}
        <div class="sheet-actions">
          {done ? <button type="button" class="prominent" onClick={close}>Done</button> : (
            <>
              <button type="button" onClick={close}>Cancel</button>
              <button type="submit" class="prominent" disabled={!repository || !chosen || busy}>{words.start}</button>
            </>
          )}
        </div>
      </form>
    </Modal>
  );
}
