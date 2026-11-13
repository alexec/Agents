// A session whose account can no longer reach the model (#999): the organisation removed it, or its
// policy refuses it now. A strip across the top of its chat says why, with Continue in New, as the
// window's AccountMoveStrip: a strip, in the warning's orange: something is wrong, not a request (#5016,
// #5029, #5034).
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { go } from "../route";
import { folderIsMissing } from "../model/missingFolder";
import { Strip } from "./Strip";
import { accountChoices, continueInNew } from "../model/runtimes";

/** Why the session's account can no longer reach the model, or null. */
export function accountMoveReason(store: Store, host: string, agent: Agent | undefined): string | null {
  if (!agent || agent.state === "archived" || folderIsMissing(agent)) return null;
  const profiles = store.accountProfiles.value[host];
  return accountChoices(agent.runtimeID, profiles ?? [], store.policyStates.value[host]?.policy)
    .moveReason(agent.accountID, profiles !== undefined) ?? null;
}

/** The account's strip (#5034, third of the session's strips). */
export function AccountMoveStrip({ store, host, agent }: { store: Store; host: string; agent: Agent | undefined }) {
  const reason = accountMoveReason(store, host, agent);
  if (!agent || !reason) return null;
  const move = async () => {
    const id = await store.continueInNew(host, agent.id);
    if (id) go({ host, folder: agent.worktree?.folder || agent.cwd, session: id });
  };
  return (
    <Strip tone="warning" name="account-move-strip" icon="user-x" line={reason}
      primary={{ label: continueInNew, run: () => void move() }} />
  );
}
