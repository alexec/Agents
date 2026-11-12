// The ⌘K command menu (#4788, spec `specs/4777-fast/spec.md`, "⌘K"), as the window's (#4787): a field over the
// page that finds any session, folder, issue or pull request, and any action, as it is typed, each with its
// shortcut. ↑ ↓ move, Return does it, Escape or a click outside closes it and changes nothing. ⌘K (Ctrl+K off a
// Mac) opens it from anywhere, in a field too. `/` stays the top bar's search; `g` and a letter still go to a section.
import { useEffect, useRef } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { go, route } from "../route";
import { adminOf } from "../model/console";
import { navTitle, sectionKeys, sectionsShown, type NavSection } from "../model/nav";
import { folderKey, folderPath } from "../model/groups";
import { canStop } from "../model/tree";
import { repoOf, shortRef } from "../model/work";
import { nodeName } from "../model/value";
import { allRows, fromList, loadList, workList } from "../model/workLists";
import {
  appleKeys, commandFound, commandKey, commandKindWord, commandMenuWords, isCommandMenuKey, type CommandItem,
} from "../model/commandMenu";
import { orderedFolders } from "./Sidebar";
import { archiveAndLeave, runSessionAction } from "./SessionMenu";

/** A key press as the page's own handlers take it, so an action does what its shortcut does. */
function press(key: string, apple: boolean) {
  document.dispatchEvent(new KeyboardEvent("keydown", { key, metaKey: apple, ctrlKey: !apple, bubbles: true, cancelable: true }));
}

/** The words of a section's `g` key: `G then S`. */
const goKey = (section: NavSection) => {
  const letter = Object.keys(sectionKeys).find((k) => sectionKeys[k] === section);
  return letter ? `G then ${letter.toUpperCase()}` : undefined;
};

type Run = () => void;

/** Each kind's mark at the row's start, as the window's symbol. */
const kindGlyph: Record<CommandItem["kind"], string> = { action: "⌘", session: "◍", folder: "▤", issue: "◉", pr: "⇄" };

/** The menu's items and what each does: the open folder's sessions, the actions that can be done now, the other
 * folders' sessions, the folders, then the issues and PRs the Work lists have read; the window's order. */
export function commandItems(store: Store, apple: boolean): { items: CommandItem[]; runs: Map<string, Run>; repos: string[] } {
  const r = route.peek();
  const runs = new Map<string, Run>();
  const folders = orderedFolders(store.hosts.value, store.folders.value, store.macHostID.value);
  const several = store.hosts.value.length > 1;
  const hereKey = r.host && r.folder ? `${r.host}|${folderKey(r.folder)}` : undefined;
  const keyOf = (f: (typeof folders)[number]) => `${f.host.id}|${folderKey(f.folder.folder.folder)}`;
  const sessions = (list: typeof folders): CommandItem[] => list.flatMap((f) => store.folderView(f.host.id, f.folder.folder.folder)
    .headings.flatMap((h) => h.agents).map((agent) => {
      const id = `session:${f.host.id}|${agent.id}`;
      runs.set(id, () => go({ host: f.host.id, folder: f.folder.folder.folder, session: agent.id }));
      return { id, kind: "session" as const, title: agent.title?.trim() || "New session",
        detail: several ? `${f.folder.name} · ${f.host.name}` : f.folder.name, keywords: ["Find Session"] };
    }));
  const actions: CommandItem[] = [];
  const add = (title: string, run: Run, shortcut?: string, keywords?: string[]) => {
    const id = `action:${title}`;
    runs.set(id, run);
    actions.push({ id, kind: "action", title, ...shortcut ? { shortcut } : {}, ...keywords ? { keywords } : {} });
  };
  const here = folders.find((f) => keyOf(f) === hereKey);
  if (here) add("New Session", () => go({ host: here.host.id, folder: here.folder.folder.folder, compose: true }));
  for (const f of folders) {
    if (f === here) continue;
    add(several ? `New Session in ${f.folder.name} · ${f.host.name}` : `New Session in ${f.folder.name}`,
      () => go({ host: f.host.id, folder: f.folder.folder.folder, compose: true }), undefined, ["start"]);
  }
  const agent: Agent | undefined = r.host && r.session ? store.agent(r.host, r.session) : undefined;
  if (r.host && agent) {
    const host = r.host;
    const busy = !!store.onItsWay.value[agent.id];
    const live = agent.state !== "archived";
    if (live && !busy) add("Archive Session", () => archiveAndLeave(store, host, agent));
    if (!live && !busy) add("Unarchive Session", () => runSessionAction(store, host, agent, "agents/unarchive"));
    if (canStop(agent) && !busy) add("Stop Session", () => runSessionAction(store, host, agent, "agents/stop"));
    if (live) add("Rename Session…", () => runSessionAction(store, host, agent, "rename", true));
    if (live) add("Branch Session", () => runSessionAction(store, host, agent, "fork"));
    const pinned = store.sessionPinsIn(host, folderPath(agent)).includes(agent.id);
    if (live) add(pinned ? "Unpin Session" : "Pin Session", () => runSessionAction(store, host, agent, pinned ? "unpin" : "pin"));
    if (store.has(host, Capability.agentsFind1)) add("Find in Chat", () => press("f", apple), commandKey("f", apple));
    add("Open File…", () => press("p", apple), commandKey("p", apple));
  }
  if (store.archiveUndo.value) add("Undo Archive", () => void store.undoArchive(), commandKey("z", apple));
  for (const s of sectionsShown(adminOf(store), "overview")) {
    add(s === "overview" ? "Overview" : `Go to ${navTitle[s]}`, () => go(s === "overview" ? {} : { nav: s }), goKey(s),
      s === "settings" ? ["preferences"] : undefined);
  }
  const folderItems = folders.map((f): CommandItem => {
    const id = `folder:${keyOf(f)}`;
    runs.set(id, () => go({ host: f.host.id, folder: f.folder.folder.folder }));
    return { id, kind: "folder", title: f.folder.name, ...several ? { detail: f.host.name } : {} };
  });
  const repos: string[] = [];
  const work = (kind: "issue" | "pr"): CommandItem[] => allRows(workList(kind)).map((row) => {
    const id = `${kind}:${row.node.ref}`;
    const repo = repoOf(row.node.ref);
    if (!repos.includes(repo)) repos.push(repo);
    return { id, kind, title: row.title, detail: nodeName({ kind: "", ref: repo }), ref: shortRef(row.node.ref) };
  });
  const issues = work("issue");
  const pulls = work("pr");
  const items = [...sessions(folders.filter((f) => keyOf(f) === hereKey)), ...actions,
    ...sessions(folders.filter((f) => keyOf(f) !== hereKey)), ...folderItems, ...issues, ...pulls];
  return { items, runs, repos };
}

