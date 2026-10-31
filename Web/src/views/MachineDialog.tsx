// Start a Machine from a Repository (#1809): the repository, a provider that makes machines, its
// New Machine form, and Start. What comes next is said in the sheet: joining on its first boot,
// or made but to add as a host in the Mac app. As New Machine (#2131), from Add a Machine… or a
// provider's New Machine…, the repository is optional and the machine is named here.
import { useEffect, useState } from "preact/hooks";
import type { ProviderID } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import {
  createRequest, formFields, machineName, machineWords as words, makers, nameSuffix, repositoryOf, type FormField,
} from "../model/machineFromRepository";
import { addMachineWords, validMachineName } from "../model/addMachine";
import { Modal } from "./Modal";

export function MachineDialog({ store, close, machine = false, picked }: {
  store: Store; close: () => void; machine?: boolean; picked?: string | undefined;
}) {
  const providers = store.providers.list.value;
  const [text, setText] = useState("");
  const [typedName, setTypedName] = useState("");
  const [provider, setProvider] = useState(picked ?? "");
  const [fields, setFields] = useState<FormField[]>([]);
  const [suffix] = useState(nameSuffix);
  const [step, setStep] = useState<{ kind: "asking" } | { kind: "starting" } | { kind: "said"; words: string; failed?: true }>({ kind: "asking" });
  useEffect(() => { if (providers === null) void store.providers.load(); }, []);
  const choices = makers(providers ?? []);
  const chosen = choices.find((p) => p.id === provider)?.id ?? choices[0]?.id ?? "";
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
  const typed = !!text.trim();
  const named = typedName.trim();
  const name = machine && named ? named : repository ? machineName(repository.name, suffix) : "";
  // A repository, or for New Machine a good name and no half-typed repository.
  const ready = !!chosen && (machine
    ? !(typed && !repository) && (named ? validMachineName(named) : !!repository)
    : !!repository);
  const start = async () => {
    if (!ready) return;
    setStep({ kind: "starting" });
    try {
      const made = await store.link.call("providers/create", createRequest(chosen, name, repository, fields));
      const by = choices.find((p) => p.id === chosen)?.name ?? "The provider";
      const said = !made.joining ? words.notJoining(made.workspace.name, by)
        : repository ? words.joining(made.workspace.name, repository) : addMachineWords.started(made.workspace.name);
      setStep({ kind: "said", words: said });
    } catch (error) {
      setStep({ kind: "said", words: describe(error), failed: true });
    }
  };
  const busy = step.kind === "starting";
  const done = step.kind === "said" && !step.failed;
  const title = machine ? addMachineWords.machineTitle : words.title;
  return (
    <Modal label={title} close={close}>
      <form class="sheet-body connect-sheet provider-sheet" onSubmit={(e) => { e.preventDefault(); void start(); }}>
        <h2>{title}</h2>
        {providers !== null && choices.length === 0 ? <p class="sheet-note">{words.noMakers}</p> : (
          <div class="token-form">
            {machine && (
              <>
                <label>Name
                  <input type="text" value={typedName} placeholder={addMachineWords.namePrompt} disabled={busy || done} autofocus
                    autocomplete="off" autocapitalize="off" spellcheck={false}
                    onInput={(e) => setTypedName((e.target as HTMLInputElement).value)} />
                </label>
                <p class={`small ${named && !validMachineName(named) ? "failure" : "quiet"}`}>{addMachineWords.nameNote}</p>
              </>
            )}
            <label>{machine ? addMachineWords.repositoryOptional : "Repository"}
              <input type="url" value={text} placeholder={words.repositoryPrompt} disabled={busy || done} autofocus={!machine}
                autocomplete="off" autocapitalize="off" spellcheck={false}
                onInput={(e) => setText((e.target as HTMLInputElement).value)} />
            </label>
            {(!machine || typed) && <p class={`small ${repository || !typed ? "quiet" : "failure"}`}>{words.repositoryNote(repository, typed)}</p>}
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
            {name && repository && <p class="small quiet">Its name: {name}. {words.privateNote}</p>}
          </div>
        )}
        {busy && <p class="quiet small">{words.starting(name)}</p>}
        {step.kind === "said" && <p class={`small${step.failed ? " failure" : ""}`}>{step.words}</p>}
        <div class="sheet-actions">
          {done ? <button type="button" class="prominent" onClick={close}>Done</button> : (
            <>
              <button type="button" onClick={close}>Cancel</button>
              <button type="submit" class="prominent" disabled={!ready || busy}>{words.start}</button>
            </>
          )}
        </div>
      </form>
    </Modal>
  );
}
