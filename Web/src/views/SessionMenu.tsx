// A session's actions (071 FR-027): Carry on while it sits in an open block (#250), Stop while it
// holds a runtime or a block, Branch (#342), and Archive, with Keep Session while an agent asks to
// have it archived (#773), or Unarchive and Delete (#398). In the chat header's ··· menu, and the
// sidebar row's menu. The chat's has Find in Chat (#1677), Prompts… (#1658) and Open File… first, as the Remote's ···
// menu does (#543), for a page with no keyboard to press ⌘F or ⌘P on. Below 760 it has the header's Turns and Files too, so the
// header's right is the ··· alone, as on the iPhone (#981).
import { undoLine } from "../model/archiveWords";
import { hostNeedsUpdate } from "../model/capabilities";
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { asksToArchive, isOpenBlock, folderPath } from "../model/groups";
import { keepLabel } from "../model/archiveWords";
import { carryOnHelp, carryOnLabel, carryOnPrompt, openBlock } from "../model/block";
import { go, routeHash } from "../route";
import { canStop, liveDescendants } from "../model/tree";
import { isMuted, muteHelp, muteLabel, unmuteLabel } from "../model/mute";
import { Capability } from "../protocol/capabilities.generated";
import { setShowsThoughts, showsThoughts, thoughtsItem } from "../model/thoughts";

export type Action = "carryOn" | "agents/stop" | "stopAll" | "agents/archive" | "agents/unarchive"
  | "markRead" | "markUnread" | "mute" | "unmute" | "rename" | "pin" | "unpin" | "fork" | "delete" | "keep";

/**
 * What the menu offers, in order, with the window's words (AgentRow's menu). Given
 * whether it is pinned, Pin or Unpin too (#180); given the sessions it started, Stop All
 * while one of them can stop (#835).
 */
export function sessionActions(agent: Agent, pinned?: boolean, started: readonly Agent[] = [], canMute = false)
  : { action: Action; label: string; help: string }[] {
  const found: { action: Action; label: string; help: string }[] = [];
  const holds = agent.state === "starting" || agent.state === "running" || agent.state === "waitingOnUser";
  // First, as the window's row menu has it (AgentRow's contextMenu); the strip in the chat has it too.
  if (openBlock(agent)) found.push({ action: "carryOn", label: carryOnLabel, help: carryOnHelp(agent) });
  if (holds || (agent.state === "finished" && isOpenBlock(agent.report))) {
    found.push({ action: "agents/stop", label: "Stop", help: "Stop this session's turn" });
  } else if (agent.state === "queued") {
    // AgentsModel.canStop: Stop takes a queued helper off the queue (#362).
    found.push({ action: "agents/stop", label: "Stop", help: "Take this agent off the queue" });
  }
  // The sessions it started too (#835).
  if (agent.state !== "archived" && started.some(canStop)) {
    found.push({ action: "stopAll", label: "Stop All", help: "Stop this session and every session it started" });
  }
  // The person's own mark (#70): leave something to come back to, or clear it without opening it.
  if (agent.state === "finished") {
    found.push(agent.isUnread === true
      ? { action: "markRead", label: "Mark as Read", help: "Clear the unread mark" }
      : { action: "markUnread", label: "Mark as Unread", help: "Leave this to come back to" });
  }
  // No push, banner or Mac notification for it, and still in Needs You (#2003), on a host that can.
  if (canMute && agent.state !== "archived") {
    found.push(isMuted(agent)
      ? { action: "unmute", label: unmuteLabel, help: muteHelp(true) }
      : { action: "mute", label: muteLabel, help: muteHelp(false) });
  }
  // The person's title, which the runtime's no longer replaces (#751), edited where it is shown.
  if (agent.state !== "archived") {
    found.push({ action: "rename", label: "Rename…", help: "Give this session a title of your own" });
  }
  // At the top of its folder whatever its state, or back among the rest (#180).
  if (pinned !== undefined && agent.state !== "archived") {
    found.push(pinned
      ? { action: "unpin", label: "Unpin", help: "Put this session back among the others" }
      : { action: "pin", label: "Pin", help: "Keep this session at the top of its folder, whatever its state" });
  }
  // Branching leaves the original alone and carries the history so far (#342), as the window's row.
  if (agent.state !== "archived") {
    found.push({ action: "fork", label: "Branch", help: "A new session that carries this one's history so far" });
  }
  if (agent.state === "archived") {
    found.push({ action: "agents/unarchive", label: "Unarchive", help: "Unarchive this session" });
    found.push({ action: "delete", label: "Delete…", help: "Delete this session and its conversation for good" });
  } else {
    found.push({ action: "agents/archive", label: "Archive", help: started.length > 0
      ? "Archive this session and the sessions it started" : "Archive this session" });
    // An agent asked to have it archived (#584): the request denied, as Needs You's (#773).
    if (asksToArchive(agent)) {
      found.push({ action: "keep", label: keepLabel, help: "Take the request to archive it away, and leave the session where it is" });
    }
  }
  return found;
}

