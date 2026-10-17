// Under a host's offline strip, over its chats and a new session, while a volume that host's agents
// write to is low on space (#196; the window's DiskStrip, #195): how much is free, and the largest
// worktrees when they could be measured. Said where the host's work is, not across the page, so it
// never reads as the browser's own disk (#1329). Gone by itself once it climbs back.
import type { Store } from "../model/store";
import { diskLine } from "../model/disk";

export function DiskStrip({ store, host }: { store: Store; host: string }) {
  const alarms = store.disk.value[host]?.alarms ?? [];
  if (alarms.length === 0) return null;
  return (
    <>
      {alarms.map((alarm) => (
        <p key={alarm.reading.mount} class={`disk-strip ${alarm.level}`} role="status">
          <span class="dot" aria-hidden="true" />
          {diskLine(alarm)}
        </p>
      ))}
    </>
  );
}
