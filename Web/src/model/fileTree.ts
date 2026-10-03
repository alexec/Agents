// The Files pane as a tree (#133; the window's FilesPane.treeLines and FileTree, ported by hand):
// each open folder's entries under it one step in, read only when opened, a folder still being
// read saying so on a line of its own; the keys that move about it; and which rows are on screen.
import type { DirectoryEntry, DirectoryListing } from "../protocol/generated";

export type TreeLine =
  | { kind: "entry"; id: string; entry: DirectoryEntry; path: string; depth: number; parent: string }
  | { kind: "note"; id: string; words: string; depth: number; parent: string }
  | { kind: "problem"; id: string; folder: string; words: string; depth: number; parent: string };

/**
 * An entry's path, spelt as its folder is: the host may answer /private/tmp for a folder asked for
 * as /tmp, and the tree keys every row by the top's spelling, so reveal and Back find them.
 */
export function childPath(folder: string, entry: DirectoryEntry): string {
  return folder === "/" ? `/${entry.name}` : `${folder}/${entry.name}`;
}

const collator = new Intl.Collator("en", { numeric: true, sensitivity: "base" });

/** Folders first, then by name, as the window lists them. */
export function sorted(listing: DirectoryListing): DirectoryListing {
  const entries = [...listing.entries].sort((a, b) => Number(b.isDirectory) - Number(a.isDirectory) || collator.compare(a.name, b.name));
  return { ...listing, entries };
}

/** The tree, flattened top to bottom: what is on screen, folders the person shut left shut. */
export function flatten(root: string, listings: ReadonlyMap<string, DirectoryListing>, expanded: ReadonlySet<string>,
  problems: ReadonlyMap<string, string> = new Map()): TreeLine[] {
  const lines: TreeLine[] = [];
  const add = (folder: string, depth: number) => {
    const problem = problems.get(folder);
    if (problem !== undefined) {
      lines.push({ kind: "problem", id: `problem:${folder}`, folder, words: problem, depth, parent: folder });
      return;
    }
    const listing = listings.get(folder);
    if (!listing) {
      lines.push({ kind: "note", id: `reading:${folder}`, words: "Reading…", depth, parent: folder });
      return;
    }
    for (const entry of listing.entries) {
      const path = childPath(folder, entry);
      lines.push({ kind: "entry", id: path, entry, path, depth, parent: folder });
      if (entry.isDirectory && expanded.has(path)) add(path, depth + 1);
    }
    if (listing.omitted > 0) {
      lines.push({ kind: "note", id: `omitted:${folder}`, words: `${listing.omitted} more, not shown`, depth, parent: folder });
    }
    if (depth === 0 && listing.entries.length === 0) {
      lines.push({ kind: "note", id: `empty:${folder}`, words: "Nothing here.", depth, parent: folder });
    }
  };
  add(root, 0);
  return lines;
}

/** Every folder between the top and this one, opened: so a file deep in the tree is in view. */
export function reveal(root: string, folder: string, expanded: ReadonlySet<string>): Set<string> {
  const next = new Set(expanded);
  if (folder === root || !folder.startsWith(root + "/")) return next;
  let path = root;
  for (const part of folder.slice(root.length + 1).split("/").filter(Boolean)) {
    path += "/" + part;
    next.add(path);
  }
  return next;
}

/** The folders on screen: the top, and every open one whose parents are open and read. */
export function visibleFolders(root: string, expanded: ReadonlySet<string>, listings: ReadonlyMap<string, DirectoryListing>): string[] {
  const folders = [root];
  for (let i = 0; i < folders.length; i++) {
    for (const entry of listings.get(folders[i]!)?.entries ?? []) {
      const path = childPath(folders[i]!, entry);
      if (entry.isDirectory && expanded.has(path)) folders.push(path);
    }
  }
  return folders;
}

/** Folders on screen with nothing to show and no read on its way (FileTree.unread). */
export function unread(root: string, expanded: ReadonlySet<string>, listings: ReadonlyMap<string, DirectoryListing>,
  problems: ReadonlyMap<string, string>, reading: ReadonlySet<string>): string[] {
  return visibleFolders(root, expanded, listings).filter((f) => !listings.has(f) && !problems.has(f) && !reading.has(f));
}

/** What a key does in the tree. */
export type KeyAction =
  | { kind: "select"; id: string }
  | { kind: "expand"; path: string }
  | { kind: "collapse"; path: string }
  | { kind: "open"; line: TreeLine & { kind: "entry" } }
  | { kind: "none" };

/**
 * The keys of a tree (WAI-ARIA's tree view, as Finder's list does it): up and down move a row,
 * right opens a shut folder or steps into an open one, left shuts an open folder or steps out to
 * the one holding the row, Return opens a file or opens and shuts a folder, Home and End go to the
 * ends.
 */
export function keyAction(lines: readonly TreeLine[], current: string | undefined, key: string,
  expanded: ReadonlySet<string>, root: string): KeyAction {
  const rows = lines.filter((l): l is TreeLine & { kind: "entry" } => l.kind === "entry");
  if (!rows.length) return { kind: "none" };
  const at = rows.findIndex((l) => l.id === current);
  const line = at >= 0 ? rows[at]! : undefined;
  switch (key) {
    case "ArrowDown":
      return { kind: "select", id: rows[at < 0 ? 0 : Math.min(at + 1, rows.length - 1)]!.id };
    case "ArrowUp":
      return { kind: "select", id: rows[at < 0 ? 0 : Math.max(at - 1, 0)]!.id };
    case "Home":
      return { kind: "select", id: rows[0]!.id };
    case "End":
      return { kind: "select", id: rows[rows.length - 1]!.id };
    case "ArrowRight": {
      if (!line) return { kind: "select", id: rows[0]!.id };
      if (!line.entry.isDirectory) return { kind: "none" };
      if (!expanded.has(line.path)) return { kind: "expand", path: line.path };
      const first = rows[at + 1];
      return first && first.parent === line.path ? { kind: "select", id: first.id } : { kind: "none" };
    }
    case "ArrowLeft": {
      if (!line) return { kind: "select", id: rows[0]!.id };
      if (line.entry.isDirectory && expanded.has(line.path)) return { kind: "collapse", path: line.path };
      return line.parent !== root ? { kind: "select", id: line.parent } : { kind: "none" };
    }
    case "Enter":
      return line ? { kind: "open", line } : { kind: "none" };
    default:
      return { kind: "none" };
  }
}

/** The rows to draw for a scroll position: those in view, and a few either side. */
export function windowOf(count: number, rowHeight: number, scrollTop: number, viewport: number, overscan = 8): { start: number; end: number } {
  const start = Math.max(0, Math.floor(scrollTop / rowHeight) - overscan);
  const end = Math.min(count, Math.ceil((scrollTop + viewport) / rowHeight) + overscan);
  return { start, end: Math.max(start, end) };
}
