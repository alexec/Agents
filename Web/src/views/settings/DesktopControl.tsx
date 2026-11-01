// Settings ▸ Machines ▸ Desktop control (#3004, US2): the off-by-default switch for drive_screen,
// an agent driving another app's own screen, mouse and keyboard. Listed in ./sections.ts.
import { useEffect } from "preact/hooks";
import type { Store } from "../../model/store";

export function DesktopControlSection({ store }: { store: Store }) {
  useEffect(() => store.loadDesktopControl(), [store]);
  const settings = store.desktopControl.value;
  if (!settings) return null;
  return (
    <section aria-labelledby="settings-desktop-control">
      <h3 class="section-head" id="settings-desktop-control">Desktop control</h3>
      <label class="setting">
        <span>Let an agent drive apps on this Mac</span>
        <input type="checkbox" role="switch" checked={settings.enabled}
          onChange={(e) => void store.setDesktopControlEnabled(e.currentTarget.checked)} />
      </label>
      <p class="hint">
        {settings.enabled
          ? "An agent can click, type and read the screen of any app on this Mac, not only the sandboxed browser. macOS will ask you to grant Agents Host the Accessibility permission the first time an agent tries."
          : "Off by default. An agent cannot click, type or read the screen of any other app until you turn this on."}
      </p>
    </section>
  );
}
