// An issue's or a pull request's words, as the forge draws them. GitHub's Markdown is not the chat's:
// it hides HTML comments (every agent's comment starts with `<!-- agent -->`), it draws a few HTML
// tags (<details>, <summary>, <br>, <img>, <a>, <b>), and it keeps a single line break. Our renderers
// never draw HTML (FR-031), so these are turned into the Markdown that means the same, and any other
// tag stays text. ForgeMarkdown.swift does the same for the Mac window and the Remote.

const fenceOpen = /^ {0,3}(`{3,}|~{3,})/;
const codeSpan = /(`+)[\s\S]*?(?<!`)\1(?!`)/g;

/** The forge's Markdown as the Markdown our renderers draw the same. */
export function forgeMarkdown(source: string): string {
  const lines: string[] = [];
  let fence: string | null = null;
  let comment = false;
  for (const raw of source.replace(/\r\n?/g, "\n").split("\n")) {
    if (fence) {
      lines.push(raw);
      if (raw.trim().startsWith(fence) && raw.trim().replaceAll(fence[0]!, "") === "") fence = null;
      continue;
    }
    if (!comment) {
      const opened = fenceOpen.exec(raw);
      if (opened) {
        fence = opened[1]!;
        lines.push(raw);
        continue;
      }
    }
    const tableRow = /^\s*\|/.test(raw);
    let text = "";
    for (const segment of segments(raw)) {
      let words = segment.text;
      let code = segment.code;
      if (comment) {
        const end = words.indexOf("-->");
        if (end < 0) continue;
        words = words.slice(end + 3);
        code = false;
        comment = false;
      }
      if (code) {
        text += words;
        continue;
      }
      const cut = uncomment(words);
      text += tags(cut.text, tableRow);
      comment = cut.open;
    }
    // A line that was only a comment or a tag is gone, so it does not end the paragraph it was in.
    if (text.trim() === "" && raw.trim() !== "") continue;
    lines.push(...text.split("\n"));
  }
  return keepBreaks(lines).join("\n");
}

/** A line cut into its code spans and the words between them. */
function segments(line: string): { text: string; code: boolean }[] {
  const parts: { text: string; code: boolean }[] = [];
  let at = 0;
  for (const span of line.matchAll(codeSpan)) {
    parts.push({ text: line.slice(at, span.index), code: false }, { text: span[0], code: true });
    at = span.index + span[0].length;
  }
  parts.push({ text: line.slice(at), code: false });
  return parts;
}

/** Text with its comments taken out; `open` when one runs on past the end. */
function uncomment(text: string): { text: string; open: boolean } {
  let out = "";
  let at = 0;
  for (;;) {
    const start = text.indexOf("<!--", at);
    if (start < 0) return { text: out + text.slice(at), open: false };
    out += text.slice(at, start);
    const end = text.indexOf("-->", start + 4);
    if (end < 0) return { text: out, open: true };
    at = end + 3;
  }
}

const dropped = "details|p|div|span|sub|sup|u|ins|center|picture|source|small|big|font|tt|abbr|mark|cite|dfn|var|section|article|header|footer|figure|figcaption|nobr|a";

/** The HTML GitHub draws, as Markdown; any other tag is left as it was written, and is drawn as text. */
function tags(text: string, tableRow: boolean): string {
  if (!text.includes("<")) return text;
  return text
    .replace(/^\s*<h([1-6])(?:\s[^>]*)?>(.*?)<\/h\1>\s*$/i, (_, level: string, words: string) => `${"#".repeat(Number(level))} ${words.trim()}`)
    .replace(/^\s*<hr\s*\/?>\s*$/i, "---")
    .replace(/<br\s*\/?>/gi, tableRow ? " " : "  \n")
    .replace(/<img\b([^>]*)>/gi, (_, attrs: string) => {
      const src = attr(attrs, "src");
      return src ? `![${(attr(attrs, "alt") ?? "").replace(/[[\]]/g, "\\$&")}](<${src}>)` : "";
    })
    .replace(/<a\b([^>]*)>(.*?)<\/a>/gi, (_, attrs: string, words: string) => {
      const href = attr(attrs, "href");
      return href ? `[${words}](<${href}>)` : words;
    })
    .replace(/<summary(?:\s[^>]*)?>(.*?)<\/summary>/gi, (_, words: string) => (words.trim() ? `**${words.trim()}**` : ""))
    .replace(/<\/?summary(?:\s[^>]*)?>/gi, "")
    .replace(/<\/?(?:b|strong)>/gi, "**")
    .replace(/<\/?(?:i|em)>/gi, "*")
    .replace(/<\/?(?:s|del|strike)>/gi, "~~")
    .replace(/<\/?(?:code|kbd|samp)>/gi, "`")
    .replace(new RegExp(`</?(?:${dropped})(?:\\s[^>]*)?/?>`, "gi"), "");
}

/** An attribute's value, quoted or not. */
function attr(attrs: string, name: string): string | undefined {
  const found = new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(attrs);
  return found ? (found[1] ?? found[2] ?? found[3]) : undefined;
}

const notPlain = /^(?: {4}|\t)|^\s*(?:#{1,6}(?:\s|$)|>|\||[-+*](?:\s|$)|\d{1,9}[.)](?:\s|$)|`{3}|~{3}|<)/;
const underline = /^\s*\|?[\s|:=-]*[=-][\s|:=-]*$/;

/** A line of a paragraph followed by another ends in a hard break, as the forge draws it. */
function keepBreaks(lines: string[]): string[] {
  let fence: string | null = null;
  return lines.map((line, i) => {
    const opened = fenceOpen.exec(line);
    if (fence) {
      if (line.trim().startsWith(fence) && line.trim().replaceAll(fence[0]!, "") === "") fence = null;
      return line;
    }
    if (opened) {
      fence = opened[1]!;
      return line;
    }
    const next = lines[i + 1];
    if (next === undefined || !plain(line) || !plain(next) || underline.test(next)) return line;
    if (/(?: {2}|\\)$/.test(line)) return line;
    return line + "  ";
  });
}

function plain(line: string): boolean {
  return line.trim() !== "" && !notPlain.test(line);
}

/** A title's words and its code spans, the only Markdown a forge draws in a title. */
export function titleParts(title: string): { text: string; code: boolean }[] {
  const parts: { text: string; code: boolean }[] = [];
  let at = 0;
  for (const span of title.matchAll(codeSpan)) {
    if (span.index > at) parts.push({ text: title.slice(at, span.index), code: false });
    const inner = span[0].slice(span[1]!.length, -span[1]!.length);
    // A space at both ends is padding, as CommonMark says, so `` `a` `` can be written.
    const code = /^ .*\S.* $/.test(inner) ? inner.slice(1, -1) : inner;
    if (code !== "") parts.push({ text: code, code: true });
    at = span.index + span[0].length;
  }
  if (at < title.length) parts.push({ text: title.slice(at), code: false });
  return parts;
}
