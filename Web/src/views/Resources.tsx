// A machine's resources, read-only (#116), as a section of its page (#3629; MachineResourcesSection.swift):
// what the person declared there, each with its description and "2 of 3 held", then whatever else is held
// or awaited. Declaring and ending leases are the Mac's (Settings ▸ Resources, the machine's page).
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import type { Store } from "../model/store";
import type { Lease, ResourceState } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { noResourcesHint, resourcesHint } from "../model/onTheMac";

/** "14:05", twenty-four hours, as LeaseWords.clock says it to agents and the Mac. */
function clock(at: number): string {
  const date = fromWireDate(at as never);
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function holderName(store: Store, host: string, id: string): string {
  const title = store.agent(host, id)?.title?.trim();
  return title ? `“${title}”` : "another agent";
}

/** "2 of 3 held", "Held" or "Free". */
export function heldWords(state: ResourceState): string {
  const places = state.places ?? 1;
  const holds = state.holds ?? (state.lease ? [state.lease] : []);
  if (places > 1) return `${holds.length} of ${places} held`;
  return holds.length > 0 ? "Held" : "Free";
}

/** Set by a chat's lease line: the machine's page it opens scrolls to its Resources, once. */
export const resourcesAsked = signal(false);

export function Resources({ store, host }: { store: Store; host: string }) {
  const snapshot = store.leases.value[host];
  const ref = useRef<HTMLElement>(null);
  const asked = resourcesAsked.value;
  useEffect(() => {
    if (!asked || !snapshot) return;
    ref.current?.scrollIntoView({ block: "start" });
    resourcesAsked.value = false;
  }, [asked, snapshot !== undefined]);
  const declared = snapshot?.resources.filter((r) => r.declared) ?? [];
  const busy = snapshot?.resources.filter((r) => !r.declared && ((r.holds ?? []).length > 0 || r.line.length > 0)) ?? [];
  const row = (state: ResourceState) => {
    const holds: Lease[] = state.holds ?? (state.lease ? [state.lease] : []);
    return (
      <li class="resource" key={state.name}>
        <p><span class="strong">{state.displayName}</span> <span class="quiet small">{heldWords(state)}</span></p>
        {state.declared && <p class="quiet small">{state.declared.description}</p>}
        {holds.map((lease) => (
          <p class="quiet small" key={lease.holder}>{holderName(store, host, lease.holder)} until {clock(lease.expiresAt)}</p>
        ))}
        {state.line.length > 0 && (
          <p class="quiet small">{state.line.length} waiting: {state.line.map((m) => holderName(store, host, m.agentID)).join(", ")}</p>
        )}
      </li>
    );
  };
  return (
    <section class="resources" aria-labelledby="machine-resources" ref={ref}>
      <h3 class="section-head" id="machine-resources">Resources</h3>
      {!snapshot ? <p class="hint">Loading…</p>
        : declared.length === 0 && busy.length === 0 ? <p class="hint">{noResourcesHint(store.hasMac.value)}</p>
        : <>
          <ul>{declared.map(row)}{busy.map(row)}</ul>
          <p class="hint">{resourcesHint(store.hasMac.value)}</p>
        </>}
    </section>
  );
}
