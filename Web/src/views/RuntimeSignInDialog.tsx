// Sign In… on a server's Claude or Codex (#3349): the machine has no browser, so the runtime's
// own sign-in runs there and gives a link to open here. Claude's page then gives a code to paste
// back; Codex gives a code to type on its page. An API key is the other way in.
import { useEffect, useState } from "preact/hooks";
import type { RuntimeSignInStep } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { machineSignInWords as words } from "../model/runtimes";
import { Modal } from "./Modal";

export function RuntimeSignInDialog({ store, host, runtimeID, runtimeName, machine, close }: {
  store: Store; host: string; runtimeID: string; runtimeName: string; machine: string; close: () => void;
}) {
  const [step, setStep] = useState<RuntimeSignInStep>();
  const [byKey, setByKey] = useState(false);
  const [code, setCode] = useState("");
  const [key, setKey] = useState("");
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string>();
  const [copied, setCopied] = useState<"link" | "code">();

  const start = () => {
    setStep(undefined);
    setCode("");
    setProblem(undefined);
    store.signInStart(host, runtimeID).then(setStep, (e: unknown) => setProblem(describe(e)));
  };
  useEffect(() => { if (!byKey) start(); }, [byKey]);

  // A sign-in left waiting is stopped on the machine.
  const leave = () => {
    if (step) void store.signInFinish(host, step.signInID, { cancel: true }).catch(() => {});
    close();
  };
  const run = (work: Promise<void>, again = false) => {
    setBusy(true);
    setProblem(undefined);
    work.then(close, (e: unknown) => {
      setProblem(describe(e));
      // Claude starts again after a code it did not take.
      if (again) setStep(undefined);
    }).finally(() => setBusy(false));
  };
  const finish = () => {
    if (!step) return;
    run(store.signInFinish(host, step.signInID, step.wantsCode ? { code } : {}), step.wantsCode);
  };
  const useKey = () => run(store.signInKey(host, runtimeID, key));
  const switchWay = () => {
    if (step) void store.signInFinish(host, step.signInID, { cancel: true }).catch(() => {});
    setStep(undefined);
    setProblem(undefined);
    setByKey(!byKey);
  };
  const copy = (text: string, what: "link" | "code") => {
    void navigator.clipboard?.writeText(text).then(() => setCopied(what)).catch(() => {});
  };
  const title = words.title(runtimeName, machine);
  const ready = byKey ? key.trim() !== "" : !!step && (!step.wantsCode || code.trim() !== "");

  return (
    <Modal label={title} close={leave}>
      <form class="sheet-body connect-sheet runtime-sign-in" onSubmit={(e) => { e.preventDefault(); if (ready && !busy) (byKey ? useKey : finish)(); }}>
        <h2>{title}</h2>
        {byKey ? (
          <div class="token-form">
            <label>{words.keyLabel}
              <input type="password" autocomplete="off" spellcheck={false} value={key}
                onInput={(e) => setKey((e.target as HTMLInputElement).value)} />
            </label>
            <p class="sheet-note">{words.keyNote(runtimeID)}</p>
          </div>
        ) : step ? (
          <>
            <p>{words.openLink}</p>
            <p class="sign-in-link">
              <a href={step.url} target="_blank" rel="noopener noreferrer" class="button">{words.open}</a>{" "}
              <button type="button" onClick={() => copy(step.url, "link")}>{copied === "link" ? "Copied" : words.copyLink}</button>
            </p>
            {step.userCode !== undefined ? (
              <>
                <p>{words.typeCode}</p>
                <p class="sign-in-code">
                  <code class="code-text" aria-label={words.codeLabel}>{step.userCode}</code>{" "}
                  <button type="button" onClick={() => copy(step.userCode!, "code")}>{copied === "code" ? "Copied" : "Copy"}</button>
                </p>
                <p class="sheet-note">{words.codexNote}</p>
              </>
            ) : step.wantsCode && (
              <div class="token-form">
                <label>{words.pasteCode}
                  <input aria-label={words.codeLabel} autocomplete="off" spellcheck={false} value={code}
                    onInput={(e) => setCode((e.target as HTMLInputElement).value)} />
                </label>
              </div>
            )}
          </>
        ) : !problem && <p class="sheet-note" role="status">{words.asking(runtimeName)}</p>}
        {problem && <p class="sheet-note failure" role="alert">{problem}</p>}
        <div class="sheet-actions">
          <button type="button" class="link" onClick={switchWay} disabled={busy}>{byKey ? words.useAccount : words.useKey}</button>
          <button type="button" onClick={leave}>Cancel</button>
          {!byKey && !step && problem
            ? <button type="button" class="prominent" onClick={start}>Try Again</button>
            : <button type="submit" class="prominent" disabled={!ready || busy}>
              {busy ? words.signingIn : byKey || step?.wantsCode ? words.signIn : words.done}
            </button>}
        </div>
      </form>
    </Modal>
  );
}
