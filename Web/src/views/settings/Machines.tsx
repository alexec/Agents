// Settings ▸ You ▸ Machines (#1759). Listed in ./sections.ts.
import type { Store } from "../../model/store";
import { appMissingWords, missingWords, stateWords, versionWords } from "../../model/capabilities";

/** Machines (#1759): every machine, with its version (#1748) and what one too old for the control plane is
 * missing, as the window's Machines pane lists them. The control plane's own version is under the list. */
export function VersionsSection({ store }: { store: Store }) {
  const plane = store.plane.value;
  const hosts = store.hosts.value.filter((h) => h.relay == null);
  const appMissing = plane?.version ? appMissingWords(plane.required, plane.version) : null;
  return (
    <section aria-labelledby="settings-machines">
      <h3 class="section-head" id="settings-machines">Machines</h3>
      {hosts.length === 0 && <p class="hint">No machines yet. Add one on the Mac, in Settings ▸ Machines.</p>}
      {hosts.map((host) => {
        const missing = missingWords(host, plane?.version);
        return (
          <div class="setting" key={host.id}>
            <span>{host.name}{missing && <span class="small failure"> {missing}</span>}</span>
            <span class="faint">{host.state === "online" ? "" : `${stateWords(host)} · `}{versionWords(host)}</span>
          </div>
        );
      })}
      {plane?.version && <p class="hint">{plane.name ?? "Control plane"}: agents-control {plane.version}</p>}
      {appMissing && <p class="hint failure">{appMissing}</p>}
    </section>
  );
}
