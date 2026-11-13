// An agent's ask to be archived (#584, #649), as an Ask at the end of the transcript, the way a
// tool's permission question is asked (#827, #5031): what the agent last said, and Archive or Keep
// Session. The window and the Remote draw ArchiveRequestCard.swift.
import { useSignal } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { asksToArchive } from "../model/groups";
import { archiveHelp, archiveLabel, archiveQuestion, keepLabel, noReport } from "../model/archiveWords";
import { archiveWithChildren } from "./SessionMenu";
import { Ask } from "./Ask";

export function ArchiveCard({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
  const busy = useSignal(false);
  if (!agent || !asksToArchive(agent)) return null;
  const held = disabled || busy.value || store.onItsWay.value[agent.id] !== undefined;
  const answer = (act: () => Promise<unknown>) => {
    busy.value = true;
    void act().finally(() => (busy.value = false));
  };
  return (
    <Ask glyph="archive" title={archiveQuestion} label={archiveQuestion} alert extra="archive-card"
      buttons={<>
        <button disabled={held} onClick={() => answer(() => store.keepSession(host, agent))}>{keepLabel}</button>
        <button class="prominent" disabled={held} title={archiveHelp} data-default=""
          onClick={() => answer(() => archiveWithChildren(store, host, agent))}>{archiveLabel}</button>
      </>}>
      <p class="quiet">{agent.report?.message ?? noReport}</p>
    </Ask>
  );
}
