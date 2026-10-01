// Labels on a session and the search field's query: SessionLabelPolicy (Model/SessionLabel.swift)
// and SessionLabelQuery (Model/SessionLabelQuery.swift), ported by hand and held to
// Fixtures/web/labels (research R7).
import type { Agent } from "../protocol/generated";

export const maximumLabels = 5;
export const maximumLabelLength = 24;

/** Swift's whitespacesAndNewlines, near enough for typed text. */
function trim(value: string): string {
  return value.replace(/^[\s\u0085]+|[\s\u0085]+$/gu, "");
}

export function labelKey(value: string): string {
  return trim(value).toLowerCase();
}

/** A typed value as a label, or null when empty or too long. Counted in characters, as Swift does. */
export function cleaned(value: string): string | null {
  const result = trim(value);
  if (!result || [...new Intl.Segmenter().segment(result)].length > maximumLabelLength) return null;
  return result;
}

/** Everything before the last comma is finished labels; what follows is still being typed. */
export function splitTyped(text: string): { finished: string[]; remainder: string } {
  const pieces = text.split(",");
  const remainder = pieces.pop() ?? "";
  return { finished: pieces, remainder };
}

/** The typed values a session can take: cleaned, new, not repeated, and only as many as fit. */
export function accepted(typed: readonly string[], existing: readonly string[]): string[] {
  const seen = new Set(existing.map(labelKey));
  const result: string[] = [];
  for (const raw of typed) {
    if (existing.length + result.length >= maximumLabels) continue;
    const value = cleaned(raw);
    if (value === null || seen.has(labelKey(value))) continue;
    seen.add(labelKey(value));
    result.push(value);
  }
  return result;
}

export interface LabelQuery {
  label: string | null;
  text: string;
}

/** The search field's words: `label:x` or `label:"x y"` filters, the rest matches title and report. */
export function parseQuery(input: string): LabelQuery {
  const match = /(?:^|\s)label:(?:"([^"]*)"|(\S*))/i.exec(input);
  if (!match) return { label: null, text: trim(input) };
  const label = match[1] ?? match[2] ?? "";
  return { label, text: trim(input.slice(0, match.index) + input.slice(match.index + match[0].length)) };
}

function containsIgnoringCase(haystack: string, needle: string): boolean {
  return haystack.toLocaleLowerCase().includes(needle.toLocaleLowerCase());
}

export function queryMatches(query: LabelQuery, agent: Agent): boolean {
  if (query.label !== null) {
    const wanted = labelKey(query.label);
    if (!wanted || !(agent.labels ?? []).some((label) => labelKey(label.value) === wanted)) return false;
  }
  if (!query.text) return true;
  return [agent.title, agent.report?.message].some((value) => value !== undefined && containsIgnoringCase(value, query.text));
}
