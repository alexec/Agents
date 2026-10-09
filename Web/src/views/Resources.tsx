// A host's resources, read-only (#116): what the person declared there, each with its
// description and "2 of 3 held", then whatever else is held or awaited. Declaring and ending
// leases are the Mac's (Settings ▸ Resources, the Resources page), as on the Remote.
import type { Store } from "../model/store";
import type { Lease, ResourceState } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { hostedLastError, hostedLine, hostedPlace } from "../model/hostedMCP";

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

export function Resources({ store, host, open }: { store: Store; host: string; open?: boolean }) {
  const snapshot = store.leases.value[host];
  if (!snapshot) return null;
  const declared = snapshot.resources.filter((r) => r.declared);
  const busy = snapshot.resources.filter((r) => !r.declared && ((r.holds ?? []).length > 0 || r.line.length > 0));
  if (declared.length === 0 && busy.length === 0) return null;
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
    <details class="resources" open={open}>
      <summary class="subhead">Resources <span class="count">{declared.length + busy.length}</span></summary>
      <ul>{declared.map(row)}{busy.map(row)}</ul>
      <p class="hint">Declared on the Mac, in Settings ▸ Resources. Agents lease one whenever its description applies.</p>
    </details>
  );
}

/** The MCP servers a host runs once for every agent (#488), read-only. */
export function HostedMCP({ store, host }: { store: Store; host: string }) {
  const servers = store.hostedMCP.value[host]?.servers ?? [];
  if (servers.length === 0) return null;
  return (
    <details class="resources hosted-mcp" open>
      <summary class="subhead">Hosted MCP servers <span class="count">{servers.length}</span></summary>
      <ul>
        {servers.map((status) => {
          const error = hostedLastError(status);
          return (
            <li class="resource" key={`${status.project ?? "~"}|${status.name}`}>
              <p><span class="strong">{status.name}</span> <span class="quiet small">{hostedPlace(status)}</span></p>
              <p class="quiet small">{hostedLine(status)}</p>
              {error && <p class={status.state === "restarting" ? "small failure" : "quiet small"}>{error}</p>}
            </li>
          );
        })}
      </ul>
      <p class="hint">Run once on this host for every agent, from "hosted": true in mcp.json.</p>
    </details>
  );
}
