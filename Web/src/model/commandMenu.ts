// The ⌘K command menu (#4788, spec `specs/4777-fast/spec.md`, "⌘K"), as the window's CommandFinder (#4787):
// one field that finds any session, folder, issue or pull request, by its words or by its ref (`#4777`),
// and any action, each with its shortcut. The page gives the items; this finds and orders them, with the
// window's rules, so each client finds the same items in the same order. It makes no call.
import { nodeName } from "./value";

/** What an item is, which the row says; on a tie the earlier kind comes first. */
export type CommandKind = "action" | "session" | "folder" | "issue" | "pr";
const kindOrder: readonly CommandKind[] = ["action", "session", "folder", "issue", "pr"];

export const commandKindWord: Record<CommandKind, string> = {
  action: "Action", session: "Session", folder: "Folder", issue: "Issue", pr: "Pull request",
};

export interface CommandItem {
  /** Unique in one menu: `session:<host>|<id>`, `folder:<host>|<folder>`, `issue:<ref>`, `action:<name>`. */
  id: string;
  kind: CommandKind;
  title: string;
  /** The grey words after the title: a session's folder, an issue's repo. */
  detail?: string;
  /** The ref's short form (`#4777`), matched as typed. */
  ref?: string;
  /** The shortcut as the page says it (`⌘F`, `G then S`); none when it has none. */
  shortcut?: string;
  /** Other words that find it, not shown ("Find Session" for the sessions). */
  keywords?: readonly string[];
}

/** What the menu says, the window's CommandMenuWords. */
export const commandMenuWords = {
  prompt: "Find a session, folder, issue or action",
  label: "Command menu",
  nothing: (term: string) => `Nothing matches “${term.trim()}”.`,
  shortcut: (keys: string) => `Shortcut ${keys}`,
};

/** The most rows the menu shows: it is for finding one thing, not for reading a list. */
export const commandShown = 50;

const wordsOf = (text: string) => text.toLowerCase().split(/\s+/).filter(Boolean);

/** A word and the parts after its punctuation, so `sign-in` starts at `in` too and `alexec/agents#12` at `agents` and `12`. */
function wordStarts(word: string): string[] {
  const starts = [word];
  let rest = word;
  for (let cut = rest.search(/[^\p{L}\p{N}]/u); cut >= 0; cut = rest.search(/[^\p{L}\p{N}]/u)) {
    rest = rest.slice(cut + 1);
    if (rest) starts.push(rest);
  }
  return starts;
}

/** Higher is better; undefined when a word is not in the item. */
function score(item: CommandItem, words: string[], whole: string): number | undefined {
  const title = item.title.toLowerCase();
  const ref = (item.ref ?? "").toLowerCase();
  // A ref typed as the item has it, with or without its `#`.
  if (ref && (whole === ref || `#${whole}` === ref || `p${ref}` === whole)) return 1000;
  const haystack = [title, (item.detail ?? "").toLowerCase(), ref, ...(item.keywords ?? []).map((k) => k.toLowerCase())].join(" ");
  const starts = wordsOf(haystack).flatMap(wordStarts);
  let allStart = true;
  for (const word of words) {
    if (!haystack.includes(word)) return undefined;
    if (!starts.some((s) => s.startsWith(word))) allStart = false;
  }
  if (title.startsWith(whole)) return title === whole ? 900 : 800;
  if (allStart) return wordsOf(title).some((w) => w.startsWith(words[0]!)) ? 600 : 500;
  return 100;
}

/**
 * The items that match `query`, the best first, at most `limit`. With no words, the items in the order given,
 * which is the page's: what is near the person first. Every word typed must be in the item (its title, detail,
 * ref or keywords). A title that starts with the query comes first; then one where each word starts a word;
 * then the rest. Ties keep the kinds' order, then the order given.
 */
export function commandMatches(items: readonly CommandItem[], query: string, limit = commandShown): CommandItem[] {
  const words = wordsOf(query);
  if (words.length === 0) return items.slice(0, limit);
  const whole = words.join(" ");
  const scored: { s: number; at: number; item: CommandItem }[] = [];
  items.forEach((item, at) => {
    const s = score(item, words, whole);
    if (s !== undefined) scored.push({ s, at, item });
  });
  scored.sort((a, b) => b.s - a.s || kindOrder.indexOf(a.item.kind) - kindOrder.indexOf(b.item.kind) || a.at - b.at);
  return scored.slice(0, limit).map((x) => x.item);
}

/** A ref typed alone, `#4777`, `4777`, `!12` or `P#12`: its number and whether it says a pull request; undefined for anything else. */
export function typedRef(query: string): { number: number; pr?: boolean } | undefined {
  let text = query.trim();
  let pr: boolean | undefined;
  if (/^p#/i.test(text)) { pr = true; text = text.slice(1); }
  if (text.startsWith("!")) { pr = true; text = text.slice(1); } else if (text.startsWith("#")) text = text.slice(1);
  if (!/^\d{1,9}$/.test(text) || Number(text) <= 0) return undefined;
  return pr === undefined ? { number: Number(text) } : { number: Number(text), pr };
}

/**
 * For a ref typed alone that no item has: an item for it in each repo the menu knows (`github:alexec/Agents`),
 * an issue and a pull request unless the ref says which, so `#4777` opens without its list read first.
 */
export function refItems(query: string, repos: readonly string[], known: readonly CommandItem[]): CommandItem[] {
  const typed = typedRef(query);
  if (!typed) return [];
  const have = new Set(known.filter((k) => k.kind === "issue" || k.kind === "pr").map((k) => k.id));
  const kinds: ("issue" | "pr")[] = typed.pr === true ? ["pr"] : typed.pr === false ? ["issue"] : ["issue", "pr"];
  const made: CommandItem[] = [];
  for (const repo of repos) {
    const separator = repo.startsWith("gitlab:") ? "!" : "#";
    for (const kind of kinds) {
      const id = `${kind}:${repo}${kind === "pr" ? separator : "#"}${typed.number}`;
      if (have.has(id)) continue;
      made.push({ id, kind, title: `Open ${commandKindWord[kind].toLowerCase()} #${typed.number}`,
        detail: nodeName({ kind: "", ref: repo }), ref: `#${typed.number}` });
    }
  }
  return made;
}

/** What the menu finds for the words: the matches, then a ref typed that no item has. */
export function commandFound(items: readonly CommandItem[], query: string, repos: readonly string[]): CommandItem[] {
  const matched = commandMatches(items, query);
  return [...matched, ...refItems(query, repos, matched)];
}

/** Whether the keys are ⌘K (Ctrl+K off a Mac), with no other modifier. */
export const isCommandMenuKey = (e: { key: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean }) =>
  e.key.toLowerCase() === "k" && (e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey;

/** A key with the command modifier, as this computer says it: `⌘F` on a Mac, `Ctrl+F` elsewhere. */
export function commandKey(key: string, apple: boolean): string {
  return apple ? `⌘${key.toUpperCase()}` : `Ctrl+${key.toUpperCase()}`;
}

/** Whether the page runs on an Apple computer, phone or tablet, whose keys say ⌘. */
export const appleKeys = () => typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
