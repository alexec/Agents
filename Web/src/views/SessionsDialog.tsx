// What the runtime is holding that the app did not start (#3716), as the window's Sessions list
// (SessionListView): a conversation started in a terminal, or in another tool's worktree of
// this folder (Conductor's workspaces), picked up as a session here. Its replay is its
// transcript, and it goes on with the runtime's own resume, so the agent keeps what it knew.
import { useEffect, useState } from "preact/hooks";
import type { RuntimeSession } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { fromWireDate } from "../protocol/dates";
import { ago } from "../model/connectorSetup";
import { sessionPlace } from "../model/runtimeSessions";
import { go } from "../route";
import { Modal } from "./Modal";

export function SessionsDialog({ store, host, folder, folderName, runtimeID, runtimeName, close }: {
  store: Store; host: string; folder: string; folderName: string; runtimeID: string; runtimeName: string; close: () => void;
}) {
  const [sessions, setSessions] = useState<RuntimeSession[]>();
  const [problem, setProblem] = useState<string>();
  const [busy, setBusy] = useState<string>();

  useEffect(() => {
    store.runtimeSessions(host, runtimeID, folder).then(setSessions, (e: unknown) => {
      setSessions([]);
      setProblem(describe(e));
    });
  }, [host, runtimeID, folder]);

  const pickUp = (session: RuntimeSession) => {
    setBusy(session.sessionID);
    setProblem(undefined);
    store.adoptSession(host, runtimeID, session).then((id) => {
      close();
      go({ host, folder, session: id });
    }, (e: unknown) => setProblem(describe(e))).finally(() => setBusy(undefined));
  };
  const remove = (session: RuntimeSession) => {
    if (!confirm(`Delete this conversation? This removes it from ${runtimeName} as well as from here. It cannot be undone.`)) return;
    setBusy(session.sessionID);
    store.deleteRuntimeSession(host, runtimeID, session.sessionID).then(() => {
      setSessions((all) => all?.filter((s) => s.sessionID !== session.sessionID));
    }, (e: unknown) => setProblem(describe(e))).finally(() => setBusy(undefined));
  };

  const title = `Conversations in ${folderName}`;
  return (
    <Modal label={title} close={close}>
      <div class="sheet-body runtime-sessions">
        <h2>{title}</h2>
        {!sessions ? <p class="sheet-note" role="status">Asking {runtimeName}…</p>
          : !sessions.length && !problem ? <p class="sheet-note">{runtimeName} is holding nothing here.</p>
          : (
            <ul class="runtime-session-list">
              {sessions.map((s) => {
                const place = sessionPlace(s, folder);
                return (
                  <li key={s.sessionID}>
                    <div class="runtime-session-words">
                      <span class="runtime-session-title">{s.title ?? s.sessionID}</span>
                      <span class="quiet small">
                        {[s.updatedAt && ago(fromWireDate(s.updatedAt)), place && `in ${place}`, s.isHeld && "already here"]
                          .filter(Boolean).join(" · ")}
                      </span>
                    </div>
                    {!s.isHeld && (
                      <button type="button" disabled={!!busy} onClick={() => pickUp(s)}>
                        {busy === s.sessionID ? "Picking up…" : "Pick up"}</button>
                    )}
                    <button type="button" class="link" disabled={!!busy} title={`Delete this conversation from ${runtimeName}`}
                      aria-label={`Delete ${s.title ?? s.sessionID}`} onClick={() => remove(s)}>Delete</button>
                  </li>
                );
              })}
            </ul>
          )}
        {problem && <p class="sheet-note failure" role="alert">{problem}</p>}
        <div class="sheet-actions">
          <button type="button" class="prominent" onClick={close}>Done</button>
        </div>
      </div>
    </Modal>
  );
}
