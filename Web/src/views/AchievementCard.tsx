// The one-time card for an achievement just earned (#984): the page's half of the window's and the
// iPad's AchievementCard, at the bottom right until closed or opened; See Achievements opens the Multiplier
// page, where the badges are (#3990). Apart from Achievements.tsx so the pages do not load the router.
import { type AchievementID, achievementList, achievementsSeen } from "../model/achievements";
import { go } from "../route";
import type { Store } from "../model/store";
import { Icon } from "./Icon";

/** The one-time card for an achievement just earned on this Mac's host. No notification is sent. */
export function AchievementCard({ store }: { store: Store }) {
  const macID = store.macHostID.value;
  const host = store.hosts.value.some((h) => h.id === macID) ? macID : store.hosts.value[0]?.id;
  const id = achievementsSeen.card(host ? store.achievements.value[host] : undefined);
  if (!id) return null;
  const achievement = achievementList.find((m) => m.id === id)!;
  const dismiss = (which: AchievementID) => achievementsSeen.dismiss(which);
  return (
    <aside class="card achievement-card" aria-label={`Achievement earned: ${achievement.title}`}>
      <div class="achievement-card-head">
        <Icon name="check" class="achievement-mark" />
        <span>
          <span class="quiet small">Achievement</span>
          <span class="achievement-title">{achievement.title}</span>
        </span>
        <button class="link close" aria-label="Dismiss achievement" title="Dismiss" onClick={() => dismiss(id)}>✕</button>
      </div>
      <button class="link small" onClick={() => { dismiss(id); go({ nav: "reports", section: "multiplier" }); }}>
        See Achievements
      </button>
    </aside>
  );
}
