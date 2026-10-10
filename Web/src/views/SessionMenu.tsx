// A session's actions (071 FR-027): Carry on while it sits in an open block (#250), Stop while it
// holds a runtime or a block, Park or Unpark
// (Agent.parkAction), Branch (#342), and Archive, or Bring Back and Delete (#398). In the chat
// header's ··· menu, and the sidebar row's menu. The chat's has Open File… first, as the Remote's
// ··· menu does (#543), for a page with no keyboard to press ⌘P on.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { isOpenBlock, projectFolder } from "../model/groups";
import { carryOnHelp, carryOnLabel, carryOnPrompt, openBlock } from "../model/block";
import { go } from "../route";

export type Action = "carryOn" | "agents/stop" | "agents/park" | "agents/unpark" | "agents/archive" | "agents/unarchive"
  | "markRead" | "markUnread" | "pin" | "unpin" | "fork" | "delete";

/**
 * What the menu offers, in order, with the window's words (ParkWords, AgentRow's menu). Given
 * whether it is pinned, Pin or Unpin too (#180).
 */
export function sessionActions(agent: Agent, pinned?: boolean): { action: Action; label: string; help: string }[] {
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
  if (agent.parking) {
    found.push({ action: "agents/unpark", label: "Unpark",
      help: "whenTurnEnds" in agent.parking ? "Don't park this chat when its turn ends" : "Put this chat back where it was" });
  } else if (agent.state !== "archived") {
    found.push({ action: "agents/park", label: "Park", help: "Put this chat down to come back to later" });
  }
  // The person's own mark (#70): leave something to come back to, or clear it without opening it.
  if (agent.state === "finished") {
    found.push(agent.isUnread === true
      ? { action: "markRead", label: "Mark as Read", help: "Clear the unread mark" }
      : { action: "markUnread", label: "Mark as Unread", help: "Leave this to come back to" });
  }
  // At the top of its project whatever its state, or back among the rest (#180).
  if (pinned !== undefined && agent.state !== "archived") {
    found.push(pinned
      ? { action: "unpin", label: "Unpin", help: "Put this session back among the others" }
      : { action: "pin", label: "Pin", help: "Keep this session at the top of its project, whatever its state" });
  }
  // Branching leaves the original alone and carries the history so far (#342), as the window's row.
  if (agent.state !== "archived") {
    found.push({ action: "fork", label: "Branch", help: "A new session that carries this one's history so far" });
  }
  if (agent.state === "archived") {
    found.push({ action: "agents/unarchive", label: "Bring Back", help: "Bring this session back from the archive" });
    found.push({ action: "delete", label: "Delete…", help: "Delete this session and its conversation for good" });
  } else {
    found.push({ action: "agents/archive", label: "Archive", help: "Archive this session" });
  }
  return found;
}

/**
 * Pin or Unpin, and Archive or Bring Back: the buttons in the chat's header beside its ···
 * menu (#586), as the window's toolbar has them. No Pin on an archived session.
 */
export function headerActions(agent: Agent, pinned: boolean): { action: Action; label: string; help: string }[] {
  if (agent.state === "archived") {
    return [{ action: "agents/unarchive", label: "Bring Back", help: "Bring this session back from the archive" }];
  }
  return [
    pinned
      ? { action: "unpin", label: "Unpin", help: "Take this session out of Pinned in the sidebar" }
      : { action: "pin", label: "Pin", help: "Keep this session in Pinned, at the top of the sidebar" },
    { action: "agents/archive", label: "Archive", help: "Archive this session and leave it" },
  ];
}

/** `headerActions` as buttons. Archive leaves the chat for its project, once the host has it. */
export function SessionButtons({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
  if (!agent) return null;
  const pinned = store.sessionPinsIn(host, projectFolder(agent)).includes(agent.id);
  return (
    <>
      {headerActions(agent, pinned).map(({ action, label, help }) => (
        <button key={action} title={help} disabled={disabled || !!store.onItsWay.value[agent.id]}
          onClick={() => {
            if (action !== "agents/archive") return runSessionAction(store, host, agent, action);
            void store.perform(host, agent.id, action).then((done) => { if (done) go({ host, project: projectFolder(agent) }); });
          }}>{label}</button>
      ))}
    </>
  );
}

export function SessionMenu({ store, host, agent, disabled, openFile }:
  { store: Store; host: string; agent: Agent | undefined; disabled: boolean; openFile?: () => void }) {
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
          {openFile && (
            <button role="menuitem" title="Find a file in this session's folder by name"
              onClick={() => {
                open.value = false;
                openFile();
              }}>Open File…</button>
          )}
          {sessionActions(agent, store.sessionPinsIn(host, projectFolder(agent)).includes(agent.id)).map(({ action, label, help }) => (
            <button key={action} role="menuitem" title={help}
              onClick={() => {
                open.value = false;
                runSessionAction(store, host, agent, action);
              }}>{label}</button>
          ))}
        </div>
      )}
    </span>
  );
}

/** One of `sessionActions`, done. */
export function runSessionAction(store: Store, host: string, agent: Agent, action: Action): void {
  if (action === "carryOn") void store.prompt(host, agent.id, carryOnPrompt, []);
  else if (action === "markRead" || action === "markUnread") void store.setUnread(host, agent.id, action === "markUnread");
  else if (action === "pin" || action === "unpin") void store.setPinned(host, projectFolder(agent), agent.id, action === "pin");
  else if (action === "fork") void branch(store, host, agent);
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
  if (await store.act("agents/delete", { agentID: agent.id }, host) !== null) go({ host, project: projectFolder(agent) });
}

/** Branch, then open the new session, as the window selects it (#342). */
async function branch(store: Store, host: string, agent: Agent) {
  const id = await store.fork(host, agent.id);
  if (id) go({ host, project: projectFolder(agent), session: id });
}
