// Settings ▸ Control plane ▸ Version (#1748). Listed in ./sections.ts.
import type { Store } from "../../model/store";
import { appMissingWords } from "../../model/capabilities";

/** The control plane's own version, and what this page is too old for. The machines it lists were here
 * (#1759); the sidebar is the one place to manage machines now (#3975). */
export function VersionsSection({ store }: { store: Store }) {
  const plane = store.plane.value;
  if (!plane?.version) return null;
  const appMissing = appMissingWords(plane.required, plane.version);
  return (
    <section aria-labelledby="settings-version">
      <h3 class="section-head" id="settings-version">Version</h3>
      <p class="hint">{plane.name ?? "Control plane"}: agents-control {plane.version}</p>
      {appMissing && <p class="hint failure">{appMissing}</p>}
    </section>
  );
}
