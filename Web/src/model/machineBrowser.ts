// The browser on the session's machine, which agents drive (#3528, spike #3527): what the Agent
// Browser tab says, where a click lands in the page, and what a key says to it. The window's
// AgentBrowserPane.swift and MachineBrowser.swift say the same.
import type { Agent, BrowserInputRequest, BrowserPageState } from "../protocol/generated";

export const words = {
  tab: "Agent Browser",
  stoppedTitle: "The browser isn't running",
  stopped: "When an agent opens a page on this machine, you see it here and can use it. To open one yourself, type an address above.",
  failedTitle: "The browser didn't start",
  failed: "Try the address again.",
  starting: "Starting the browser",
  loading: "Loading the page",
  noTabTitle: "This session's agent has not used the browser",
  noTab: "When it opens a page, you see it here and can use it. To open one yourself, type an address above.",
  using: "is using the browser",
  anotherSession: "Another session",
};

export interface Rect { x: number; y: number; width: number; height: number }

/** The rectangle a page of this size takes when drawn to fit the view, centred. */
export function fitted(page: { width: number; height: number }, view: { width: number; height: number }): Rect {
  if (page.width <= 0 || page.height <= 0 || view.width <= 0 || view.height <= 0) return { x: 0, y: 0, width: 0, height: 0 };
  const scale = Math.min(view.width / page.width, view.height / page.height);
  const width = page.width * scale;
  const height = page.height * scale;
  return { x: (view.width - width) / 2, y: (view.height - height) / 2, width, height };
}

/** Where in the page a point of the view is, in CSS pixels; null outside the page. */
export function pagePoint(point: { x: number; y: number }, view: { width: number; height: number },
  page: { width: number; height: number }): { x: number; y: number } | null {
  const fit = fitted(page, view);
  if (fit.width <= 0 || fit.height <= 0) return null;
  if (point.x < fit.x || point.y < fit.y || point.x > fit.x + fit.width || point.y > fit.y + fit.height) return null;
  return { x: ((point.x - fit.x) * page.width) / fit.width, y: ((point.y - fit.y) * page.height) / fit.height };
}

/** The modifier bits CDP takes: Alt 1, Control 2, Meta 4, Shift 8. */
export function modifiers(e: { altKey: boolean; ctrlKey: boolean; metaKey: boolean; shiftKey: boolean }): number {
  return (e.altKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.metaKey ? 4 : 0) | (e.shiftKey ? 8 : 0);
}

/** A key going down or up, as the page's own key events name it. Text only with a key that types. */
export function keyInput(e: { key: string; code: string; keyCode: number; altKey: boolean; ctrlKey: boolean;
  metaKey: boolean; shiftKey: boolean }, down: boolean): BrowserInputRequest {
  const mods = modifiers(e);
  const types = down && e.key.length === 1 && (mods & (2 | 4)) === 0;
  return {
    kind: "key", type: down ? "keyDown" : "keyUp", key: e.key, code: e.code,
    ...(e.keyCode ? { keyCode: e.keyCode } : {}), ...(types ? { text: e.key } : {}), modifiers: mods,
  };
}

/**
 * What a touch screen's keyboard typed into the pane's hidden field (#4088), as the page takes it:
 * text as text, a delete as Backspace, a new line as Enter. Nothing for what the page has no key for.
 */
export function touchTyped(inputType: string, data: string | null): BrowserInputRequest[] {
  const key = (name: string, keyCode: number, text?: string): BrowserInputRequest[] => [
    { kind: "key", type: "keyDown", key: name, code: name, keyCode, ...(text ? { text } : {}), modifiers: 0 },
    { kind: "key", type: "keyUp", key: name, code: name, keyCode, modifiers: 0 },
  ];
  switch (inputType) {
    case "insertText":
    case "insertReplacementText":
    case "insertFromPaste":
    case "insertFromDrop":
      return data ? [{ kind: "text", text: data }] : [];
    case "insertLineBreak":
    case "insertParagraph":
      return key("Enter", 13, "\r");
    case "deleteContentBackward":
      return key("Backspace", 8);
    case "deleteContentForward":
      return key("Delete", 46);
    default:
      return [];
  }
}

/** The state shown before the host has said one. */
export const stopped: BrowserPageState = { status: "stopped" };

/**
 * The session whose agent holds the browser (#3916), when it is not this one: its title, or
 * Another session. The Mac writes an id in capitals and Go in small letters.
 */
export function otherHolder(state: BrowserPageState, session: string): { id: string; title: string } | null {
  if (!state.holder || state.holder.toLowerCase() === session.toLowerCase()) return null;
  return { id: state.holder, title: state.holderTitle || words.anotherSession };
}

/**
 * The sessions whose agent began to use the browser since `seen` last saw them (#3916): their
 * browserUsedAt moved on. An agent seen for the first time is only recorded, so a page that loads
 * opens no pane. `seen` keeps each agent's last value, for the page's lifetime.
 */
export function browserUseMoved(seen: Map<string, number | undefined>, agents: Iterable<Agent>): string[] {
  const moved: string[] = [];
  for (const agent of agents) {
    const now = agent.browserUsedAt;
    const before = seen.get(agent.id);
    const known = seen.has(agent.id);
    seen.set(agent.id, now);
    if (known && now !== undefined && (before === undefined || now > before)) moved.push(agent.id);
  }
  return moved;
}
