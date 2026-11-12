// Move to Machine… (#3790), from a session's menu, as the window's sheet: the machine, and the
// folder there. Its host stops the turn if one runs, sends the branch with its uncommitted changes,
// and the session goes on there with this conversation. The host answers once it has checked the
// move (#4641): the dialog closes, the session's row says how it goes, and the page opens it there
// once that machine has it, when it is still the open one.
import { signal, useSignal } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { folderHelp, moveTargets, noTargets, whatGoes } from "../model/moveToMachine";
import { canStop } from "../model/tree";
import { go, route } from "../route";
import { Modal } from "./Modal";

const moving = signal<{ host: string; agent: Agent } | null>(null);

export function moveToMachine(host: string, agent: Agent): void {
  moving.value = { host, agent };
}

/** Drawn once, by the columns. */
export function MoveToMachineDialog({ store }: { store: Store }) {
  const ask = moving.value;
  if (!ask) return null;
  return <MoveToMachine store={store} host={ask.host} agent={ask.agent} close={() => (moving.value = null)} />;
}

function MoveToMachine({ store, host, agent, close }: { store: Store; host: string; agent: Agent; close: () => void }) {
  const targets = moveTargets(store.hosts.value, host);
  const machine = useSignal(targets[0]?.id ?? "");
  const folder = useSignal("");
  const busy = useSignal(false);
  const failure = useSignal<string | null>(null);
  const title = agent.title?.trim() || "this session";
  const move = async () => {
    busy.value = true;
    failure.value = null;
    try {
      const there = machine.value;
      await store.moveToMachine(host, agent.id, there, folder.value, (answer) => {
        if (route.peek().session === agent.id) go({ host: there, folder: answer.folder, session: agent.id });
      });
      close();
    } catch (error) {
      failure.value = error instanceof Error ? error.message : String(error);
      busy.value = false;
    }
  };
  return (
    <Modal label="Move to Machine" close={close} keep={() => busy.value}>
      <form method="dialog" class="sheet-body move-to-machine" onSubmit={(e) => { e.preventDefault(); void move(); }}>
        <h2>Move “{title}” to Another Machine</h2>
        {targets.length === 0 ? <p class="sheet-note">{noTargets}</p> : (
          <>
            <label>Machine
              <select value={machine.value} disabled={busy.value}
                onChange={(e) => (machine.value = (e.currentTarget as HTMLSelectElement).value)}>
                {targets.map((h) => <option key={h.id} value={h.id}>{h.name}</option>)}
              </select>
            </label>
            <label>Folder there
              <input type="text" value={folder.value} placeholder="The project’s folder there" disabled={busy.value}
                onInput={(e) => (folder.value = (e.currentTarget as HTMLInputElement).value)} />
            </label>
            <p class="sheet-note">{folderHelp}</p>
            <p class="sheet-note">{whatGoes(canStop(agent))}</p>
          </>
        )}
        {failure.value ? <p class="failure small" role="alert">{failure.value}</p>
          : busy.value && <p class="sheet-note" role="status">Moving…</p>}
        <div class="sheet-actions">
          <button type="button" onClick={close} disabled={busy.value}>Cancel</button>
          <button type="submit" class="prominent" disabled={busy.value || machine.value === ""}>Move</button>
        </div>
      </form>
    </Modal>
  );
}
