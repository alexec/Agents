// What the chat's card for a file an agent showed is (#836): ShownFile.look and lookWords
// (Model/ShownFile.swift). A chart, a diagram (#853) and a picture show a preview; anything else is one line.
import { isChart, markWords, type ChartHint } from "./chart";
import { isMermaid } from "./mermaid";

/** The fields of a ShownFile the card reads. */
export interface Shown {
  path: string;
  line?: number | undefined;
  chart?: ChartHint | undefined;
}

export type Look = "chart" | "diagram" | "picture" | "page" | "file";

/** FileProbe.imageKinds. */
const imageKinds = new Set(["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "icns"]);
/** ShownFile.markdownExtensions and HTMLPageScope.extensions. */
const pageKinds = new Set(["md", "markdown", "mdown", "mkd", "html", "htm"]);

function extensionOf(path: string): string {
  const name = path.split("/").filter(Boolean).pop() ?? "";
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

export function look(file: Shown): Look {
  if (isChart(file.path, file.chart)) return "chart";
  if (isMermaid(file.path)) return "diagram";
  const ext = extensionOf(file.path);
  if (imageKinds.has(ext)) return "picture";
  if (pageKinds.has(ext)) return "page";
  return "file";
}

/** The card's grey line before the folder: "Bar chart", "Diagram", "Picture", "Page", "File". */
export function lookWords(file: Shown): string {
  switch (look(file)) {
    case "chart": return file.chart ? markWords(file.chart.mark) : "Chart";
    case "diagram": return "Diagram";
    case "picture": return "Picture";
    case "page": return "Page";
    case "file": return "File";
  }
}

/** The card's grey line: "Bar chart · reports/ · line 12". */
export function cardLine(file: Shown): string {
  const parts = file.path.split("/").filter(Boolean);
  const folder = parts.length > 1 ? `${parts[parts.length - 2]}/` : undefined;
  return [lookWords(file), folder, file.line ? `line ${file.line}` : undefined].filter(Boolean).join(" · ");
}
