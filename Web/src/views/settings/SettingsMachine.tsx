// The machine Settings' per-machine panes speak to (#3368): the Mac when there is one, with nothing
// drawn; with no Mac, a Machine menu of the machines there are (one choice for every pane), or why
// there is none yet.
import { signal } from "@preact/signals";
import type { Store } from "../../model/store";
import { machineLabel, noMachineYet, settingsMachine, settingsMachines } from "../../model/settingsMachine";

const chosen = signal<string | null>(null);

/** Settings' per-machine panes speak to this machine, as a machine's page's Settings… asks (#3626). */
export function chooseSettingsMachine(id: string) {
  chosen.value = id;
}

export function useSettingsMachine(store: Store) {
  const macID = store.macHostID.value;
  const machines = settingsMachines(store.hosts.value, macID);
  const machine = settingsMachine(machines, chosen.value, store.plane.value?.homeHost);
  const isMac = machine?.id === macID;
  // Before the first hosts/list and control/status there is nothing to say yet.
  const loading = !machine && store.hosts.value.length === 0 && !store.plane.value;
  const picker = isMac ? null : loading ? <p class="hint">Loading…</p> : !machine ? <p class="hint">{noMachineYet}</p> : (
    <label class="setting">{machineLabel}{" "}
      <select value={machine.id} disabled={machines.length < 2}
        onChange={(event) => { chosen.value = event.currentTarget.value; }}>
        {machines.map((h) => <option key={h.id} value={h.id}>{h.name}</option>)}
      </select>
    </label>
  );
  return { host: machine?.id, name: machine?.name, isMac, picker };
}
