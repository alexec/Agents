// Settings ▸ Agent Configuration ▸ Workflows' daily summary (#3351): Off or Summary only, and the
// time, for all folders, as the Mac's and the Remote's. The home folder's Daily summary workflow
// keeps it on the Mac's host.
import { useEffect } from "preact/hooks";
import type { Store } from "../../model/store";
import type { DailySummaryMode } from "../../protocol/generated";
import {
  dailySummaryChoices, dailySummaryHint, dailySummaryModes, dailySummaryTimeLabel,
} from "../../model/dailySummaryWords";

export function DailySummaryControl({ store }: { store: Store }) {
  useEffect(() => store.loadDailySummary(), [store]);
  const settings = store.dailySummary.value;
  if (!settings) return null;
  return (
    <div class="daily-summary" role="group" aria-label="Daily summary">
      <label class="setting">
        <span>Daily summary</span>
        <select value={settings.mode}
          onChange={(e) => void store.setDailySummary({ ...settings, mode: e.currentTarget.value as DailySummaryMode })}>
          {dailySummaryModes.map((m) => <option key={m.mode} value={m.mode}>{m.label}</option>)}
        </select>
      </label>
      {settings.mode !== "off" && (
        <label class="setting">
          <span>Time</span>
          <select value={settings.at}
            onChange={(e) => void store.setDailySummary({ ...settings, at: e.currentTarget.value })}>
            {dailySummaryChoices(settings.at).map((at) => <option key={at} value={at}>{dailySummaryTimeLabel(at)}</option>)}
          </select>
        </label>
      )}
      <p class="hint">{dailySummaryHint}</p>
    </div>
  );
}
