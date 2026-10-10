// What an agent wrote, drawn as Markdown and never as HTML (071 FR-031, research R9).
//
// markdown-it parses with `html: false`, so raw HTML in a message arrives as text. Its tokens are
// turned into Preact nodes here, never into an HTML string, so nothing an agent says can reach an
// HTML sink. An image in a chat, or any image that is not a file beside a Markdown page, becomes
// a placeholder naming it: the page loads nothing from anywhere but itself (the CSP says so too).
// A picture beside a page is drawn from bytes `files/read` returns. A link opens in a new tab,
// and only http, https and mailto links are links at all. A file: link is a link only where the
// page says how a file opens (a chat opens it in Files, #548), and then it never navigates.
import MarkdownIt, { type Token } from "markdown-it";
import { pageImagePath } from "../model/pageImage";
import { LocalPicture } from "./LocalPicture";
import { memo } from "./memo";
import { highlightCode } from "./codeHighlight";
import { Fragment, h, type ComponentChildren } from "preact";

/** A Markdown page's pictures: read from beside the document, never from an address. */
export interface PageImages {
  document: string;
  /** Bumped when the folder changes, so a picture is read again. */
  revision: number;
  read: (path: string) => Promise<{ bytes: Uint8Array; type: string } | null>;
}

const parser = new MarkdownIt({ html: false, linkify: true, typographer: false, breaks: false });
// markdown-it drops a file: link to its bare text; it is kept as a link token so `build` can
// decide, and `build` follows it only through `openFile`, never as an address.
const validateLink = parser.validateLink.bind(parser);
parser.validateLink = (url) => validateLink(url) || fileLinkPath(url) !== null;

/** Opens a file on the agent's host by its full path: the chat's Files pane. */
export type OpenFile = (location: { path: string }) => void;

/** The full path a file: link names on its host, or null for any other link. */
export function fileLinkPath(href: string): string | null {
  try {
    const url = new URL(href);
    if (url.protocol !== "file:" || (url.host !== "" && url.host !== "localhost")) return null;
    const path = decodeURIComponent(url.pathname);
    return path.startsWith("/") ? path : null;
  } catch {
    return null;
  }
}

/** Whether a link may be followed from the page. */
export function isSafeLink(href: string): boolean {
  try {
    const url = new URL(href);
    return url.protocol === "http:" || url.protocol === "https:" || url.protocol === "mailto:";
  } catch {
    return false;
  }
}

const blockTags: Record<string, string> = {
  paragraph: "p", bullet_list: "ul", ordered_list: "ol", list_item: "li", blockquote: "blockquote",
  table: "table", thead: "thead", tbody: "tbody", tr: "tr", th: "th", td: "td",
  strong: "strong", em: "em", s: "s",
};

interface Frame {
  tag: string;
  props: Record<string, unknown>;
  children: ComponentChildren[];
}

/** Builds nodes from a flat token list with nesting, as markdown-it hands them over. */
function build(tokens: readonly Token[], images?: PageImages, openFile?: OpenFile): ComponentChildren[] {
  const root: Frame = { tag: "", props: {}, children: [] };
  const stack: Frame[] = [root];
  const top = () => stack[stack.length - 1]!;
  const push = (node: ComponentChildren) => top().children.push(node);

  for (const token of tokens) {
    if (token.nesting === 1) {
      const name = token.type.replace(/_open$/, "");
      let tag = blockTags[name] ?? (name === "heading" ? token.tag : name === "link" ? "a" : "span");
      const props: Record<string, unknown> = {};
      if (name === "link") {
        const href = String(token.attrGet("href") ?? "");
        const path = openFile ? fileLinkPath(href) : null;
        if (isSafeLink(href)) {
          Object.assign(props, { href, target: "_blank", rel: "noopener noreferrer" });
        } else if (path && openFile) {
          tag = "button";
          Object.assign(props, { type: "button", class: "link reading", title: path, onClick: () => openFile({ path }) });
        } else {
          tag = "span";
        }
      }
      if (name === "ordered_list") {
        // No attribute is a list from 1; Number(null) would make it 0.
        const written = token.attrGet("start");
        const start = written === null ? 1 : Number(written);
        if (Number.isInteger(start) && start !== 1) props["start"] = start;
      }
      // A list item's paragraphs are tight in a tight list: markdown-it marks them hidden.
      if (name === "paragraph" && token.hidden) tag = "";
      stack.push({ tag, props, children: [] });
      continue;
    }
    if (token.nesting === -1) {
      const frame = stack.pop()!;
      if (frame.tag === "") top().children.push(...frame.children);
      else push(h(frame.tag, frame.props, ...frame.children));
      continue;
    }
    switch (token.type) {
      case "inline": {
        // A task list item (`- [ ]`, `- [x]`): a box drawn and never ticked, as MarkdownText's (#252).
        const item = stack[stack.length - 2];
        const first = token.children?.[0];
        const box = item?.tag === "li" && item.children.length === 0 && top().children.length === 0
          && first?.type === "text" ? /^\[([ xX])\]\s+/.exec(first.content) : null;
        if (box && first) {
          const done = box[1] !== " ";
          first.content = first.content.slice(box[0].length);
          item!.props["class"] = "task";
          push(h("span", { class: `task-box${done ? " done" : ""}`, role: "img", "aria-label": done ? "Done" : "Not done" },
            done ? "☑" : "☐"));
          push(" ");
        }
        top().children.push(...build(token.children ?? [], images, openFile));
        break;
      }
      case "text":
        push(token.content);
        break;
      case "softbreak":
        push("\n");
        break;
      case "hardbreak":
        push(h("br", null));
        break;
      case "code_inline":
        push(h("code", null, token.content));
        break;
      case "code_block":
      case "fence": {
        const language = token.info.trim().split(/\s+/)[0];
        push(h("pre", language ? { "data-language": language } : null,
          h("code", null, language ? highlightCode(token.content, language) : token.content)));
        break;
      }
      case "hr":
        push(h("hr", null));
        break;
      case "image": {
        const alt = token.children?.map((child) => child.content).join("") || String(token.attrGet("alt") ?? "");
        const src = String(token.attrGet("src") ?? "");
        // Beside the document, and only there. A chat has no document, so every image stays
        // a placeholder, and a remote one does even on a page (FR-031).
        const path = images ? pageImagePath(src, images.document) : null;
        if (path && images) {
          push(h(LocalPicture, { path, alt, revision: images.revision, read: images.read }));
        } else {
          push(h("span", { class: "image-placeholder", title: src }, alt ? `[image: ${alt}]` : "[image]"));
        }
        break;
      }
      default:
        // Anything else (html_inline and html_block cannot occur with html: false) as its text.
        if (token.content) push(token.content);
    }
  }
  return root.children;
}