/**
 * Pin or Unpin, and Archive or Unarchive: the buttons in the chat's header beside its ···
 * menu (#586), as the window's toolbar has them. No Pin on an archived session.
 */
export function headerActions(agent: Agent, pinned: boolean): { action: Action; label: string; help: string }[] {
  if (agent.state === "archived") {
    return [{ action: "agents/unarchive", label: "Unarchive", help: "Unarchive this session" }];
  }
  return [
    pinned
      ? { action: "unpin", label: "Unpin", help: "Take this session out of Pinned in the sidebar" }
      : { action: "pin", label: "Pin", help: "Keep this session in Pinned, at the top of the sidebar" },
    { action: "agents/archive", label: "Archive", help: "Archive this session and leave it" },
  ];
}

/**
 * `headerActions` as buttons. Archive leaves the chat for its folder, once the host has it.
 * Below 760 they are left to the ···, as the iPhone has them, so the title keeps the room (#665).
 */
export function SessionButtons({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
  if (!agent) return null;
  const pinned = store.sessionPinsIn(host, folderPath(agent)).includes(agent.id);
  return (
    <>
      {headerActions(agent, pinned).map(({ action, label, help }) => (
        <button key={action} class="wide-only" title={help} disabled={disabled || !!store.onItsWay.value[agent.id]}
          onClick={() => {
            if (action !== "agents/archive") return runSessionAction(store, host, agent, action);
            archiveAndLeave(store, host, agent);
          }}>{label}</button>
      ))}
    </>
  );
}

/** Archive, then the session's folder with nothing chosen (#2090): the chat it was open in has nothing left to show. */
function archiveAndLeave(store: Store, host: string, agent: Agent) {
  void archiveWithChildren(store, host, agent).then((done) => { if (done) go({ host, folder: folderPath(agent) }); });
}

/** The live sessions this one started, at every level, as the host's list has them (#835). */
export function startedBy(store: Store, host: string, agent: Agent): Agent[] {
  return liveDescendants(store.agents.value[host] ?? [], agent.id);
}

/**
 * Archive, and the sessions it started with it (Alex, #835), named before it goes; one archived
 * meanwhile is left as it is.
 */
export async function archiveWithChildren(store: Store, host: string, agent: Agent): Promise<boolean> {
  const started = startedBy(store, host, agent);
  const children = started.map((a) => a.id);
  const stops = [agent, ...started].some((a) => a.state === "running" || a.state === "starting" || a.state === "waitingOnUser");
  const done = await store.perform(host, agent.id, "agents/archive");
  if (!done) return false;
  const put = [agent.id];
  for (const id of children) {
    if (store.agent(host, id)?.state !== "archived" && await store.perform(host, id, "agents/archive")) put.push(id);
  }
  // Undo for a few seconds, at the foot of the list (#1534).
  store.archiveUndo.value = { key: Date.now(), host, agentIDs: put, line: undoLine(agent.title, stops) };
  return true;
}

/** Stop it and every session it started that can stop (#835). */
async function stopAll(store: Store, host: string, agent: Agent) {
  for (const one of [agent, ...startedBy(store, host, agent)]) {
    if (canStop(one)) await store.perform(host, one.id, "agents/stop");
  }
}

/** `inChat`: the chat header's, whose Archive leaves the chat as the header's button does. */
/** One of the chat header's own controls, in the ··· menu only below 760 (#981). */
export type NarrowItem = { label: string; help?: string; checked: boolean; run: () => void };

/**
 * Find in Chat in the chat's menu (#1867): on a host too old to find (#1748) it stays,
 * greyed, with the update help, as on the Mac and the Remote (`ChatFindItem`). ⌘F is left
 * to the browser there.
 */
export function findInChatItem(hostFinds: boolean): { disabled: boolean; title: string } {
  return hostFinds
    ? { disabled: false, title: "Find words in this chat's prompts and replies" }
    : { disabled: true, title: hostNeedsUpdate };
}

export function SessionMenu({ store, host, agent, disabled, find, findsOnHost = true, prompts, openFile, inChat, narrow = [] }:
  { store: Store; host: string; agent: Agent | undefined; disabled: boolean; find?: (() => void) | undefined; findsOnHost?: boolean; prompts?: () => void; openFile?: () => void; inChat?: boolean; narrow?: NarrowItem[] }) {
  const open = useSignal(false);
  const anchor = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open.value) return;
    const close = (e: Event) => { if (!anchor.current?.contains(e.target as Node)) open.value = false; };
    const escape = (e: KeyboardEvent) => { if (e.key === "Escape") open.value = false; };
    addEventListener("pointerdown", close);
    addEventListener("keydown", escape);
    return () => { removeEventListener("pointerdown", close); removeEventListener("keydown", escape); };
  }, [open.value]);
  return (
    <span class="menu-anchor session-menu" ref={anchor}>
      <button class="icon" aria-label="More" title="More" aria-haspopup="menu" aria-expanded={open.value}
        disabled={!agent || disabled || (agent && !!store.onItsWay.value[agent.id])} onClick={() => (open.value = !open.value)}>···</button>
      {open.value && agent && (
        <div class="popover right" role="menu">
          {narrow.map(({ label, help, checked, run }) => (
            <button key={label} class="narrow-only" role="menuitemcheckbox" aria-checked={checked} title={help}
              onClick={() => {
                open.value = false;
                run();
              }}>{label}</button>
          ))}
          {narrow.length > 0 && <hr class="narrow-only" />}
          {find && (
            <button role="menuitem" {...findInChatItem(findsOnHost)}
              onClick={() => {
                open.value = false;
                find();
              }}>Find in Chat</button>
          )}
          {prompts && (
            <button role="menuitem" title="See each prompt you sent in this chat, and go to one"
              onClick={() => {
                open.value = false;
                prompts();
              }}>Prompts…</button>
          )}
          {openFile && (
            <button role="menuitem" title="Find a file in this session's folder by name"
              onClick={() => {
                open.value = false;
                openFile();
              }}>Open File…</button>
          )}
          {inChat && (
            // Next to the chat, not in Settings (#2383), as View ▸ Show Thoughts on the Mac.
            <button role="menuitem" title={thoughtsItem(showsThoughts.value).title}
              onClick={() => {
                open.value = false;
                setShowsThoughts(!showsThoughts.value);
              }}>{thoughtsItem(showsThoughts.value).label}</button>
          )}
          {sessionActions(agent, store.sessionPinsIn(host, folderPath(agent)).includes(agent.id), startedBy(store, host, agent),
            store.has(host, Capability.mute1)).map(({ action, label, help }) => (
            <button key={action} role="menuitem" title={help}
              onClick={() => {
                open.value = false;
                if (inChat && action === "agents/archive") archiveAndLeave(store, host, agent);
                else runSessionAction(store, host, agent, action, inChat);
              }}>{label}</button>
          ))}
        </div>
      )}
    </span>
  );
}

