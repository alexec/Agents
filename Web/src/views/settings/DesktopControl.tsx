// Settings ▸ Machines ▸ Desktop control (#3004, US2, #4264): Ask, Always Approve or Off for drive_screen, an
// agent driving another app's own screen, mouse and keyboard. Listed in ./sections.ts.
import { useEffect } from "preact/hooks";
import type { DriveApproval } from "../../protocol/generated";
import type { Store } from "../../model/store";
import { driveApprovals, screenFooter, screenLabel, shownMode } from "../../model/driveApproval";

export function DesktopControlSection({ store }: { store: Store }) {
  useEffect(() => store.loadDesktopControl(), [store]);
  const settings = store.desktopControl.value;
  if (!settings) return null;
  const mode = shownMode(settings);
  return (
    <section aria-labelledby="settings-desktop-control">
      <h3 class="section-head" id="settings-desktop-control">Desktop control</h3>
      <label class="setting">
        <span>{screenLabel}</span>
        <select value={mode} onChange={(e) => void store.setDesktopControl(e.currentTarget.value as DriveApproval)}>
          {driveApprovals.map((m) => <option key={m.mode} value={m.mode}>{m.label}</option>)}
        </select>
      </label>
      <p class="hint">{screenFooter(mode)}</p>
    </section>
  );
}
