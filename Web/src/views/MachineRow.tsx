// A machine's row in the Machines section (#3974), as the window's MachineRow (#3973): the dot, the
// name and the grey line; its menu on a right-click, from ··· on hover or a finger held on it; and on
// a touch screen a swipe to the right starts or stops it, to the left deletes or removes it, both asked first.
import { useRef } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import type { Store } from "../model/store";
import { deleteQuestion, machineActions, machineDot, machineSwipes, removeQuestion, swipeDistance } from "../model/machineRow";
import { placedSessions } from "../model/overview";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { chooseSettingsMachine } from "./settings/SettingsMachine";
import { go } from "../route";

/** Settings ▸ Machines' section for this machine (#3979): Backups… and Processes… open it there. */
function openSettings(host: string, section: string) {
  chooseSettingsMachine(host);
  go({ nav: "settings" });
  setTimeout(() => document.getElementById(section)?.scrollIntoView({ block: "start" }), 0);
}

const swipeWords = { start: "Start", stop: "Stop", delete: "Delete", remove: "Remove" } as const;

export function MachineRow({ store, host, on, open, mark, children }: {
  store: Store; host: string; on: boolean; open: () => void; mark: ComponentChildren; children: ComponentChildren;
}) {
  const row = store.hosts.value.find((h) => h.id === host);
  const dx = useSignal(0);
  const from = useRef<{ x: number; y: number; across: boolean } | null>(null);
  const swiped = useRef(false);
  if (!row) return null;
  const mac = host === store.macHostID.value;
  const name = mac ? "This Mac" : row.name;
  const actions = machineActions(row, store.macHostID.value);
  const swipes = machineSwipes(actions);
  const dot = machineDot(row, store.hostIsOnline(host), store.hostsBeingStarted.value.includes(host));

  const stop = async () => {
    const asked = await store.providers.stop(host);
    if (typeof asked === "string") store.say(asked);
    else if (asked && window.confirm(`Stop ${row.name}? ${asked.question}`)) {
      const again = await store.providers.stop(host, true);
      if (typeof again === "string") store.say(again);
    }
  };
  const sessions = () => placedSessions([row], store.folders.value,
    (h, f) => store.folderView(h, f).headings.flatMap((x) => x.agents)).length;
  const run = {
    start: () => void store.startHost(host),
    stop: () => void stop(),
    // Delete asks the machine first which worktrees have work not pushed (#3979).
    delete: () => void store.deletePreview(host).then((preview) => {
      if (window.confirm(deleteQuestion(row, sessions(), preview))) void store.deleteHost(host);
    }),
    remove: () => { if (window.confirm(removeQuestion(row))) void store.removeHost(host); },
  };
  const items = (): MenuItem[] => [
    { label: "Open", run: open },
    ...(actions.start ? [{ label: "Start", run: run.start }] : []),
    ...(actions.stop ? [{ label: "Stop", run: run.stop }] : []),
    // As Settings ▸ Machines has them (#3979).
    ...(mac ? [] : [
      { label: "Check Again", run: () => void store.checkAgain(host) },
      { label: "Backups…", disabled: !store.hostIsOnline(host), run: () => openSettings(host, "settings-server-backups") },
      { label: "Processes…", disabled: !store.hostIsOnline(host), run: () => openSettings(host, "settings-processes") },
    ]),
    ...(actions.delete ? [{ label: `Delete ${row.name}…`, run: run.delete }] : []),
    ...(actions.remove ? [{ label: `Remove ${row.name}…`, run: run.remove }] : []),
  ];

  // A finger across the row, not down the list: the row follows it, and past swipeDistance lifting it acts.
  const swipe = {
    onPointerDown: (e: PointerEvent) => {
      if (e.pointerType === "mouse" || !e.isPrimary || (!swipes.leading && !swipes.trailing)) return;
      from.current = { x: e.clientX, y: e.clientY, across: false };
    },
    onPointerMove: (e: PointerEvent) => {
      const f = from.current;
      if (!f) return;
      const x = e.clientX - f.x;
      if (!f.across && Math.abs(x) > 8 && Math.abs(x) > Math.abs(e.clientY - f.y)) f.across = true;
      if (!f.across) return;
      dx.value = Math.max(swipes.trailing ? -swipeDistance * 1.5 : 0, Math.min(swipes.leading ? swipeDistance * 1.5 : 0, x));
    },
    onPointerUp: () => {
      const moved = dx.value;
      swiped.current = from.current?.across ?? false;
      from.current = null;
      dx.value = 0;
      if (moved >= swipeDistance && swipes.leading) run[swipes.leading]();
      else if (moved <= -swipeDistance && swipes.trailing) run[swipes.trailing]();
    },
    onPointerCancel: () => { from.current = null; dx.value = 0; },
  };
  const hold = holdForMenu(items);
  const shown = dx.value > 0 ? swipes.leading : dx.value < 0 ? swipes.trailing : null;

  return (
    <div class={`machine-row${dx.value ? " swiping" : ""}`}
      onPointerDown={(e) => { swipe.onPointerDown(e); hold.onPointerDown(e); }}
      onPointerMove={(e) => { swipe.onPointerMove(e); hold.onPointerMove(e); }}
      onPointerUp={() => { swipe.onPointerUp(); hold.onPointerUp(); }}
      onPointerCancel={() => { swipe.onPointerCancel(); hold.onPointerCancel(); }}>
      {shown && <span class={`machine-swipe ${shown} ${dx.value > 0 ? "leading" : "trailing"}`} aria-hidden="true">{swipeWords[shown]}</span>}
      <div class="machine-row-body" style={dx.value ? { transform: `translateX(${dx.value}px)` } : undefined}>
        <button type="button" class={`sub-app-row${on ? " on" : ""}`} aria-current={on ? "page" : undefined}
          onClick={() => { if (swiped.current) { swiped.current = false; return; } open(); }}
          onContextMenu={(e) => openContextMenu(e, items())}
          onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, items()); }}>
          <span class="machine-name"><span class={`machine-dot ${dot}`} aria-hidden="true" />{name}</span>
          {mark}
        </button>
        {!mac && <button type="button" class="machine-more" aria-label={`More for ${name}`}
          onClick={(e) => openContextMenu(e, items())}>···</button>}
        {children}
      </div>
    </div>
  );
}

/** A machine New Machine is making (#3974): an amber, turning dot and `Making…` until it joins. */
export function MakingRow({ name }: { name: string }) {
  return (
    <div class="machine-row making" role="status">
      <span class="sub-app-row"><span class="machine-name"><span class="machine-dot busy" aria-hidden="true" />{name || "New machine"}</span></span>
      <p class="machine-need quiet small">Making…</p>
    </div>
  );
}
