// The achievements (#984): the page's half of the window's and the Remote's AchievementsSection. Earned
// ones with their day, then the rest greyed with how, the newcomer's checklist. Worked out in
// model/achievements.ts; the one-time card is AchievementCard.tsx.
import type { Achievements } from "../protocol/generated";
import { isComplete, achievementDay, achievementList, orderedAchievements } from "../model/achievements";
import type { ComponentChildren } from "preact";

export function AchievementsSection({ achievements }: { achievements: Achievements }) {
  const rows = orderedAchievements(achievements);
  return (
    <section class="achievements" aria-label="Achievements">
      <p class="quiet small strong">
        Achievements <span class="achievements-count">{rows.filter((r) => r.at).length} of {achievementList.length}</span>
      </p>
      <ul>
        {rows.map((r) => (
          <li key={r.id} class={r.at ? "done" : ""} aria-label={r.title}>
            <span class="achievement-mark" aria-hidden="true">{r.at ? "✓" : "○"}</span>
            <span>
              <span class="achievement-title">{r.title}</span>
              <span class="quiet small">{r.at ? achievementDay(r.at) : r.how}</span>
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** The Time page with its achievements under the charts once all are earned; until then they are a
 * page of their own (#1067). */
export function TimeAchievementsUnder({ achievements, children }: { achievements: Achievements | undefined; children: ComponentChildren }) {
  return (
    <>
      {children}
      {achievements && isComplete(achievements) && <AchievementsSection achievements={achievements} />}
    </>
  );
}
