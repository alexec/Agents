// A session's actions (071 FR-027): Stop while it holds a runtime or a block, Park or Unpark
// (Agent.parkAction), and Archive or Bring Back. In the chat header's ··· menu.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { isOpenBlock } from "../model/groups";

type Action = "agents/stop" | "agents/park" | "agents/unpark" | "agents/archive" | "agents/unarchive"
  | "markRead" | "markUnread";

/** What the menu offers, in order, with the window's words (ParkWords, AgentRow's menu). */
export function sessionActions(agent: Agent): { action: Action; label: string; help: string }[] {
  const found: { action: Action; label: string; help: string }[] = [];
  const holds = agent.state === "starting" || agent.state === "running" || agent.state === "waitingOnUser";
  if (holds || (agent.state === "finished" && isOpenBlock(agent.report))) {
    found.push({ action: "agents/stop", label: "Stop", help: "Stop this session's turn" });
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
  found.push(agent.state === "archived"
    ? { action: "agents/unarchive", label: "Bring Back", help: "Bring this session back from the archive" }
    : { action: "agents/archive", label: "Archive", help: "Archive this session" });
  return found;
}

export function SessionMenu({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
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
          {sessionActions(agent).map(({ action, label, help }) => (
            <button key={action} role="menuitem" title={help}
              onClick={() => {
                open.value = false;
                if (action === "markRead" || action === "markUnread") void store.setUnread(host, agent.id, action === "markUnread");
                else void store.perform(host, agent.id, action);
              }}>{label}</button>
          ))}
        </div>
      )}
    </span>
  );
}
