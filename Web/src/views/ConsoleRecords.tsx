// The Console's records (#1804): Audit (M8), who did what, for one person or everyone, with CSV;
// and Requests (M7), what waits for an admin: machines asking to join, channel identities asking
// to be linked, and bots stopped at a cap.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { ChannelLinkRequest, PersonRow } from "../protocol/generated";
import { go } from "../route";
import { failedWords, linkWords, noRequests, requestsFoot } from "../model/console";
import { capReachedWords } from "../model/teamGroups";
import { liveJoins } from "../model/people";
import { AuditPane } from "./Audit";
import { JoinRequests } from "./JoinRequest";

/** M8: the audit, every machine's names from the fleet, and a person to narrow it to. */
export function AuditPage({ store, down }: { store: Store; down: boolean }) {
  const people = useSignal<PersonRow[] | null>(null);
  const names = useSignal<Record<string, string>>({});
  useEffect(() => {
    if (down) return;
    void store.link.call("people/list", {}).then((l) => { people.value = l.people; }, () => { people.value = []; });
    void store.link.call("console/fleet", {}).then((b) => {
      names.value = Object.fromEntries(b.machines.map((m) => [m.host.id, m.host.name]));
    }, () => {});
  }, [down]);
  if (people.value === null) return <p class="hint">Loading…</p>;
  return <AuditPane store={store} people={people.value} hostName={(host) => names.value[host] ?? host} />;
}

/** M7: each request with its answer. Join requests and a bot at its cap come as notifications too. */
export function RequestsPage({ store, down }: { store: Store; down: boolean }) {
  const links = useSignal<ChannelLinkRequest[]>([]);
  const problem = useSignal<string | null>(null);
  const load = async () => {
    // A control plane before channel links (#1762) has none to list.
    links.value = await store.link.call("links/requests", {}).catch(() => []);
  };
  useEffect(() => { if (!down) void load(); }, [down]);
  const decide = async (request: ChannelLinkRequest, approve: boolean) => {
    try {
      await store.link.call(approve ? "links/approve" : "links/deny", { request: request.request });
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
    await load();
  };
  const joins = liveJoins(store.joinRequests.value);
  const cap = store.capReached.value;
  const none = joins.length === 0 && links.value.length === 0 && !cap;
  return (
    <div class="requests">
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {none && <p class="hint">{noRequests}</p>}
      {joins.length > 0 && (
        <section aria-labelledby="requests-joins">
          <h3 class="section-head" id="requests-joins">Machines</h3>
          <JoinRequests store={store} down={down} />
        </section>
      )}
      {links.value.length > 0 && (
        <section aria-labelledby="requests-links">
          <h3 class="section-head" id="requests-links">Channels</h3>
          <ul class="request-list">
            {links.value.map((r) => (
              <li key={r.request} class="request">
                <span>{linkWords(r)}</span>
                <span class="request-actions">
                  <button type="button" disabled={down} onClick={() => void decide(r, false)}>Refuse</button>
                  <button type="button" class="prominent" disabled={down} onClick={() => void decide(r, true)}>Approve</button>
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}
      {cap && (
        <section aria-labelledby="requests-caps">
          <h3 class="section-head" id="requests-caps">Spend Caps</h3>
          <ul class="request-list">
            <li class="request">
              <span>{capReachedWords(cap)}</span>
              <span class="request-actions">
                <button type="button" onClick={() => go({ app: "console", section: "people" })}>Change Cap…</button>
              </span>
            </li>
          </ul>
        </section>
      )}
      <p class="hint">{requestsFoot}</p>
    </div>
  );
}

/** How many requests wait, for the Console's list. */
export function requestCount(store: Store): number {
  return liveJoins(store.joinRequests.value).length + (store.capReached.value ? 1 : 0);
}
