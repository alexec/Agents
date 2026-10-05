// A file's text, a row to a line, numbered (FileLines, #258). Numbered because an agent
// that says "line 412" is naming something the reader has to be able to find.

/** Split on newlines, keeping a blank line at the end when the file has one. */
export function splitLines(text: string): string[] {
  return text.split("\n");
}

/** Said when an agent names a line past the part of the file that was read. */
export function linePastEnd(line: number | undefined, count: number): string | null {
  if (line === undefined || line <= count) return null;
  return `Line ${line} is past what is shown here.`;
}

/** What a screen reader hears for one row: "Line 12: …", or "Line 12, blank". */
export function lineLabel(number: number, content: string): string {
  return content.trim() === "" ? `Line ${number}, blank` : `Line ${number}: ${content}`;
}

/** The gutter widens once the numbers need four digits. A file shows its first 128 KB. */
export function gutterIsWide(count: number): boolean {
  return count >= 1_000;
}
