// What an agent changed, as a tree (#63; Files/ChangeTree.swift and ChangeWords, ported by hand):
// folders first, a folder holding only one folder folded into one line as GitHub does, a total
// per folder; and the index the Files pane marks its rows from.
import type { ChangedFile, ChangeState } from "../protocol/generated";

export interface Totals { added: number; removed: number; files: number }

export type Node =
  | { kind: "folder"; name: string; key: string; children: Node[]; totals: Totals }
  | { kind: "file"; file: ChangedFile };

export interface Line { node: Node; depth: number }

const collator = new Intl.Collator("en", { numeric: true, sensitivity: "base" });
const byName = (a: string, b: string) => collator.compare(a, b);

function fileName(file: ChangedFile): string {
  return file.path.split("/").filter(Boolean).pop() ?? file.path;
}

/** The parts of the path a file is shown by: relative to the agent's folder where it can be. */
export function components(file: ChangedFile): string[] {
  const shown = file.relativePath ?? file.path;
  const parts = shown.split("/").filter(Boolean);
  if (shown.startsWith("/") && parts.length) parts[0] = "/" + parts[0];
  return parts;
}

function count(sum: Totals, file: ChangedFile): Totals {
  return { added: sum.added + (file.added ?? 0), removed: sum.removed + (file.removed ?? 0), files: sum.files + 1 };
}

export function totals(nodes: Node[]): Totals {
  return nodes.reduce<Totals>((sum, node) => node.kind === "folder"
    ? { added: sum.added + node.totals.added, removed: sum.removed + node.totals.removed, files: sum.files + node.totals.files }
    : count(sum, node.file), { added: 0, removed: 0, files: 0 });
}

interface Folder { folders: Map<string, Folder>; files: ChangedFile[] }

/** ChangeTree.build. */
export function build(files: readonly ChangedFile[]): Node[] {
  const top: Folder = { folders: new Map(), files: [] };
  for (const file of files) {
    const parts = components(file);
    let folder = top;
    for (const part of parts.slice(0, -1)) {
      let next = folder.folders.get(part);
      if (!next) folder.folders.set(part, (next = { folders: new Map(), files: [] }));
      folder = next;
    }
    folder.files.push(file);
  }
  const nodes = (folder: Folder, path: string): Node[] => {
    const folders = [...folder.folders.keys()].sort(byName).map((first): Node => {
      let name = first;
      let key = path ? `${path}/${first}` : first;
      let inner = folder.folders.get(first)!;
      // GitHub's fold: one folder and nothing else becomes part of this line.
      while (inner.files.length === 0 && inner.folders.size === 1) {
        const [only, next] = [...inner.folders][0]!;
        name += "/" + only;
        key += "/" + only;
        inner = next;
      }
      const children = nodes(inner, key);
      return { kind: "folder", name, key, children, totals: totals(children) };
    });
    const leaves = [...folder.files].sort((a, b) => byName(fileName(a), fileName(b)))
      .map((file): Node => ({ kind: "file", file }));
    return [...folders, ...leaves];
  };
  return nodes(top, "");
}

/** ChangeTree.lines: what is on screen, folders the person closed left shut. */
export function lines(nodes: Node[], collapsed: ReadonlySet<string>, depth = 0, into: Line[] = []): Line[] {
  for (const node of nodes) {
    into.push({ node, depth });
    if (node.kind === "folder" && !collapsed.has(node.key)) lines(node.children, collapsed, depth + 1, into);
  }
  return into;
}

/**
 * A path as the index keys it: macOS names /tmp, /var and /etc two ways, and a host's listing
 * says /private/tmp where its changes say /tmp.
 */
export function canonical(path: string): string {
  return path.replace(/^\/private(?=\/(?:tmp|var|etc)(?:\/|$))/, "");
}

/** ChangeTree.Index: a changed file by path, and each folder above one with its totals. Look up with `canonical`. */
export function index(files: readonly ChangedFile[]): { files: Map<string, ChangedFile>; folders: Map<string, Totals> } {
  const byPath = new Map<string, ChangedFile>();
  const folders = new Map<string, Totals>();
  for (const file of files) {
    const path = canonical(file.path);
    byPath.set(path, file);
    let folder = path.slice(0, path.lastIndexOf("/"));
    while (folder.length > 1) {
      folders.set(folder, count(folders.get(folder) ?? { added: 0, removed: 0, files: 0 }, file));
      folder = folder.slice(0, folder.lastIndexOf("/"));
    }
  }
  return { files: byPath, folders };
}

/** ChangeWords.status. */
export function statusWord(state: ChangeState): string {
  return { added: "added", modified: "changed", deleted: "deleted", renamed: "renamed", untracked: "untracked",
    binary: "changed, binary" }[state];
}

/** ChangeTint.symbol, as a glyph: a square saying what happened, coloured by `class`. */
export function statusGlyph(state: ChangeState): string {
  return { added: "⊞", modified: "⊡", binary: "⊡", deleted: "⊟", renamed: "⇥", untracked: "?" }[state];
}

/** ChangeWords.oldPath: where a renamed file was, relative where the new path is. */
export function oldPathOf(file: ChangedFile): string | undefined {
  const old = file.oldPath;
  if (!old) return undefined;
  const relative = file.relativePath;
  if (!relative || !file.path.endsWith(relative)) return old;
  const top = file.path.slice(0, file.path.length - relative.length);
  return old.startsWith(top) ? old.slice(top.length) : old;
}

/** ChangeWords.statusPhrase. */
export function statusPhrase(file: ChangedFile): string {
  if (file.state === "renamed") {
    const old = oldPathOf(file);
    return old ? `renamed from ${old}` : "renamed";
  }
  if (file.state === "untracked") return "untracked, not in git";
  return statusWord(file.state);
}
