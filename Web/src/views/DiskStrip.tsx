// Across the top of the page while a volume a host's agents write to is low on space (#196; the
// window's DiskStrip, #195): how much is free, and the largest worktrees when they could be
// measured. Gone by itself once it climbs back. A server's are named, as its offline strip is.
import type { Store } from "../model/store";
import { diskLine } from "../model/disk";

export function DiskStrip({ store }: { store: Store }) {
  const rows = Object.entries(store.disk.value).flatMap(([host, state]) =>
    state.alarms.map((alarm) => ({ host, alarm })));
  if (rows.length === 0) return null;
  return (
    <>
      {rows.map(({ host, alarm }) => {
        const name = host === "mac" ? null : store.hosts.value.find((h) => h.id === host)?.name ?? host;
        return (
          <p key={`${host}|${alarm.reading.mount}`} class={`disk-strip ${alarm.level}`} role="status">
            <span class="dot" aria-hidden="true" />
            {name ? `${name}: ${diskLine(alarm)}` : diskLine(alarm)}
          </p>
        );
      })}
    </>
  );
}
