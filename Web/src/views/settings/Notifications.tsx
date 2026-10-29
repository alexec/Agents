// Settings ▸ This app ▸ Notifications (#2805): how many notices agents may send, kept on the Mac's host, so the
// same on every client. Listed in ./sections.ts.
import {
  noticeBurst, noticeBurstMost, noticeCooldown, noticeCooldownMost, noticeLimitsFooter, setNoticeBurst, setNoticeCooldown,
} from "../../model/notified";

export function NotificationsSection() {
  return (
    <section aria-labelledby="settings-notifications">
      <h3 class="section-head" id="settings-notifications">Notifications</h3>
      <label class="setting">
        <span>Burst</span>
        <input type="number" min={1} max={noticeBurstMost} step={1} value={noticeBurst.value}
          onChange={(e) => setNoticeBurst(e.currentTarget.valueAsNumber)} />
      </label>
      <label class="setting">
        <span>Cool-down (minutes)</span>
        <input type="number" min={1} max={noticeCooldownMost} step={1} value={noticeCooldown.value}
          onChange={(e) => setNoticeCooldown(e.currentTarget.valueAsNumber)} />
      </label>
      <p class="hint">{noticeLimitsFooter}</p>
    </section>
  );
}
