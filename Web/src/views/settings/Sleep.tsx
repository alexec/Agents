// Settings ▸ Machines ▸ Sleep (#4066): the Mac's two runtime pickers, as the window's Settings ▸ Machines ▸ This Mac ▸
// Sleep draws them, over `wake/settings` and `wake/set`. The Mac's own awake switch stays the window's. Listed in
// ./sections.ts.
import { useEffect } from "preact/hooks";
import type { Store } from "../../model/store";
import { backgroundHourChoices, defaultBackgroundHours, hoursLabel, sessionsLabel, sleepFooter, warmCounts } from "../../model/sleep";

export function SleepSection({ store, down }: { store: Store; down: boolean }) {
  useEffect(() => store.loadWakeSettings(), [store]);
  const settings = store.wakeSettings.value;
  if (!settings) return null;
  const background = settings.backgroundHours || defaultBackgroundHours;
  return (
    <section aria-labelledby="settings-sleep">
      <h3 class="section-head" id="settings-sleep">Sleep</h3>
      <label class="setting">
        <span>Keep ready for a reply</span>
        <select disabled={down} value={String(settings.warmRuntimes)}
          onChange={(e) => void store.setWakeSettings({ warmRuntimes: Number(e.currentTarget.value) })}>
          {warmCounts.map((n) => <option key={n} value={String(n)}>{sessionsLabel(n)}</option>)}
        </select>
      </label>
      <label class="setting">
        <span>Keep runtimes with background processes</span>
        <select disabled={down} value={String(background)}
          onChange={(e) => void store.setWakeSettings({ backgroundHours: Number(e.currentTarget.value) })}>
          {backgroundHourChoices.map((h) => <option key={h} value={String(h)}>{hoursLabel(h)}</option>)}
        </select>
      </label>
      <p class="hint">{sleepFooter(background)}</p>
    </section>
  );
}
