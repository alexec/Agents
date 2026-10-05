import { h, type ComponentChildren } from "preact";

// A small, inert highlighter for the languages CodeText colours in the shared clients. It emits
// text nodes and classed spans only; the agent's source is never treated as markup.
const keywords = new Set((
  "as async await break case catch class const continue def defer do else enum export extends " +
  "false final finally for func function guard if implements import in interface let match new nil " +
  "not null of package private public raise return self static struct super switch throw true try " +
  "type typeof var void while with yield"
).split(/\s+/));

const knownLanguages = new Set([
  "bash", "c", "cpp", "csharp", "css", "go", "html", "java", "javascript", "json", "kotlin",
  "markdown", "objectivec", "php", "python", "ruby", "rust", "shell", "sql", "swift", "typescript", "yaml",
]);
const aliases: Record<string, string> = { "c++": "cpp", "c#": "csharp", js: "javascript", jsx: "javascript", py: "python", sh: "shell", ts: "typescript", tsx: "typescript", yml: "yaml" };
const tokenPattern = /(\/\/[^\n]*|#[^\n]*|\/\*[\s\S]*?\*\/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b|[A-Za-z_$][\w$]*|\s+|.)/g;

/** Coloured code as text nodes, leaving unknown fence names plain as the shared clients do. */
export function highlightCode(source: string, fence: string): ComponentChildren[] {
  const rawLanguage = fence.trim().toLowerCase().split(/[\s,]+/)[0] ?? "";
  const language = aliases[rawLanguage] ?? rawLanguage;
  if (!knownLanguages.has(language)) return [source];
  const nodes: ComponentChildren[] = [];
  for (const match of source.matchAll(tokenPattern)) {
    const value = match[0];
    let kind: string | undefined;
    if (/^(?:\/\/|#|\/\*)/.test(value)) kind = "comment";
    else if (/^["'`]/.test(value)) kind = "string";
    else if (/^\d/.test(value)) kind = "number";
    else if (/^[A-Za-z_$]/.test(value) && keywords.has(value)) kind = "keyword";
    else if (/^[A-Za-z_$]/.test(value) && /^[A-Z]/.test(value)) kind = "type";
    else if (/^[=+*/%<>!&|^~-]+$/.test(value)) kind = "operator";
    else if (/^[{}()[\].,:;]$/.test(value)) kind = "punctuation";
    nodes.push(kind ? h("span", { class: `code-${kind}` }, value) : value);
  }
  return nodes;
}
