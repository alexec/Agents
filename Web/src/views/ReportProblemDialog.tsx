// Report a Problem… (#3718), from the person menu: what happened and what the person expected,
// made into a GitHub issue they post from their own account, as the window's Help ▸ Report a
// Problem… does. The host adds the versions and, when asked, its recent log lines, and cuts out
// tokens and home folders; the dialog shows all of it before GitHub opens, and nothing is sent
// until the person posts it there.
import { signal, useSignal } from "@preact/signals";
import type { ProblemReport } from "../protocol/generated";
import type { Store } from "../model/store";
import { browserWords, webClient } from "../model/problemReport";
import { route } from "../route";
import { Modal } from "./Modal";

const reporting = signal(false);

export function reportProblem(): void {
  reporting.value = true;
}

/** Drawn once, by the columns. */
export function ReportProblemDialog({ store }: { store: Store }) {
  if (!reporting.value) return null;
  return <ReportProblem store={store} close={() => (reporting.value = false)} />;
}

function ReportProblem({ store, close }: { store: Store; close: () => void }) {
  const happened = useSignal("");
  const expected = useSignal("");
  const withLog = useSignal(true);
  const making = useSignal(false);
  const failure = useSignal<string | null>(null);
  const report = useSignal<ProblemReport | null>(null);
  const r = route.value;
  // The open session's host and runtime; else the person's Mac.
  const agent = r.host && r.session ? store.agent(r.host, r.session) : undefined;
  const host = agent ? r.host! : store.macHostID.value;
  const make = async () => {
    making.value = true;
    failure.value = null;
    try {
      report.value = await store.problemReport(host, {
        happened: happened.value, expected: expected.value,
        client: webClient(store.plane.value?.version), clientOS: browserWords(navigator.userAgent),
        ...(agent ? { runtime: agent.runtimeID } : {}), withLog: withLog.value,
      });
    } catch (error) {
      failure.value = `The host could not make the report: ${error instanceof Error ? error.message : String(error)}`;
    } finally {
      making.value = false;
    }
  };
  const shown = report.value;
  return (
    <Modal label="Report a Problem" close={close}>
      {shown ? (
        <div class="sheet-body report-problem">
          <h2>Report a Problem</h2>
          <p class="sheet-note">This is what GitHub gets. Change it there before you post it, if you like.</p>
          <p class="strong">{shown.title}</p>
          <pre class="report-body" tabIndex={0} aria-label="The issue's text">{shown.body}</pre>
          <div class="sheet-actions">
            <button type="button" onClick={() => (report.value = null)}>Back</button>
            <span class="spacer" />
            <button type="button" onClick={close}>Cancel</button>
            <button type="button" class="prominent" onClick={() => { open(shown.url, "_blank", "noopener"); close(); }}>
              Open on GitHub
            </button>
          </div>
        </div>
      ) : (
        <form method="dialog" class="sheet-body report-problem" onSubmit={(e) => { e.preventDefault(); void make(); }}>
          <h2>Report a Problem</h2>
          <p class="sheet-note">This makes a new issue on GitHub, posted from your own account. You see all of it first.</p>
          <label>What happened
            <textarea rows={3} value={happened.value}
              onInput={(e) => (happened.value = (e.currentTarget as HTMLTextAreaElement).value)} />
          </label>
          <label>What you expected
            <textarea rows={3} value={expected.value}
              onInput={(e) => (expected.value = (e.currentTarget as HTMLTextAreaElement).value)} />
          </label>
          <label class="check">
            <input type="checkbox" checked={withLog.value}
              onChange={(e) => (withLog.value = (e.currentTarget as HTMLInputElement).checked)} />
            Add the host’s recent log lines
          </label>
          <p class="sheet-note">Tokens and the paths in home folders are cut out.</p>
          {failure.value && <p class="failure small" role="alert">{failure.value}</p>}
          <div class="sheet-actions">
            <button type="button" onClick={close}>Cancel</button>
            <button type="submit" class="prominent" disabled={making.value || happened.value.trim() === ""}>
              {making.value ? "Making…" : "Review…"}
            </button>
          </div>
        </form>
      )}
    </Modal>
  );
}
