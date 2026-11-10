// Settings ▸ Control plane ▸ Connect to Another… (#4257) on the page this Mac serves, as the window's
// (#4228): sign in to agentloops.dev, or use a code from a control plane the person runs, said before
// it is done. The window on this Mac does it (control/connectAnother) and says each step; at the end
// this control plane stops, and with it this page. Listed in ./sections.ts.
import { useState } from "preact/hooks";
import { checkConnectCode, connectAnotherWords as words, connectBefore, connectDone } from "../../model/connectAnother";
import { describe } from "../../model/errors";
import type { Store } from "../../model/store";
import { Modal } from "../Modal";

export function ConnectAnotherSection({ store, down }: { store: Store; down: boolean }) {
  const [open, setOpen] = useState(false);
  return (
    <section aria-labelledby="settings-connect-another">
      <h3 class="section-head" id="settings-connect-another">Where it runs</h3>
      <p class="hint">{words.lead}</p>
      <button type="button" onClick={() => setOpen(true)} disabled={down}>{words.connect}</button>
      {open && <ConnectAnotherDialog store={store} down={down} close={() => setOpen(false)} />}
    </section>
  );
}

type Step =
  | { kind: "choose" }
  | { kind: "code" }
  | { kind: "confirm"; place: string; url?: string | undefined; code?: string | undefined }
  | { kind: "asked"; place: string; url?: string | undefined };

function ConnectAnotherDialog({ store, down, close }: { store: Store; down: boolean; close: () => void }) {
  const [step, setStep] = useState<Step>({ kind: "choose" });
  const [typed, setTyped] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  const report = store.connectReport.value;
  const asked = step.kind === "asked";
  // The window stopped and this Mac is as it was: back to the choice, with why.
  const stopped = asked ? report?.problem ?? problem : problem;
  const done = asked && down && !report?.problem;

  const next = () => {
    const checked = checkConnectCode(typed);
    if ("problem" in checked) { setProblem(checked.problem); return; }
    setProblem(null);
    setStep({ kind: "confirm", place: checked.place, url: checked.url, code: checked.code });
  };
  const connect = (confirmed: Extract<Step, { kind: "confirm" }>) => {
    setProblem(null);
    setStep({ kind: "asked", place: confirmed.place, url: confirmed.url });
    store.connectAnother(confirmed.code ? { code: confirmed.code } : { hosted: true })
      .catch((error) => { setProblem(describe(error)); setStep({ kind: "choose" }); });
  };
  const again = () => { setProblem(null); store.connectReport.value = null; setStep({ kind: "choose" }); };

  return (
    <Modal label={words.title} close={close} keep={() => asked && !done && !stopped}>
      <form class="sheet-body connect-sheet" onSubmit={(e) => {
        e.preventDefault();
        if (step.kind === "code") next();
        else if (step.kind === "confirm") connect(step);
      }}>
        <h2>{words.title}</h2>
        {step.kind === "choose" && (
          <>
            <p class="sheet-note">{words.lead}</p>
            <div class="add-machine-ways">
              <button type="button" class="add-machine-way"
                onClick={() => { setProblem(null); setStep({ kind: "confirm", place: words.hosted }); }}>
                <span class="strong">{words.signIn}</span>
                <span class="small quiet">{words.signInNote}</span>
              </button>
              <button type="button" class="add-machine-way" onClick={() => { setProblem(null); setStep({ kind: "code" }); }}>
                <span class="strong">{words.useCode}</span>
                <span class="small quiet">{words.useCodeNote}</span>
              </button>
            </div>
          </>
        )}
        {step.kind === "code" && (
          <>
            <textarea aria-label="Code" placeholder="agents-control:2:c:…" spellcheck={false} autocomplete="off" autoFocus
              value={typed} onInput={(e) => setTyped((e.currentTarget as HTMLTextAreaElement).value)} />
            <p class="sheet-note">{words.codeNote}</p>
          </>
        )}
        {step.kind === "confirm" && <p>{connectBefore(step.place)}</p>}
        {asked && (done ? (
          <p role="status">
            {connectDone(step.place)}{" "}
            {step.url && <a href={step.url} target="_blank" rel="noopener">{step.url.replace(/^https:\/\//, "")}</a>}
          </p>
        ) : !stopped && <p class="sheet-note" role="status">{report?.step ?? words.asking}</p>)}
        {stopped && <p class="sheet-note failure" role="alert">{stopped}</p>}
        <div class="sheet-actions">
          {asked && stopped && <button type="button" onClick={again}>Back</button>}
          <button type="button" onClick={close} disabled={asked && !done && !stopped}>{done ? "Done" : "Cancel"}</button>
          {step.kind === "code" && <button type="submit" class="prominent" disabled={!typed.trim()}>Next</button>}
          {step.kind === "confirm" && <button type="submit" class="prominent">Connect</button>}
        </div>
      </form>
    </Modal>
  );
}
