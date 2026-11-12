// A machine's row in the Machines section (#3974), as the window's MachineRow (#3973): the icon (its
// kind in its shape, its state in its colour, #4113), the name and the grey line; its menu on a right-click, from ··· on hover or a finger held on it; and on
// a touch screen a swipe to the right starts or stops it, to the left deletes or removes it, both asked first.
import { useRef } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import type { Store } from "../model/store";
import { deleteQuestion, machineActions, machineDot, machineIcon, machineKind, machineSwipes, removeQuestion, swipeDistance,
  type MachineIconTone, type MachineKind, type MachineMaking } from "../model/machineRow";
import { machineSheets } from "../model/machineSheets";
import { placedSessions } from "../model/overview";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { MachineSheetDialog, type MachineSheet } from "./MachineSheets";
import { chooseSettingsMachine } from "./settings/SettingsMachine";
import { go } from "../route";
import { ask } from "./MessageKinds";

/** Settings ▸ Machines' section for this machine (#3979): Backups… and Processes… open it there. */
function openSettings(host: string, section: string) {
  chooseSettingsMachine(host);
  go({ nav: "settings" });
  setTimeout(() => document.getElementById(section)?.scrollIntoView({ block: "start" }), 0);
}

const swipeWords = { start: "Start", stop: "Stop", delete: "Delete", remove: "Remove" } as const;

/** A laptop, a cloud or a rack, as the window's SF Symbols, in its state's colour; amber pulses while it changes. */
function MachineIcon({ kind, tone }: { kind: MachineKind; tone: MachineIconTone }) {
  return (
    <svg class={`machine-icon ${tone}`} viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor"
      stroke-width="1.4" stroke-linejoin="round" stroke-linecap="round" aria-hidden="true">
      {kind === "mac" && <><rect x="3" y="3.5" width="10" height="7" rx="1" /><path d="M1.5 12.5h13" /></>}
      {kind === "cloud" && <path d="M4.5 12.5a3 3 0 0 1-.4-6 4 4 0 0 1 7.7-.9 3.5 3.5 0 0 1 .2 6.9z" />}
      {kind === "rack" && <><rect x="2.5" y="2.5" width="11" height="4.5" rx="1" /><rect x="2.5" y="9" width="11" height="4.5" rx="1" />
        <path d="M5 4.75h.01M5 11.25h.01" /></>}
    </svg>
  );
}

/** The state in words, for a screen reader, as the window's row says it: the icon's colour is never the only sign. */
const toneWords: Record<MachineIconTone, string> = {
  accent: "Online", busy: "Changing", failure: "Needs attention", attention: "Needs an update", stopped: "Stopped",
};

export function MachineRow({ store, host, on, open, children }: {
  store: Store; host: string; on: boolean; open: () => void; children: ComponentChildren;
}) {
  const row = store.hosts.value.find((h) => h.id === host);
  const dx = useSignal(0);
  const from = useRef<{ x: number; y: number; across: boolean } | null>(null);
  const swiped = useRef(false);
  // Update…, Choose Folders… or Link to Provider…, open from the menu (#4122).
  const sheet = useSignal<MachineSheet | null>(null);
  if (!row) return null;
  const mac = host === store.macHostID.value;
  const name = mac ? "This Mac" : row.name;
  const actions = machineActions(row, store.macHostID.value);
  const swipes = machineSwipes(actions);
  const sheets = machineSheets(row, store.macHostID.value, store.hostIsOnline(host));
  const dot = machineDot(row, store.hostIsOnline(host), store.hostsBeingStarted.value.includes(host));
  const diskLow = (store.disk.value[host]?.alarms ?? []).some((a) => a.level !== "ok");
  const tone = machineIcon(dot, diskLow);
  const stateWords = tone === "failure" && dot !== "offline" ? "A disk is low" : toneWords[tone];

  const stop = async () => {
    const asked = await store.providers.stop(host);
    if (typeof asked === "string") store.say(asked);
    else if (asked && await ask(`Stop ${row.name}? ${asked.question}`)) {
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
    delete: () => void store.deletePreview(host).then(async (preview) => {
      if (await ask(deleteQuestion(row, sessions(), preview))) void store.deleteHost(host);
    }),
    remove: async () => { if (await ask(removeQuestion(row))) void store.removeHost(host); },
  };
  const items = (): MenuItem[] => [
    { label: "Open", run: open },
    ...(actions.start ? [{ label: "Start", run: run.start }] : []),
    ...(actions.stop ? [{ label: "Stop", run: run.stop }] : []),
    // As Settings ▸ Machines has them (#3979).
    ...(mac ? [] : [
      { label: "Check Again", run: () => void store.checkAgain(host) },
      ...(sheets.update ? [{ label: "Update…", run: () => (sheet.value = "update") }] : []),
      ...(sheets.folders ? [{ label: "Choose Folders…", disabled: !sheets.foldersReady, run: () => (sheet.value = "folders") }] : []),
      { label: "Backups…", disabled: !store.hostIsOnline(host), run: () => openSettings(host, "settings-server-backups") },
      { label: "Processes…", disabled: !store.hostIsOnline(host), run: () => openSettings(host, "settings-processes") },
      ...(sheets.link ? [{ label: "Link to Provider…", run: () => (sheet.value = "link") }] : []),
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

  // The sheet is beside the row, not in it, so its pointer events are not the row's swipes and holds.
  return (
    <>
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
            <span class="machine-name"><MachineIcon kind={machineKind(row, store.macHostID.value)} tone={tone} />{name}
              <span class="visually-hidden">, {stateWords}</span></span>
          </button>
          {!mac && <button type="button" class="machine-more" aria-label={`More for ${name}`}
            onClick={(e) => openContextMenu(e, items())}>···</button>}
          {children}
        </div>
      </div>
      {sheet.value && <MachineSheetDialog store={store} host={row} sheet={sheet.value} close={() => (sheet.value = null)} />}
    </>
  );
}

/** A machine New Machine is making (#3974): an amber, pulsing cloud and `Making…` until it joins; red with the reason,
 * and Delete in its menu, once the control plane gave up waiting for it (#4610). */
export function MakingRow({ row, onDelete }: { row: MachineMaking; onDelete: () => void }) {
  const name = row.name || "New machine";
  const gaveUp = row.notJoined !== null;
  const items = (): MenuItem[] => [{ label: `Delete ${name}…`, run: onDelete }];
  return (
    <div class={`machine-row making${gaveUp ? " not-joined" : ""}`} role={gaveUp ? undefined : "status"}
      onContextMenu={gaveUp ? (e) => openContextMenu(e, items()) : undefined}>
      <span class="sub-app-row"><span class="machine-name"><MachineIcon kind="cloud" tone={gaveUp ? "failure" : "busy"} />{name}</span></span>
      {gaveUp && <button type="button" class="machine-more" aria-label={`More for ${name}`}
        onClick={(e) => openContextMenu(e, items())}>···</button>}
      <p class={`machine-need small ${gaveUp ? "failure" : "quiet"}`}>{row.notJoined ?? "Making…"}</p>
    </div>
  );
}
