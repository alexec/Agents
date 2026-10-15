// The milestones (#984): the page's half of the window's and the Remote's MilestonesSection. Earned
// ones with their day, then the rest greyed with how, the newcomer's checklist. Worked out in
// model/milestones.ts; the one-time card is MilestoneCard.tsx.
import type { Milestones } from "../protocol/generated";
import { isComplete, milestoneDay, milestoneList, orderedMilestones } from "../model/milestones";
import type { ComponentChildren } from "preact";

export function MilestonesSection({ milestones }: { milestones: Milestones }) {
  const rows = orderedMilestones(milestones);
  return (
    <section class="milestones" aria-label="Milestones">
      <p class="quiet small strong">
        Milestones <span class="milestones-count">{rows.filter((r) => r.at).length} of {milestoneList.length}</span>
      </p>
      <ul>
        {rows.map((r) => (
          <li key={r.id} class={r.at ? "done" : ""} aria-label={r.title}>
            <span class="milestone-mark" aria-hidden="true">{r.at ? "✓" : "○"}</span>
            <span>
              <span class="milestone-title">{r.title}</span>
              <span class="quiet small">{r.at ? milestoneDay(r.at) : r.how}</span>
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** The Time page with its milestones under the charts once all are earned; until then they are a
 * page of their own (#1067). */
export function TimeMilestonesUnder({ milestones, children }: { milestones: Milestones | undefined; children: ComponentChildren }) {
  return (
    <>
      {children}
      {milestones && isComplete(milestones) && <MilestonesSection milestones={milestones} />}
    </>
  );
}
