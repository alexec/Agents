// Settings ▸ Policy (#998, spec 998 FR-021, FR-022): the organisation's rules in words, read only, with
// the last change and who made it; for an admin, Edit in Console and the kill switch. The same as the
// window's and the Remote's pane (Shared/UI/OrgPolicyPane.swift). Console ▸ Policy draws the kill switch too.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../../model/store";
import type { OrgPolicy, OrgRouteMine } from "../../protocol/generated";
import { fromWireDate } from "../../protocol/dates";
import { go } from "../../route";
import { describe } from "../../model/errors";
import { changed, editPolicy, foot, none, resumeAll, resumeMessage, resumeTitle, rules, runningAgents, stopAll, stopFoot,
  stopMessage, stopTitle, stoppedBy, stoppedStrip, title, viewOf } from "../../model/orgPolicy";
import { fromOrganisation, mineLine, noRoutes, routesFoot, routesTitle } from "../../model/orgAccounts";
import { GovernanceAsk } from "../Governance";

/** The red strip while the kill switch is on, and the time it went on. */
export function StoppedStrip({ policy }: { policy: OrgPolicy | undefined }) {
  const stop = policy?.stopAll;
  if (!stop?.on) return null;
  return (
    <p class="policy-stopped" role="alert">
      <strong>{stoppedStrip}</strong> <span class="small">{stoppedBy(stop, fromWireDate(stop.at), new Date())}</span>
      {stop.note && <><br /><span class="small">{stop.note}</span></>}
    </p>
  );
}

/** Stop All Agent Work, or Resume Agent Work while it is on: an admin's, asked first. */
export function KillSwitch({ store, policy, down, changedTo }: { store: Store; policy: OrgPolicy | undefined; down: boolean;
  changedTo?: (policy: OrgPolicy | undefined) => void }) {
  const busy = useSignal(false);
  const on = policy?.stopAll?.on === true;
  const flip = async () => {
    let running: number | undefined;
    if (!on) {
      // The running agents each machine last listed; the question asks without them when this fails.
      running = await store.link.call("console/fleet", {}).then((b) => runningAgents(b.machines), () => undefined);
    }
    if (!window.confirm(on ? `${resumeTitle}\n\n${resumeMessage}` : `${stopTitle}\n\n${stopMessage(running)}`)) return;
    busy.value = true;
    try {
      const kept = await store.link.call("policy/stopAll", { on: !on });
      store.orgPolicy.value = viewOf(kept.policy);
      changedTo?.(kept.policy);
    } catch (error) {
      store.say(describe(error));
    } finally {
      busy.value = false;
    }
  };
  return (
    <div class="policy-kill">
      <button type="button" class={on ? "" : "destructive"} disabled={down || busy.value} onClick={() => void flip()}>
        {on ? resumeAll : stopAll}
      </button>
      <p class="hint">{stopFoot}</p>
    </div>
  );
}

export function PolicySection({ store, down }: { store: Store; down: boolean }) {
  const problem = useSignal<string | null>(null);
  // The routes this person may use (#999); null from a control plane before them, which shows none.
  const routes = useSignal<OrgRouteMine[] | null>(null);
  const admin = store.person.value?.role === "admin";
  const load = async () => {
    try {
      store.orgPolicy.value = await store.link.call("policy/mine", {});
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
  };
  const loadRoutes = async () => {
    routes.value = await store.link.call("orgRoutes/mine", {}).then((m) => m.routes, () => null);
  };
  useEffect(() => { if (!down) void load(); }, [down]);
  const routeChanges = store.orgRoutesChanges.value;
  useEffect(() => { if (!down) void loadRoutes(); }, [down, routeChanges]);
  const view = store.orgPolicy.value;
  const policy = view?.policy;
  const list = policy ? rules(policy) : [];
  return (
    <section aria-labelledby="settings-policy">
      <h3 class="section-head" id="settings-policy">{title}</h3>
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {!view && !problem.value && <p class="hint">Loading…</p>}
      {view && (
        <>
          <StoppedStrip policy={policy} />
          {list.length === 0 ? <p class="hint">{none}</p> : (
            <dl class="policy-rules">
              {list.map((r) => (
                <div key={r.name} class="setting">
                  <dt>{r.title}</dt>
                  <dd>{r.words}</dd>
                </div>
              ))}
            </dl>
          )}
          {policy && <p class="quiet small">{changed(policy, fromWireDate(policy.issued), new Date())}</p>}
          {routes.value && (
            <>
              <h4 class="section-head">{routesTitle}</h4>
              {routes.value.length === 0 ? <p class="hint">{noRoutes}</p> : (
                <ul class="policy-routes">
                  {routes.value.map((r) => (
                    <li key={r.id}>
                      <span class="strong">{r.name}</span> <span class="quiet small">{fromOrganisation}</span><br />
                      <span class="small">{mineLine(r)}</span>
                    </li>
                  ))}
                </ul>
              )}
              <p class="hint">{routesFoot}</p>
            </>
          )}
          {/* A person's ask for an MCP server or skill (#2019, M5). */}
          <GovernanceAsk store={store} down={down} />
          {admin && (
            <>
              <div class="policy-kill">
                <button type="button" onClick={() => go({ nav: "settings", section: "policy" })}>{editPolicy}</button>
              </div>
              <KillSwitch store={store} policy={policy} down={down} />
            </>
          )}
          <p class="hint">{foot}</p>
        </>
      )}
    </section>
  );
}