/**
 * Markdown as Preact nodes. `images` draws pictures from beside a document; without it, none are
 * fetched. `openFile` makes a file: link a way into that file; without it, the link is its words.
 */
export function renderMarkdown(source: string, images?: PageImages, openFile?: OpenFile): ComponentChildren[] {
  return build(parser.parse(source, {}), images, openFile);
}

const fenceOpen = /^ {0,3}(`{3,}|~{3,})/;
const listMarker = /^([-+*]|\d{1,9}[.)])(\s|$)/;
/** A link reference is the whole text's: one anywhere and the text is one block. */
const linkReference = /^ {0,3}\[[^\]]+\]:/m;

/** The blocks of the text last split, all but the last finished: a longer text starting with them is split from there. */
let lastSplit: { done: string; blocks: string[]; linked: boolean } = { done: "", blocks: [], linked: false };

/**
 * Markdown cut where it parses the same in pieces as whole (#214): before a line that starts at
 * the margin after a blank one, outside a fence, and that is no list item or quote, so no list,
 * quote, indented code or paragraph runs across the cut. Every block but the last is finished: a
 * message growing chunk by chunk parses only its last block again.
 *
 * A cut is remembered only once the line it cuts before has ended. Until then a longer line may
 * become a list item ("2" becoming "2. item"), and keeping the cut would parse differently from
 * the whole text.
 */
export function markdownBlocks(source: string): string[] {
  const continues = lastSplit.done !== "" && source.startsWith(lastSplit.done);
  // A link reference is resolved from anywhere, so once one is in the text it stays one block.
  if (lastSplit.linked && continues) return [source];
  if (linkReference.test(continues ? source.slice(lastSplit.done.length) : source)) {
    lastSplit = { done: source, blocks: [], linked: true };
    return [source];
  }
  const reuse = continues;
  const blocks = reuse ? [...lastSplit.blocks] : [];
  let start = reuse ? lastSplit.done.length : 0;
  let remembered = start;
  const rememberedBlocks = [...blocks];
  let fence: string | null = null;
  let blank = false;
  let at = start;
  while (at < source.length) {
    const end = source.indexOf("\n", at);
    const next = end < 0 ? source.length : end + 1;
    const line = source.slice(at, end < 0 ? source.length : end);
    const ended = end >= 0;
    if (fence) {
      if (ended && line.trimStart().startsWith(fence) && line.trim().replaceAll(fence[0]!, "") === "" && line.length - line.trimStart().length < 4) fence = null;
    } else {
      const isBlank = line.trim() === "";
      if (blank && !isBlank && at > start && !/^\s/.test(line) && !line.startsWith(">") && !listMarker.test(line)) {
        blocks.push(source.slice(start, at));
        start = at;
        if (ended) {
          rememberedBlocks.push(blocks[blocks.length - 1]!);
          remembered = at;
        }
      }
      blank = isBlank;
      const opened = fenceOpen.exec(line);
      if (opened) fence = opened[1]!;
    }
    at = next;
  }
  lastSplit = { done: source.slice(0, remembered), blocks: rememberedBlocks, linked: false };
  blocks.push(source.slice(start));
  return blocks;
}

/** One finished block, parsed once. */
const MarkdownBlock = memo(function MarkdownBlock({ text, images, openFile }: {
  text: string; images?: PageImages | undefined; openFile?: OpenFile | undefined;
}): ComponentChildren {
  return h(Fragment, null, ...renderMarkdown(text, images, openFile));
});

/** A message's text, drawn; only a block whose text changed is parsed again (#170, #214). */
export const Markdown = memo(function Markdown({ text, images, openFile }: {
  text: string; images?: PageImages | undefined; openFile?: OpenFile | undefined;
}): ComponentChildren {
  return h("div", { class: "markdown" }, ...markdownBlocks(text).map((block, index) => h(MarkdownBlock, { key: index, text: block, images, openFile })));
});
