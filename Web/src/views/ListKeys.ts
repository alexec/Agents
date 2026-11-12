// The session list's single keys on the web page (#4796; the keys and their rules are `model/listKeys.ts`'s):
// j and k through the session rows as the sidebar shows them, e archives the open session and opens the next,
// l puts the request it asked in Later, r renames it. Anywhere on the Sessions page, while no field, menu or
// dialog has the keys; Work has its own j and k, and the sidebar is not drawn there.
import { useEffect } from "preact/hooks";
import type { Agent, Request as PersonRequest } from "../protocol/generated";
import type { Store } from "../model/store";
import { folderPath } from "../model/groups";
import { route } from "../route";
import { afterArchiving, laterTime, listKeyOf, stepFrom, type ListKey } from "../model/listKeys";
import { archiveAndLeave, runSessionAction } from "./SessionMenu";

/** The request l puts in Later: the oldest the session asked that is not in Later already, as the window's. */
export function laterRequestOf(store: Store, host: string, agent: Agent): PersonRequest | undefined {
  return store.personRequestsIn(host, folderPath(agent)).filter((r) => r.askedBy === agent.id)
    .sort((a, b) => a.askedAt - b.askedAt)[0];
}

/** The rows the keys go through, in the order shown; a request's row stands for the session that asked it. */
function sessionRows(): HTMLElement[] {
  return [...document.querySelectorAll<HTMLElement>("nav.sidebar .scroll .nav-item .row.session")]
    .filter((el) => el.offsetParent !== null);
}

/** To a row as ↓ goes: the keys' focus on it, in sight, and open. */
function land(el: HTMLElement) {
  el.focus();
  el.scrollIntoView({ block: "nearest" });
  el.click();
}

const takesKeys = (target: EventTarget | null) => target instanceof Element
  && !!target.closest("input, textarea, select, [contenteditable=true], [role=menu], dialog");

/** Does the key; false when it has nothing to do it to, so the page keeps the key. */
function run(store: Store, key: ListKey): boolean {
  const rows = sessionRows();
  const current = rows.find((el) => el === document.activeElement) ?? rows.find((el) => el.classList.contains("chosen"));
  if (key === "next" || key === "previous") {
    const to = stepFrom(current, rows, key === "next");
    if (to) land(to);
    return rows.length > 0;
  }
  const r = route.peek();
  const host = r.host;
  const agent = host && r.session ? store.agent(host, r.session) : undefined;
  if (!host || !agent || agent.state === "archived" || store.onItsWay.peek()[agent.id]) return false;
  if (key === "archive") {
    // Its other rows (a request's, under Needs You) go with it, so the next is another session's.
    const next = current && afterArchiving(current, rows.filter((el) => el === current || !el.classList.contains("chosen")));
    if (!next) { archiveAndLeave(store, host, agent); return true; }
    land(next);
    runSessionAction(store, host, agent, "agents/archive");
  } else if (key === "rename") {
    // In its row, as a double-click renames it; in the chat's header when the sidebar does not show it.
    const inRow = rows.some((el) => el.classList.contains("chosen") && !el.classList.contains("approval"));
    runSessionAction(store, host, agent, "rename", !inRow);
  } else {
    const request = laterRequestOf(store, host, agent);
    if (!request) return false;
    void store.deferRequest(host, request.id, laterTime);
  }
  return true;
}

/** The keys, while the Sessions page's sidebar is drawn. */
export function useListKeys(store: Store) {
  useEffect(() => {
    let afterG = 0;
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      // g then a letter goes to a section (Nav): g then r is Reports, not Rename.
      if (e.key === "g") { afterG = Date.now(); return; }
      const followsG = Date.now() - afterG < 1500;
      afterG = 0;
      const key = listKeyOf(e, takesKeys(e.target) || !!document.querySelector("dialog[open]"));
      if (key && !followsG && run(store, key)) e.preventDefault();
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);
}
