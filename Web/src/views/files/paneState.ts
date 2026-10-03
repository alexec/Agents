// Where each session's files pane is: which tab, which folder, which file, which page. Kept per
// session in memory, as the window's SidebarState is, so going back to a chat finds its pane
// where it was.
import { signal } from "@preact/signals";

export type Tab = "files" | "changes" | "page";

export interface PaneState {
  tab: Tab;
  /** The folder listed, as an absolute path; nil for the session's own folder. */
  folder?: string | undefined;
  /** The file open under Files. */
  file?: string | undefined;
  /** The file last open, marked in its folder when Back comes to it (#66). */
  last?: string | undefined;
  /** The tree's open folders, by path (#133): kept while files are opened and closed. */
  expanded?: ReadonlySet<string> | undefined;
  /** The tree's row the keys are on. */
  cursor?: string | undefined;
  /** The live page, and the line the agent named. */
  page?: string | undefined;
  line?: number | undefined;
  /** The changed file open under Changes. */
  changed?: string | undefined;
}

export const panes = signal<Record<string, PaneState>>({});

export function paneOf(session: string): PaneState {
  return panes.value[session] ?? { tab: "files" };
}

export function setPane(session: string, change: Partial<PaneState>): void {
  panes.value = { ...panes.value, [session]: { ...paneOf(session), ...change } };
}

/** An absolute path from a file URL, as the host writes them. */
export function pathOf(url: string): string {
  try {
    return decodeURIComponent(new URL(url).pathname).replace(/\/+$/, "") || "/";
  } catch {
    return url;
  }
}

export function nameOf(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

export function extensionOf(path: string): string {
  const name = nameOf(path);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/**
 * How a file read as text is drawn (FR-031): SVG only as a picture made from its bytes, Markdown
 * through the renderer, HTML as its source, and anything else as monospace text. There is no
 * way here to draw a file as markup.
 */
export type TextShownAs = "picture" | "page" | "source" | "text";
export function textShownAs(path: string): TextShownAs {
  const ext = extensionOf(path);
  if (ext === "svg") return "picture";
  if (ext === "md" || ext === "markdown") return "page";
  if (ext === "html" || ext === "htm" || ext === "xhtml") return "source";
  return "text";
}