/** What choosing an item does: its action, or open it. An issue or a PR opens its page, as from its list. */
function choose(item: CommandItem, runs: Map<string, Run>) {
  const run = runs.get(item.id);
  if (run) return run();
  const cut = item.id.indexOf(":");
  const kind = item.id.slice(0, cut);
  if (kind === "issue" || kind === "pr") {
    fromList.value = undefined;
    go({ nav: "work", section: kind, item: item.id.slice(cut + 1) });
  }
}

/** ⌘K, anywhere on the page: the menu, over it. */
export function CommandMenu({ store }: { store: Store }) {
  const open = useSignal(false);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.isComposing || !isCommandMenuKey(e)) return;
      e.preventDefault();
      open.value = !open.value;
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);
  useEffect(() => {
    if (!open.value) return;
    // The Work lists' issues and PRs, read once; a list read already is not read again.
    for (const kind of ["issue", "pr"] as const) void loadList(store, workList(kind)).catch(() => undefined);
  }, [open.value]);
  return open.value ? <CommandMenuSheet store={store} close={() => { open.value = false; }} /> : null;
}

function CommandMenuSheet({ store, close }: { store: Store; close: () => void }) {
  const words = useSignal("");
  const at = useSignal(0);
  const dialog = useRef<HTMLDialogElement>(null);
  const list = useRef<HTMLUListElement>(null);
  const apple = appleKeys();
  const { items, runs, repos } = commandItems(store, apple);
  const found = commandFound(items, words.value, repos);
  useEffect(() => {
    const d = dialog.current;
    if (d && !d.open) d.showModal();
    return () => d?.close();
  }, []);
  useEffect(() => {
    list.current?.querySelector(`[aria-selected="true"]`)?.scrollIntoView({ block: "nearest" });
  }, [at.value]);
  const pick = (item: CommandItem | undefined) => {
    if (!item) return;
    close();
    // After the sheet has gone, so a key an action presses reaches the page, not the sheet.
    requestAnimationFrame(() => choose(item, runs));
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "ArrowDown") { e.preventDefault(); at.value = Math.min(at.value + 1, found.length - 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); at.value = Math.max(at.value - 1, 0); }
    else if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); pick(found[at.value]); }
  };
  return (
    <dialog ref={dialog} class="command-menu" aria-label={commandMenuWords.label} onClose={close}
      // A click on the backdrop, outside the box, closes it, as a menu would.
      onMouseDown={(e) => { if (e.target === dialog.current) close(); }}>
      <div class="command-menu-box">
        <input type="text" autocomplete="off" spellcheck={false} autoFocus placeholder={commandMenuWords.prompt}
          aria-label={commandMenuWords.label} role="combobox" aria-expanded={found.length > 0} aria-controls="command-menu-found"
          aria-autocomplete="list" aria-activedescendant={found.length ? `command-${at.value}` : undefined} value={words.value}
          onInput={(e) => { words.value = (e.currentTarget as HTMLInputElement).value; at.value = 0; }} onKeyDown={onKey} />
        {found.length > 0 ? (
          <ul id="command-menu-found" ref={list} class="command-menu-found" role="listbox" aria-label="Found">
            {found.map((item, i) => (
              <li key={item.id} id={`command-${i}`} role="option" aria-selected={i === at.value} class={i === at.value ? "on" : undefined}
                aria-description={commandKindWord[item.kind]}
                onMouseMove={() => { if (at.value !== i) at.value = i; }}
                onMouseDown={(e) => { e.preventDefault(); pick(item); }}>
                <span class="command-kind" aria-hidden="true" title={commandKindWord[item.kind]}>{kindGlyph[item.kind]}</span>
                <span class="command-title">{item.title}</span>
                {item.ref && !item.title.endsWith(item.ref) && <span class="command-detail">{item.ref}</span>}
                {item.detail && <span class="command-detail">{item.detail}</span>}
                {item.shortcut && <kbd class="command-key" aria-label={commandMenuWords.shortcut(item.shortcut)}>{item.shortcut}</kbd>}
              </li>
            ))}
          </ul>
        ) : words.value.trim() ? <p class="command-menu-none">{commandMenuWords.nothing(words.value)}</p> : null}
      </div>
    </dialog>
  );
}