/**
 * The address of this page open on one session (#826): what Open in New Tab opens, so a session
 * can sit in a tab or a window of its own beside this one, as the Mac's Open in New Window.
 */
export function sessionTabURL(host: string, agent: Agent, page: { pathname: string; search: string } = location): string {
  return page.pathname + page.search + routeHash({ host, folder: folderPath(agent), session: agent.id });
}

/** Open in New Tab (#826), from the sidebar row's menu. */
export function openInNewTab(host: string, agent: Agent): void {
  window.open(sessionTabURL(host, agent), "_blank", "noopener");
}

/** One of `sessionActions`, done. Rename edits the title where the menu was: the chat's header, or the row. */
export function runSessionAction(store: Store, host: string, agent: Agent, action: Action, inChat = false): void {
  if (action === "rename") store.renaming.value = { id: agent.id, inChat };
  else if (action === "carryOn") void store.prompt(host, agent.id, carryOnPrompt, []);
  else if (action === "markRead" || action === "markUnread") void store.setUnread(host, agent.id, action === "markUnread");
  else if (action === "mute" || action === "unmute") void store.setMuted(host, agent.id, action === "mute");
  else if (action === "pin" || action === "unpin") void store.setPinned(host, folderPath(agent), agent.id, action === "pin");
  else if (action === "fork") void branch(store, host, agent);
  else if (action === "keep") void store.keepSession(host, agent);
  else if (action === "agents/archive") void archiveWithChildren(store, host, agent);
  else if (action === "stopAll") void stopAll(store, host, agent);
  else if (action === "delete") { if (confirm(`${deleteTitle(agent.title)}\n\n${deleteMessage}`)) void remove(store, host, agent); }
  else void store.perform(host, agent.id, action);
}

