// The browser on the session's machine, which agents drive (#3528, spike #3527): what the Agent
// Browser tab says, where a click lands in the page, and what a key says to it. The window's
// AgentBrowserPane.swift and MachineBrowser.swift say the same.
import type { BrowserInputRequest, BrowserState } from "../protocol/generated";

export const words = {
  tab: "Agent Browser",
  stoppedTitle: "The browser isn't running",
  stopped: "When an agent opens a page on this machine, you see it here and can use it. To open one yourself, type an address above.",
  failedTitle: "The browser didn't start",
  failed: "Try the address again.",
  starting: "Starting the browser",
  loading: "Loading the page",
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

/** The state shown before the host has said one. */
export const stopped: BrowserState = { status: "stopped" };
