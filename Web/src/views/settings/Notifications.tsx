// Settings ▸ This browser ▸ What agents tell you (#2805): how many notices agents may send, kept on the Mac's host,
// so the same on every client. Its heading is the window's and the Remote's, and its hint says the limits are not
// this browser's, which gets no notices (#2895, #1486). Listed in ./sections.ts.
import {
  noticeBurst, noticeBurstMost, noticeCooldown, noticeCooldownMost, noticeLimitsFooter, noticeLimitsWhere, setNoticeBurst,
  setNoticeCooldown,
} from "../../model/notified";

export function NotificationsSection() {
  return (
    <section aria-labelledby="settings-notifications">
      <h3 class="section-head" id="settings-notifications">What agents tell you</h3>
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
      <p class="hint">{noticeLimitsFooter} {noticeLimitsWhere}</p>
    </section>
  );
}
