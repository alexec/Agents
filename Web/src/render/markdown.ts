// What an agent wrote, drawn as Markdown and never as HTML (071 FR-031, research R9).
//
// markdown-it parses with `html: false`, so raw HTML in a message arrives as text. Its tokens are
// turned into Preact nodes here, never into an HTML string, so nothing an agent says can reach an
// HTML sink. Images become a placeholder naming them: the page loads nothing from anywhere but
// itself (the CSP says so too). A link opens in a new tab, and only http, https and mailto links
// are links at all.
import MarkdownIt, { type Token } from "markdown-it";
import { memo } from "./memo";
import { h, type ComponentChildren } from "preact";

const parser = new MarkdownIt({ html: false, linkify: true, typographer: false, breaks: false });

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
function build(tokens: readonly Token[]): ComponentChildren[] {
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
        if (isSafeLink(href)) {
          Object.assign(props, { href, target: "_blank", rel: "noopener noreferrer" });
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
        top().children.push(...build(token.children ?? []));
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
        push(h("pre", language ? { "data-language": language } : null, h("code", null, token.content)));
        break;
      }
      case "hr":
        push(h("hr", null));
        break;
      case "image": {
        const alt = token.children?.map((child) => child.content).join("") || token.attrGet("alt") || "";
        push(h("span", { class: "image-placeholder", title: token.attrGet("src") ?? "" },
          alt ? `[image: ${alt}]` : "[image]"));
        break;
      }
      default:
        // Anything else (html_inline and html_block cannot occur with html: false) as its text.
        if (token.content) push(token.content);
    }
  }
  return root.children;
}

/** Markdown as Preact nodes. */
export function renderMarkdown(source: string): ComponentChildren[] {
  return build(parser.parse(source, {}));
}

/** A message's text, drawn; parsed again only when the text changes (#170). */
export const Markdown = memo(function Markdown({ text }: { text: string }): ComponentChildren {
  return h("div", { class: "markdown" }, ...renderMarkdown(text));
});
