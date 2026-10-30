// The one-time card for a milestone just earned (#984): the page's half of the window's and the
// iPad's MilestoneCard, at the bottom right until closed or opened; See Milestones opens their page
// (#1067). Apart from Milestones.tsx so the pages do not load the router.
import { type MilestoneID, milestoneList, milestonesSeen } from "../model/milestones";
import { go } from "../route";
import type { Store } from "../model/store";

/** The one-time card for a milestone just earned on this Mac's host. No notification is sent. */
export function MilestoneCard({ store }: { store: Store }) {
  const macID = store.macHostID.value;
  const host = store.hosts.value.some((h) => h.id === macID) ? macID : store.hosts.value[0]?.id;
  const id = milestonesSeen.card(host ? store.milestones.value[host] : undefined);
  if (!id) return null;
  const milestone = milestoneList.find((m) => m.id === id)!;
  const dismiss = (which: MilestoneID) => milestonesSeen.dismiss(which);
  return (
    <aside class="card milestone-card" aria-label={`Milestone earned: ${milestone.title}`}>
      <div class="milestone-card-head">
        <span class="milestone-mark" aria-hidden="true">✓</span>
        <span>
          <span class="quiet small">Milestone</span>
          <span class="milestone-title">{milestone.title}</span>
        </span>
        <button class="link close" aria-label="Dismiss milestone" title="Dismiss" onClick={() => dismiss(id)}>✕</button>
      </div>
      <button class="link small" onClick={() => { dismiss(id); go({ nav: "reports", section: "milestones" }); }}>
        See Milestones
      </button>
    </aside>
  );
}
