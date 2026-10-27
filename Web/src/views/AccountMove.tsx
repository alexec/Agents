// A session whose account can no longer reach the model (#999): the organisation removed it, or its
// policy refuses it now. A strip across the top of its chat says why, with Continue in New, as the
// window's AccountMoveStrip.
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { go } from "../route";
import { folderIsMissing } from "../model/missingFolder";
import { accountChoices, continueInNew } from "../model/runtimes";

export function AccountMoveStrip({ store, host, agent }: { store: Store; host: string; agent: Agent | undefined }) {
  if (!agent || agent.state === "archived" || folderIsMissing(agent)) return null;
  const profiles = store.accountProfiles.value[host];
  const reason = accountChoices(agent.runtimeID, profiles ?? [], store.policyStates.value[host]?.policy)
    .moveReason(agent.accountID, profiles !== undefined);
  if (!reason) return null;
  const move = async () => {
    const id = await store.continueInNew(host, agent.id);
    if (id) go({ host, folder: agent.worktree?.folder || agent.cwd, session: id });
  };
  return (
    <div class="missing-folder-strip" role="status">
      <span class="what" title={reason}>{reason}</span>
      <span class="ways-on"><button onClick={() => void move()}>{continueInNew}</button></span>
    </div>
  );
}
