// The one-time card for a milestone just earned (#984): the page's half of the window's and the
// iPad's MilestoneCard, at the bottom right until closed or opened. Apart from Milestones.tsx so
// the Time page does not load the router.
import { type MilestoneID, milestoneList, milestonesSeen } from "../model/milestones";
import { go, route } from "../route";
import type { Store } from "../model/store";

/** The one-time card for a milestone just earned on this Mac's host. No notification is sent. */
export function MilestoneCard({ store }: { store: Store }) {
  const host = store.hosts.value.some((h) => h.id === "mac") ? "mac" : store.hosts.value[0]?.id;
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
      <button class="link small" onClick={() => { dismiss(id); go({ ...route.peek(), activity: "time", settings: undefined }); }}>
        See Milestones
      </button>
    </aside>
  );
}
