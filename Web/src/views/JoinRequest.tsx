// A machine's ask to join the control plane (#994, Team T1), as the window's and the Remote's join
// card: its name, for which person, the code it shows, its platform, and Approve or Deny. Drawn
// with the approvals' shield (#773) at the top of the sidebar, so it is seen without opening
// Settings, and again in Settings ▸ People.
import type { Store } from "../model/store";
import type { JoinRequest } from "../protocol/generated";
import { codeLine, joinExplanation, joinWords, liveJoins } from "../model/people";
import { ApprovalMark } from "./Approval";

function JoinCard({ store, request, down }: { store: Store; request: JoinRequest; down: boolean }) {
  const words = joinWords(request, store.person.value?.id);
  return (
    <li class="join-request" aria-label={`${request.name} ${words}`}>
      <ApprovalMark />
      <div class="body">
        <span class="title"><strong>{request.name}</strong> {words}</span>
        <span class="subtitle">{codeLine(request.code)}</span>
        {request.platform && <span class="subtitle">{request.platform}</span>}
        <div class="join-actions">
          <button type="button" disabled={down} onClick={() => void store.decideJoin(request.request, false)}>Deny</button>
          <button type="button" class="prominent" disabled={down} onClick={() => void store.decideJoin(request.request, true)}>Approve</button>
        </div>
      </div>
    </li>
  );
}

/** Every machine waiting to join, or nothing. `explained` adds what Approve and Deny do. */
export function JoinRequests({ store, down, explained = false }: { store: Store; down: boolean; explained?: boolean }) {
  const waiting = liveJoins(store.joinRequests.value);
  if (waiting.length === 0) return null;
  return (
    <section class="join-requests" aria-label="Machines waiting to join">
      <ul>{waiting.map((request) => <JoinCard key={request.request} store={store} request={request} down={down} />)}</ul>
      {explained && <p class="hint">{joinExplanation}</p>}
    </section>
  );
}