/** DeletionWords.confirmTitle: "Delete “Fix the build”?". */
export function deleteTitle(title: string | null | undefined): string {
  const trimmed = title?.trim();
  return trimmed ? `Delete \u201C${trimmed}\u201D?` : "Delete this session?";
}

/** DeletionWords.confirmMessage. */
export const deleteMessage = "Its conversation and record are removed. This cannot be undone.";

/** Delete, asked first (#398); the host's agent/removed takes it out of every list. */
async function remove(store: Store, host: string, agent: Agent) {
  if (await store.act("agents/delete", { agentID: agent.id }, host) !== null) go({ host, folder: folderPath(agent) });
}

/** Branch, then open the new session, as the window selects it (#342). */
async function branch(store: Store, host: string, agent: Agent) {
  const id = await store.fork(host, agent.id);
  if (id) go({ host, folder: folderPath(agent), session: id });
}

/**
 * Branch from Here (#1658), then open the new session, as Branch does, with the prompt in its
 * prompt bar to change and send.
 */
export async function branchFromPrompt(store: Store, host: string, agent: Agent, entryID: string, text: string): Promise<void> {
  const id = await store.branchFrom(host, agent.id, entryID, text);
  if (id) go({ host, folder: folderPath(agent), session: id });
}

/**
 * The title as a field, in place of the text (#751): Enter keeps it, Escape or leaving it puts
 * it back. Emptied, the runtime names the session again.
 */
export function RenameInput({ store, host, agent }: { store: Store; host: string; agent: Agent }) {
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => { field.current?.focus(); field.current?.select(); }, []);
  const done = () => { store.renaming.value = null; };
  return (
    <input ref={field} class="rename" aria-label="Title" defaultValue={agent.title ?? ""}
      placeholder={(agent.titleIsPersons ? agent.runtimeTitle : agent.title) ?? "Untitled"}
      title="Enter renames it; an empty title gives the runtime's back. Escape cancels."
      onClick={(e) => e.stopPropagation()}
      onBlur={done}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Escape") { e.preventDefault(); done(); }
        if (e.key !== "Enter") return;
        e.preventDefault();
        const title = e.currentTarget.value;
        done();
        if (cleanedTitle(title) !== (agent.title ?? null)) void store.rename(host, agent.id, title);
      }} />
  );
}

/** Agent.cleanedTitle: one line, spaces collapsed, 80 at most; null when nothing is left. */
export function cleanedTitle(raw: string): string | null {
  const line = raw.split(/\s+/).filter(Boolean).join(" ");
  if (!line) return null;
  return [...line].length > 80 ? [...line].slice(0, 79).join("") + "\u2026" : line;
}
