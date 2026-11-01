// Add a Machine… (#2131), the window's and the Remote's: a provider first, then a server by one
// command, then another Mac by a code. A browser has no ssh, so a server is added by its command.
// Reached from Settings ▸ Machines and Connectors set-up ▸ Where agents run.
import { useEffect, useState } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { ControlCodeShown } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { makers } from "../model/machineFromRepository";
import { addMachineWays, addMachineWords as words, type AddMachineWay } from "../model/addMachine";
import { AddProviderDialog } from "./Providers";
import { MachineDialog } from "./MachineDialog";
import { Modal } from "./Modal";

type Step = { kind: "choose" } | { kind: "provider"; picked?: string | undefined } | { kind: "addProvider" } | { kind: "code"; command: boolean };

export function AddMachineDialog({ store, close, start = { kind: "choose" } }: { store: Store; close: () => void; start?: Step }) {
  const [step, setStep] = useState<Step>(start);
  const [way, setWay] = useState<AddMachineWay>("provider");
  const [picked, setPicked] = useState<string>();
  const providers = store.providers.list.value;
  useEffect(() => { if (providers === null) void store.providers.load(); }, []);
  const off = store.providers.off.value;
  const admin = store.person.value?.role !== "member";
  const choices = makers(providers ?? []);

  if (step.kind === "provider") return <MachineDialog store={store} close={close} machine picked={step.picked} />;
  if (step.kind === "addProvider") {
    return <AddProviderDialog store={store} close={close} added={(id) => { setPicked(id); setStep({ kind: "choose" }); }} />;
  }
  if (step.kind === "code") return <EnrollCode store={store} command={step.command} close={close} />;

  const next = () => {
    if (way === "provider") setStep({ kind: "provider", picked: picked ?? choices[0]?.id });
    else setStep({ kind: "code", command: way === "server" });
  };
  const ready = way !== "provider" || (!off && choices.length > 0);
  return (
    <Modal label={words.title} close={close}>
      <form class="sheet-body connect-sheet provider-sheet" onSubmit={(e) => { e.preventDefault(); if (ready) next(); }}>
        <h2>{words.title}</h2>
        <div class="add-machine-ways" role="radiogroup" aria-label={words.title}>
          {addMachineWays.map((w) => (
            <button key={w} type="button" role="radio" aria-checked={way === w} class={`add-machine-way${way === w ? " on" : ""}`}
              onClick={() => setWay(w)}>
              <span class="strong">{words.choice(w)}</span>
              <span class="small quiet">{w === "provider" && off ? off : words.note(w)}</span>
            </button>
          ))}
        </div>
        {way === "provider" && !off && providers !== null && (choices.length === 0 ? (
          <p class="sheet-note">
            {admin ? words.noProviders : words.noProvidersAskAdmin}{" "}
            {admin && <button type="button" onClick={() => setStep({ kind: "addProvider" })}>{words.addProvider}</button>}
          </p>
        ) : (
          <div class="token-form">
            <label>Provider
              <select value={picked ?? choices[0]?.id} onChange={(e) => setPicked((e.target as HTMLSelectElement).value)}>
                {choices.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
              </select>
            </label>
            {admin && <button type="button" class="link small" onClick={() => setStep({ kind: "addProvider" })}>{words.addProvider}</button>}
          </div>
        ))}
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={!ready}>{words.next}</button>
        </div>
      </form>
    </Modal>
  );
}

/** A server's one command, or another Mac's code: `hosts/startEnroll`, with Copy, and who joined with it. */
function EnrollCode({ store, command, close }: { store: Store; command: boolean; close: () => void }) {
  const shown = useSignal<ControlCodeShown | null>(null);
  const problem = useSignal<string | null>(null);
  const copied = useSignal(false);
  const [before] = useState(() => new Set(store.hosts.peek().map((h) => h.id)));
  useEffect(() => {
    store.link.call("hosts/startEnroll", {})
      .then((code) => { shown.value = code; })
      .catch((error) => { problem.value = describe(error); });
  }, []);
  const line = shown.value ? (command ? shown.value.command ?? shown.value.text : shown.value.text) : null;
  const joined = shown.value ? store.hosts.value.find((h) => !before.has(h.id))?.name : undefined;
  const copy = () => { if (line) void navigator.clipboard?.writeText(line).then(() => { copied.value = true; }).catch(() => {}); };
  const title = command ? words.serverTitle : words.codeTitle;
  return (
    <Modal label={title} close={close}>
      <div class="sheet-body invite-code">
        <h2>{title}</h2>
        {joined ? <p class="sheet-note" role="status">{words.joined(joined)}</p>
          : line ? <code class="code-text" aria-label={command ? "Command" : "Code"}>{line}</code>
          : !problem.value && <p class="sheet-note" role="status">{words.makingCode}</p>}
        {!joined && <p class="sheet-note">{command ? words.serverNote : words.codeNote}</p>}
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          {line && !joined && <button type="button" onClick={copy}>{copied.value ? "Copied" : "Copy"}</button>}
          <button type="button" class="prominent" onClick={close}>Done</button>
        </div>
      </div>
    </Modal>
  );
}
