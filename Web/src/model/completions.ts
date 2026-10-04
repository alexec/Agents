// What the prompt offers while a `/` command or an `@` file is being typed (#255): SlashCommand's
// and FileMention's rules (Model/SlashCommand.swift, Model/FileMention.swift), ported by hand and
// held to Fixtures/web/completions. The commands are the runtime's; the files are found by the
// host (`files/mention`), as the Remote asks the Mac.
import type { SlashCommand } from "../protocol/generated";

/** The word being typed after a `/` or an `@`: where it starts, and what follows the mark. */
export interface Typed {
  start: number;
  term: string;
}

/**
 * The word after the last `mark`, when the mark starts a word and nothing after it is a space:
 * a path in a sentence is not a command, and an email address is not a file.
 */
function word(text: string, mark: "/" | "@"): Typed | null {
  const at = text.lastIndexOf(mark);
  if (at < 0) return null;
  if (at > 0 && !/\s/u.test(text[at - 1]!)) return null;
  const term = text.slice(at + 1);
  if (/\s/u.test(term)) return null;
  return { start: at, term };
}

export function commandQuery(text: string): Typed | null {
  return word(text, "/");
}

export function mentionQuery(text: string): Typed | null {
  return word(text, "@");
}

/** What starts with the term before what merely contains it, as SlashCommand.matching. */
export function matchingCommands(term: string, commands: readonly SlashCommand[]): SlashCommand[] {
  if (!term) return [...commands];
  const needle = term.toLowerCase();
  const starts = commands.filter((c) => c.name.toLowerCase().startsWith(needle));
  const contains = commands.filter((c) => !c.name.toLowerCase().startsWith(needle) && c.name.toLowerCase().includes(needle));
  return [...starts, ...contains];
}

/** The text with the half-typed command replaced by this one. */
export function completeCommand(text: string, query: Typed, command: SlashCommand): string {
  return `${text.slice(0, query.start)}/${command.name} `;
}

/** The text with the half-typed mention replaced by the file's name. */
export function completeMention(text: string, query: Typed, name: string): string {
  return `${text.slice(0, query.start)}${name} `;
}

/** The file's name: the last part of its path. */
export function fileName(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

/** The host's path as the `file:` URL Attachment.file sends, so the agent reads it where it is. */
export function fileURL(path: string): string {
  return "file://" + path.split("/").map(encodeURIComponent).join("/");
}
