// Across the top of a chat or a new session whose host is down (#83; the window's OfflineStrip):
// this Mac's host in the window's words, with since when, because nothing of this Mac's moves
// until it is back; a server's as before, because its agents keep working. The control plane
// dials the host again by itself; the page has nothing of its own to try sooner.
import type { Store } from "../model/store";

export function OfflineStrip({ store, host }: { store: Store; host: string }) {
  if (store.hostIsOnline(host)) return null;
  const since = store.downSince.value[host];
  const at = since ? new Date(since).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : null;
  const name = store.hosts.value.find((h) => h.id === host)?.name ?? "This host";
  return (
    <p class="offline-strip" role="status">
      <span class="dot" aria-hidden="true" />
      {host === "mac"
        ? `This Mac\u2019s host hasn\u2019t answered${at ? ` since ${at}` : ""}. Nothing here can change until it\u2019s back. Trying again\u2026`
        : `${name} is offline${at ? ` since ${at}` : ""}. Agents there keep working; nothing can be sent until it\u2019s back.`}
    </p>
  );
}
