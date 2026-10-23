// Catalogue governance (#2019, M5): a person's ask for an MCP server or skill (in Settings ▸ Policy),
// the waiting ones on Console ▸ Requests, and Console ▸ Catalogue: who uses each, at which version,
// and what is approved for whom. The web page's only: the Console is the web page's (#1804).
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { CatalogApproval, CatalogKind, CatalogRequest, CatalogUsage } from "../protocol/generated";
import { approvalFor, takeBackQuestion, approvalsFoot, approvalsTitle, askFoot, askTitle, itemWords, kindNames, mineWords, noApprovals, noUsage,
  requestWords, usageFoot, usageTitle, usersWords, withGovernanceRequest } from "../model/governance";
import { failedWords } from "../model/console";

/** A person's ask, and their own requests of the last 30 days. Nothing from a control plane before them. */
export function GovernanceAsk({ store, down }: { store: Store; down: boolean }) {
  const mine = useSignal<CatalogRequest[] | null>(null);
  const kind = useSignal<CatalogKind>("mcp");
  const name = useSignal("");
  const why = useSignal("");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const load = () => store.link.call("governance/requests", {}).then((l) => { mine.value = l.requests; }, () => { mine.value = null; });
  const changes = store.governanceChanges.value;
  useEffect(() => { if (!down) void load(); }, [down, changes]);
  if (mine.value === null) return null;
  const ask = async () => {
    busy.value = true;
    try {
      await store.link.call("governance/request", { kind: kind.value, name: name.value, ...(why.value ? { why: why.value } : {}) });
      name.value = "";
      why.value = "";
      problem.value = null;
      await load();
    } catch (error) {
      problem.value = failedWords(error);
    } finally {
      busy.value = false;
    }
  };
  const admin = store.people.value?.admin ?? false;
  const own = admin ? mine.value.filter((r) => r.user === store.person.value?.id) : mine.value;
  return (
    <>
      <h4 class="section-head">{askTitle}</h4>
      <form class="org-policy" onSubmit={(e) => { e.preventDefault(); void ask(); }}>
        <label class="setting">
          <span>Kind</span>
          <select aria-label="Kind" value={kind.value} disabled={down || busy.value}
            onChange={(e) => { kind.value = (e.currentTarget as HTMLSelectElement).value as CatalogKind; }}>
            <option value="mcp">{kindNames.mcp}</option>
            <option value="skills">{kindNames.skills}</option>
          </select>
        </label>
        <label class="setting">
          <span>Name</span>
          <input type="text" spellcheck={false} aria-label="Name" placeholder="github" value={name.value} disabled={down || busy.value}
            onInput={(e) => { name.value = (e.currentTarget as HTMLInputElement).value; }} />
        </label>
        <label class="setting">
          <span>Why</span>
          <input type="text" class="wide" aria-label="Why" placeholder="To review pull requests" value={why.value} disabled={down || busy.value}
            onInput={(e) => { why.value = (e.currentTarget as HTMLInputElement).value; }} />
        </label>
        {problem.value && <p class="hint" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          <button type="submit" class="prominent" disabled={down || busy.value || name.value.trim() === ""}>Ask</button>
        </div>
      </form>
      {own.length > 0 && (
        <ul class="policy-routes">
          {own.map((r) => <li key={r.id} class="small">{mineWords(r, store.orgPolicy.value?.policy?.marketplaces !== undefined)}</li>)}
        </ul>
      )}
      <p class="hint">{askFoot}</p>
    </>
  );
}

/** Console ▸ Requests: each waiting request, to approve for the person or a group, or refuse. */
export function GovernanceRequests({ store, down }: { store: Store; down: boolean }) {
  const problem = useSignal<string | null>(null);
  const groupOf = useSignal<Record<string, string>>({});
  const list = store.governanceRequests.value;
  if (list.length === 0) return null;
  const groups = store.providers.groups.value ?? [];
  const decide = async (r: CatalogRequest, approve: boolean) => {
    try {
      const group = approve ? groupOf.value[r.id] : undefined;
      const decided = await store.link.call("governance/decide", { request: r.id, approve, ...(group ? { group } : {}) });
      store.governanceRequests.value = withGovernanceRequest(store.governanceRequests.value, decided);
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
      void store.loadGovernanceRequests();
    }
  };
  return (
    <section aria-labelledby="requests-governance">
      <h3 class="section-head" id="requests-governance">MCP Servers and Skills</h3>
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      <ul class="request-list">
        {list.map((r) => (
          <li key={r.id} class="request">
            <span>{requestWords(r)}</span>
            <span class="request-actions">
              <select aria-label={`Approve ${itemWords(r.kind, r.name)} for`} disabled={down} value={groupOf.value[r.id] ?? ""}
                onChange={(e) => { groupOf.value = { ...groupOf.value, [r.id]: (e.currentTarget as HTMLSelectElement).value }; }}>
                <option value="">For {r.userName}</option>
                {groups.map((g) => <option key={g.id} value={g.id}>For {g.name}</option>)}
              </select>
              <button type="button" disabled={down} onClick={() => void decide(r, false)}>Refuse</button>
              <button type="button" class="prominent" disabled={down} onClick={() => void decide(r, true)}>Approve</button>
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** Console ▸ Catalogue: who uses each MCP server and skill, at which version, and the approvals. */
export function CataloguePage({ store, down }: { store: Store; down: boolean }) {
  const usage = useSignal<CatalogUsage | null>(null);
  const approvals = useSignal<CatalogApproval[] | null>(null);
  const problem = useSignal<string | null>(null);
  const load = async () => {
    try {
      const [u, a] = await Promise.all([store.link.call("governance/usage", {}), store.link.call("governance/approvals", {})]);
      usage.value = u;
      approvals.value = a.approvals;
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  const changes = store.governanceRequests.value;
  useEffect(() => { if (!down) void load(); }, [down, changes]);
  const revoke = async (a: CatalogApproval) => {
    try {
      const left = await store.link.call("governance/revoke", { kind: a.kind, name: a.name, ...(a.group ? { group: a.group } : {}), ...(a.user ? { user: a.user } : {}) });
      approvals.value = left.approvals;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  if (problem.value) return <p class="hint" role="alert">{problem.value}</p>;
  if (!usage.value || !approvals.value) return <p class="hint">Loading…</p>;
  return (
    <>
      <section aria-labelledby="catalogue-usage">
        <h3 class="section-head" id="catalogue-usage">{usageTitle}</h3>
        {usage.value.rows.length === 0 ? <p class="hint">{noUsage}</p> : (
          <table class="console-table">
            <thead><tr><th>Name</th><th>Kind</th><th>Version</th><th>Used on</th></tr></thead>
            <tbody>
              {usage.value.rows.map((r) => (
                <tr key={`${r.kind}/${r.name}/${r.version}`}>
                  <td><span class="strong">{r.name}</span>{r.source && <><br /><span class="quiet small">{r.source}</span></>}</td>
                  <td>{kindNames[r.kind]}</td>
                  <td>{r.version || <span class="quiet">None</span>}</td>
                  <td>{usersWords(r)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p class="hint">{usageFoot}</p>
      </section>
      <section aria-labelledby="catalogue-approvals">
        <h3 class="section-head" id="catalogue-approvals">{approvalsTitle}</h3>
        {approvals.value.length === 0 ? <p class="hint">{noApprovals}</p> : (
          <ul class="request-list">
            {approvals.value.map((a) => (
              <li key={`${a.kind}/${a.name}/${a.group ?? ""}/${a.user ?? ""}`} class="request">
                <span>{kindNames[a.kind]} <span class="strong">{a.name}</span>, for {approvalFor(a)}. <span class="quiet small">Approved by {a.by}.</span></span>
                <span class="request-actions">
                  <button type="button" class="destructive" disabled={down} onClick={() => {
                    if (window.confirm(takeBackQuestion(a.kind, a.name, approvalFor(a)))) void revoke(a);
                  }}>Take Back…</button>
                </span>
              </li>
            ))}
          </ul>
        )}
        <p class="hint">{approvalsFoot}</p>
      </section>
    </>
  );
}
