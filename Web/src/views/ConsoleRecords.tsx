// The Console's records (#1804): Audit (M8), who did what, for one person or everyone, with CSV;
// and Requests (M7), what waits for an admin: machines asking to join, channel identities asking
// to be linked, bots stopped at a cap, and people at the organisation's budget asking for more (#3262).
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { BudgetRequest, ChannelLinkRequest, PersonRow, RemoveRequest } from "../protocol/generated";
import { budgetRequestWords, budgetsFoot, budgetsTitle, failedWords, linkWords, noRequests, raiseDefault, raiseTitle, requestsFoot, waitingCount,
  withBudgetRequest } from "../model/console";
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
import { MessageBanner } from "./MessageKinds";

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
      {problem.value && <MessageBanner tone="failure">{problem.value}</MessageBanner>}
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
                  <button type="button" disabled={down} onClick={() => void decide(r, false)}>Deny</button>
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
      {/* People at the organisation's budget asking for more today (#3262). */}
      <BudgetRequests store={store} down={down} />
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

/** Console ▸ Requests ▸ Budgets (#3262, spec 998 FR-019): each Ask for More, to raise for today (policy/raise with the
 * request's id) or refuse (policy/refuseMore). The raise starts at twice the budget a day, in dollars, or in tokens
 * when the policy sets only tokens. */
function BudgetRequests({ store, down }: { store: Store; down: boolean }) {
  const problem = useSignal<string | null>(null);
  const amounts = useSignal<Record<string, string>>({});
  const list = store.budgetRequests.value;
  // The budget a day, for the raise to start from: policy/mine, if Settings ▸ Policy has not read it yet.
  useEffect(() => {
    if (list.length > 0 && !down && store.orgPolicy.value === null) {
      void store.link.call("policy/mine", {}).then((view) => { if (store.orgPolicy.value === null) store.orgPolicy.value = view; }, () => {});
    }
  }, [list.length > 0, down]);
  if (list.length === 0) return null;
  const budgets = store.orgPolicy.value?.policy?.budgets;
  const inTokens = budgets?.daily === undefined && budgets?.dailyTokens !== undefined;
  const amount = (r: BudgetRequest) => amounts.value[r.id] ?? raiseDefault(inTokens ? budgets?.dailyTokens : budgets?.daily);
  const answer = async (r: BudgetRequest, raise: boolean) => {
    try {
      if (raise) {
        const to = Number(amount(r));
        await store.link.call("policy/raise", { user: r.user, ...(inTokens ? { dailyTokens: Math.round(to) } : { daily: to }), request: r.id });
        store.budgetRequests.value = withBudgetRequest(store.budgetRequests.value, { ...r, state: "raised" });
      } else {
        store.budgetRequests.value = withBudgetRequest(store.budgetRequests.value, await store.link.call("policy/refuseMore", { request: r.id }));
      }
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
      void store.loadBudgetRequests();
    }
  };
  return (
    <section aria-labelledby="requests-budgets">
      <h3 class="section-head" id="requests-budgets">{budgetsTitle}</h3>
      {problem.value && <MessageBanner tone="failure">{problem.value}</MessageBanner>}
      <ul class="request-list">
        {list.map((r) => {
          const usd = Number(amount(r));
          return (
            <li key={r.id} class="request">
              <span>{budgetRequestWords(r)}</span>
              <span class="request-actions">
                <label class="amount">
                  <span>{inTokens ? "To tokens" : "To $"}</span>
                  <input type="number" min="0" step={inTokens ? "1" : "any"} disabled={down}
                    aria-label={`Today's budget for ${r.userName}, in ${inTokens ? "tokens" : "dollars"}`}
                    value={amount(r)} onInput={(e) => { amounts.value = { ...amounts.value, [r.id]: (e.currentTarget as HTMLInputElement).value }; }} />
                </label>
                <button type="button" disabled={down} onClick={() => void answer(r, false)}>Deny</button>
                <button type="button" class="prominent" disabled={down || !(usd > 0)} onClick={() => void answer(r, true)}>{raiseTitle}</button>
              </span>
            </li>
          );
        })}
      </ul>
      <p class="hint">{budgetsFoot}</p>
    </section>
  );
}

/** How many requests wait, for the Console's list and its Overview: machines, channel identities, capped bots (#2070),
 * asks for an MCP server or skill (#2019, M5), and people SCIM removed (#2436). */
export function requestCount(store: Store): number {
  return waitingCount({ joins: liveJoins(store.joinRequests.value).length, links: liveRequests(store.linkRequests.value).length,
    capped: store.capped.value.length, governance: store.governanceRequests.value.length, budgets: store.budgetRequests.value.length,
    removals: store.removeRequests.value.length });
}

/** "Acme Okta deleted Bea on 12 Oct at 09:30. Bea is suspended until you remove them." */
export function removeRequestWords(r: RemoveRequest, provider: string, now: Date = new Date()): string {
  return `${provider} deleted ${r.name} ${when(fromWireDate(r.at), now)}. ${r.name} is suspended until an admin removes them.`;
}
