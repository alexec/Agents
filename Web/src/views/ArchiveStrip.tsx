// A session an agent asks to have archived (#584): under its head, the mark and the one click that
// agrees, as over the window's chat (ChatView) and the Remote's.
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { archiveHelp, archiveLabel, archiveLine } from "../model/archiveWords";

export function ArchiveStrip({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
  const line = agent && archiveLine(agent);
  if (!agent || !line) return null;
  const going = store.onItsWay.value[agent.id] !== undefined;
  return (
    <div class="archive-strip" role="status">
      <span class="quiet">{line}</span>
      <button disabled={disabled || going} title={archiveHelp}
        onClick={() => void store.perform(host, agent.id, "agents/archive")}>{archiveLabel}</button>
    </div>
  );
}
