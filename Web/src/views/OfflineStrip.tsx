// Across the top of a chat or a new session whose host is down (#83; the window's OfflineStrip):
// this Mac's host in the window's words, with since when, because nothing of this Mac's moves
// until it is back; a server's as before, because its agents keep working. The control plane
// dials the host again by itself; the page has nothing of its own to try sooner, unless the host
// runs on a provider's workspace (#691, layouts.md L1): then a stopped or failed one offers Start,
// and a starting one shows a spinner and how long so far. The words are OfflineWords.swift's.
import { useEffect, useState } from "preact/hooks";
import type { ControlHost, HostWorkspace } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import type { Store } from "../model/store";

/** What a workspace host's strip says while it is stopped, starting or failed to start, or null
 *  when the ordinary offline line says it (OfflineWords.workspaceLine). */
export function workspaceLine(name: string, state: string, workspace: HostWorkspace): string | null {
  if (state === "starting") {
    switch (workspace.phase) {
      case "connecting": return `Waiting for ${name} to connect…`;
      case "sshStart": return `${name} started but agentsd didn’t connect; starting it over ssh…`;
      default: return `Starting ${name}…`;
    }
  }
  if (state === "stopping") return `Stopping ${name}…`;
  if (workspace.problem) return workspace.problem;
  if (state !== "stopped") return null;
  const by = workspace.stoppedBy;
  if (by) return `${name} was ${by.slice(0, 1).toLowerCase() + by.slice(1)}.`;
  return `${name} is stopped. Agents there are paused until it starts.`;
}

/** What the sidebar's foot says for a host that isn't online (#961; OfflineWords.footLine): a
 *  workspace's words, as its strip says them, or that it is connecting or offline. */
export function footLine(host: ControlHost): string {
  const said = host.workspace ? workspaceLine(host.name, host.state, host.workspace) : null;
  return said ?? `${host.name} is ${host.state === "connecting" ? "connecting…" : "offline"}`;
}

/** Whether the strip offers Start: a stopped or failed workspace, with nothing under way. */
export function offersStart(state: string, workspace: HostWorkspace): boolean {
  return workspace.canStart && state !== "online" && state !== "starting" && state !== "stopping";
}

/** The strip's timer while a start is under way: `0:24`. */
export function elapsed(since: number, now: number): string {
  const seconds = Math.max(0, Math.floor((now - since) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** What the strip draws for `host`: its words, a spinner or the dot, and Start or the timer. */
export function offlineStrip(host: string, row: ControlHost | undefined, at: string | null):
  { line: string; starting: boolean; since: number | null; start: boolean } {
  const name = row?.name ?? "This host";
  const state = row?.state ?? "offline";
  const workspace = row?.workspace;
  const said = workspace ? workspaceLine(name, state, workspace) : null;
  const line = said ?? (host === "mac"
    ? `This Mac’s host hasn’t answered${at ? ` since ${at}` : ""}. Nothing here can change until it’s back. Trying again…`
    : `${name} is offline${at ? ` since ${at}` : ""}. Agents there keep working; nothing can be sent until it’s back.`);
  const starting = workspace !== undefined && state === "starting";
  return {
    line,
    starting,
    since: starting && workspace?.since !== undefined ? fromWireDate(workspace.since).getTime() : null,
    start: workspace !== undefined && !starting && offersStart(state, workspace),
  };
}

export function OfflineStrip({ store, host }: { store: Store; host: string }) {
  if (store.hostIsOnline(host)) return null;
  const since = store.downSince.value[host];
  const at = since ? new Date(since).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : null;
  const row = store.hosts.value.find((h) => h.id === host);
  const strip = offlineStrip(host, row, at);
  return (
    <p class="offline-strip" role="status">
      {strip.starting ? <span class="spinner" aria-hidden="true" /> : <span class="dot" aria-hidden="true" />}
      <span class="words">{strip.line}</span>
      {strip.since !== null ? <Elapsed since={strip.since} />
        : strip.start ? (
          <button type="button" disabled={store.hostsBeingStarted.value.includes(host)}
            aria-label={`Start ${row?.name ?? "this host"}`} onClick={() => void store.startHost(host)}>Start</button>
        ) : null}
    </p>
  );
}

/** How long the start has been under way, counted every second. */
function Elapsed({ since }: { since: number }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const every = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(every);
  }, [since]);
  return <span class="elapsed">{elapsed(since, now)}</span>;
}
