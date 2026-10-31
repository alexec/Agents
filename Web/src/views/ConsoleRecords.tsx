// The Console's records (#1804): Audit (M8), who did what, for one person or everyone, with CSV;
// and Requests (M7), what waits for an admin: machines asking to join, channel identities asking
// to be linked, and bots stopped at a cap.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { ChannelLinkRequest, PersonRow, RemoveRequest } from "../protocol/generated";
import { failedWords, linkWords, noRequests, requestsFoot, waitingCount } from "../model/console";
import { capReachedWords } from "../model/teamGroups";
import { liveJoins } from "../model/people";
import { liveRequests, withoutRequest } from "../model/channelLinks";
import { AuditPane } from "./Audit";
import { AuditSinks } from "./AuditSinks";
import { BotSheet, RemoveSheet } from "./People";
import { orgName } from "../model/signIn";
import { fromWireDate } from "../protocol/dates";
import { when } from "../model/orgPolicy";
import { JoinRequests } from "./JoinRequest";
import { GovernanceRequests } from "./Governance";

/** M8: the audit, every machine's names from the fleet, and a person to narrow it to. */
export function AuditPage({ store, down }: { store: Store; down: boolean }) {
  const names = useSignal<Record<string, string>>({});
  // The store's one people list (#2055); a control plane before people has none.
  const people: PersonRow[] | null = store.people.value?.people ?? (store.peopleFailure.value ? [] : null);
  useEffect(() => {
    if (down) return;
    void store.link.call("console/fleet", {}).then((b) => {
      names.value = Object.fromEntries(b.machines.map((m) => [m.host.id, m.host.name]));
    }, () => {});
  }, [down]);
  if (people === null) return <p class="hint">Loading…</p>;
  return <>
    <AuditPane store={store} people={people} hostName={(host) => names.value[host] ?? host} />
    {/* Where each entry is also sent (#1001), an admin's. */}
    <AuditSinks store={store} down={down} />
  </>;
}

/** M7: each request with its answer. Join requests and a bot at its cap come as notifications too. The
 * link requests are the store's, as the count beside Requests is (#2070). */
export function RequestsPage({ store, down }: { store: Store; down: boolean }) {
  const problem = useSignal<string | null>(null);
  const decide = async (request: ChannelLinkRequest, approve: boolean) => {
    try {
      await store.link.call(approve ? "links/approve" : "links/deny", { request: request.request });
      store.linkRequests.value = withoutRequest(store.linkRequests.value, request.request);
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  const links = liveRequests(store.linkRequests.value);
  // Change Cap…: that bot's Group and Cap… sheet, here (#2088).
  const changing = useSignal<PersonRow | null>(null);
  const joins = liveJoins(store.joinRequests.value);
  // Every bot stopped at a cap, while it is true (#2073, #2088).
  const capped = store.capped.value;
  // A person their provider's SCIM deleted, suspended until an admin removes them (#1002, FR-017, FR-031).
  // In the store, so the Console's count has them too (#2436).
  const removals = store.removeRequests;
  const removing = useSignal<PersonRow | null>(null);
  const loadRemovals = () => store.loadRemoveRequests();
  useEffect(() => { if (!down) void loadRemovals(); }, [down]);
  const none = requestCount(store) === 0;
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
      {links.length > 0 && (
        <section aria-labelledby="requests-links">
          <h3 class="section-head" id="requests-links">Channels</h3>
          <ul class="request-list">
            {links.map((r) => (
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
      {capped.length > 0 && (
        <section aria-labelledby="requests-caps">
          <h3 class="section-head" id="requests-caps">Spend Caps</h3>
          <ul class="request-list">
            {capped.map((reached) => {
              const bot = store.people.value?.people.find((p) => p.id === reached.user) ?? null;
              return (
                <li key={reached.user} class="request">
                  <span>{capReachedWords(reached)}</span>
                  <span class="request-actions">
                    <button type="button" title="Keep the cap as it is" onClick={() => store.dismissCap(reached)}>OK</button>
                    <button type="button" disabled={down || !bot} onClick={() => { changing.value = bot; }}>Change Cap…</button>
                  </span>
                </li>
              );
            })}
          </ul>
        </section>
      )}
      {/* People asking for an MCP server or skill (#2019, M5). */}
      <GovernanceRequests store={store} down={down} />
      {removals.value.length > 0 && (
        <section aria-labelledby="requests-removals">
          <h3 class="section-head" id="requests-removals">Removals</h3>
          <ul class="request-list">
            {removals.value.map((r) => {
              const person = store.people.value?.people.find((p) => p.id === r.user) ?? null;
              return (
                <li key={r.user} class="request">
                  <span>{removeRequestWords(r, orgName(r.provider, store.orgProviderNames.value))}</span>
                  <span class="request-actions">
                    <button type="button" class="destructive" disabled={down || !person} onClick={() => { removing.value = person; }}>Remove…</button>
                  </span>
                </li>
              );
            })}
          </ul>
        </section>
      )}
      {removing.value && (
        <RemoveSheet store={store} person={removing.value} close={() => { removing.value = null; void loadRemovals(); }} />
      )}
      {changing.value && (
        <BotSheet store={store} bot={changing.value} groups={store.providers.groups.value} close={() => { changing.value = null; }} />
      )}
      <p class="hint">{requestsFoot}</p>
    </div>
  );
}

/** How many requests wait, for the Console's list and its Overview: machines, channel identities, capped bots (#2070),
 * asks for an MCP server or skill (#2019, M5), and people SCIM removed (#2436). */
export function requestCount(store: Store): number {
  return waitingCount({ joins: liveJoins(store.joinRequests.value).length, links: liveRequests(store.linkRequests.value).length,
    capped: store.capped.value.length, governance: store.governanceRequests.value.length, removals: store.removeRequests.value.length });
}

/** "Acme Okta deleted Bea on 12 Oct at 09:30. Bea is suspended until you remove them." */
export function removeRequestWords(r: RemoveRequest, provider: string, now: Date = new Date()): string {
  return `${provider} deleted ${r.name} ${when(fromWireDate(r.at), now)}. ${r.name} is suspended until an admin removes them.`;
}
