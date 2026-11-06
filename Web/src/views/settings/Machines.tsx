// Settings ▸ You ▸ Machines (#1759). Listed in ./sections.ts.
import { useState } from "preact/hooks";
import type { Store } from "../../model/store";
import { addMachineWords } from "../../model/addMachine";
import { AddMachineDialog } from "../AddMachineDialog";
import { appMissingWords, missingWords, stateWords, versionWords } from "../../model/capabilities";

/** Machines (#1759): every machine, with its version (#1748), what one too old for the control plane is
 * missing and Remove… (#3381), as the window's Machines pane lists them. The control plane's own version is under the list. */
export function VersionsSection({ store }: { store: Store }) {
  const plane = store.plane.value;
  const hosts = store.hosts.value;
  const appMissing = plane?.version ? appMissingWords(plane.required, plane.version) : null;
  const [adding, setAdding] = useState(false);
  const remove = (host: { id: string; name: string }) => {
    if (window.confirm(`${addMachineWords.removeTitle(host.name)} ${addMachineWords.removeNote}`)) void store.removeHost(host.id);
  };
  return (
    <section aria-labelledby="settings-machines">
      <h3 class="section-head" id="settings-machines">Machines</h3>
      {hosts.length === 0 && <p class="hint">No machines yet.</p>}
      {hosts.map((host) => {
        const missing = missingWords(host, plane?.version);
        return (
          <div class="setting" key={host.id}>
            <span>{host.name}{missing && <span class="small failure"> {missing}</span>}</span>
            <span class="faint">{host.state === "online" ? "" : `${stateWords(host)} · `}{versionWords(host)}</span>
            {/* The window's Remove… (#3381): the control plane says no to one who may not. */}
            <button type="button" class="destructive" onClick={() => remove(host)}>Remove…</button>
          </div>
        );
      })}
      {/* One sheet, a provider first (#2131): a server and a code are its other two ways. */}
      <div class="provider-add"><button type="button" onClick={() => setAdding(true)}>{addMachineWords.menuItem}</button></div>
      <p class="hint">{addMachineWords.machinesFoot}</p>
      {plane?.version && <p class="hint">{plane.name ?? "Control plane"}: agents-control {plane.version}</p>}
      {appMissing && <p class="hint failure">{appMissing}</p>}
      {adding && <AddMachineDialog store={store} close={() => setAdding(false)} />}
    </section>
  );
}
