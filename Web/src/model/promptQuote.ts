// Quote in Prompt (#1553): PromptQuote (Model/PromptQuote.swift), ported by hand and held to
// Fixtures/web/prompt/quote.json.

/** `text` with `quote` added at its end as a Markdown quote and an empty line after it. Nothing to quote leaves it as it was. */
export function quoteInto(quote: string, text: string): string {
  const words = quote.trim();
  if (!words) return text;
  const quoted = words.split("\n").map((line) => (line.trim() === "" ? ">" : `> ${line}`)).join("\n");
  // An empty line before it, so it is not read as part of the line before.
  const before = text === "" || text.endsWith("\n\n") ? text : text.endsWith("\n") ? `${text}\n` : `${text}\n\n`;
  return `${before}${quoted}\n\n`;
}
