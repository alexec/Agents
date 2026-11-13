// A file an agent showed with `show_file`, where it showed it (#836), as an Object card (#5035):
// Shared/UI/Chat/FileCard.swift for the page. A chart, a diagram (#853) or a picture has its preview
// above the name; anything else is one row. A click opens it in the Files pane at its line.
import { useSignal } from "@preact/signals";
import { useContext, useEffect } from "preact/hooks";
import { markWords, problemWords, type ChartSpec } from "../../model/chart";
import { read as readMermaid, problemWords as mermaidProblemWords, type MermaidDiagram } from "../../model/mermaid";
import { pictureFromReading } from "../../model/pageImage";
import { cardLine, look, type Look, type Shown } from "../../model/shownFile";
import { ChartView, readChart } from "../files/ChartView";
import { MermaidView } from "../../render/MermaidView";
import { CallActionsContext } from "./Rows";
import type { IconName } from "../Icon";
import { ObjectCard } from "./ObjectCard";

type Preview =
  | { kind: "loading" }
  | { kind: "chart"; spec: ChartSpec }
  | { kind: "diagram"; diagram: MermaidDiagram }
  | { kind: "picture"; src: string }
  | { kind: "words"; words: string }
  | { kind: "gone" };

// The window's symbols, as Lucide icons (FileCard.swift).
const icons: Record<Look, IconName> = { chart: "chart-column", diagram: "workflow", picture: "image", page: "file-text", file: "file-text" };

function nameOf(path: string): string {
  return path.split("/").filter(Boolean).pop() ?? path;
}

export function FileCard({ file }: { file: Shown }) {
  const actions = useContext(CallActionsContext);
  const kind = look(file);
  const previewed = kind === "chart" || kind === "diagram" || kind === "picture";
  const preview = useSignal<Preview>({ kind: "loading" });
  // A CSV's hint is held for the pane, which looks it up by path when the card opens it.
  useEffect(() => actions?.noteChart?.(file), [file.path, file.chart]);
  useEffect(() => {
    const read = actions?.readFile;
    if (!previewed || !read) return;
    let current = true;
    let made: string | null = null;
    preview.value = { kind: "loading" };
    const readText = (path: string) => read(path).then((r) => (r.kind === "text" ? r.text : null), () => null);
    void read(file.path).then(async (reading) => {
      if (!current) return;
      if (kind === "picture") {
        const picture = pictureFromReading(file.path, reading);
        if (!picture) { preview.value = { kind: "gone" }; return; }
        made = URL.createObjectURL(new Blob([picture.bytes as BlobPart], { type: picture.type }));
        preview.value = { kind: "picture", src: made };
        return;
      }
      if (reading.kind !== "text") { preview.value = { kind: "gone" }; return; }
      if (kind === "diagram") {
        const drawn = readMermaid(reading.text);
        preview.value = "diagram" in drawn ? { kind: "diagram", diagram: drawn.diagram } : { kind: "words", words: mermaidProblemWords(drawn.problem) };
        return;
      }
      const result = await readChart(reading.text, file.path, file.chart, readText);
      if (!current) return;
      preview.value = "spec" in result ? { kind: "chart", spec: result.spec } : { kind: "words", words: problemWords(result.problem) };
    }, () => { if (current) preview.value = { kind: "gone" }; });
    return () => {
      current = false;
      if (made) URL.revokeObjectURL(made);
    };
  }, [file.path, file.chart?.mark, file.chart?.x, file.chart?.y, file.chart?.color, !!actions?.readFile]);

  const shown = preview.value;
  const name = nameOf(file.path);
  // A spec says its own mark: once read, the card names it, where the path alone says "Chart".
  const detail = shown.kind === "gone" ? "Not there now"
    : shown.kind === "chart" && !file.chart ? cardLine(file).replace(/^Chart/, markWords(shown.spec.mark))
    : cardLine(file);
  const open = actions?.showFile;
  return (
    <ObjectCard icon={icons[kind]} title={name} detail={detail} openTitle={`Open ${name} in Files`}
      open={open ? () => open(file) : undefined}
      preview={previewed && shown.kind !== "gone" ? (
        <>
          {shown.kind === "loading" && <span class="quiet small">Reading…</span>}
          {shown.kind === "chart" && <ChartView spec={shown.spec} compact />}
          {shown.kind === "diagram" && <MermaidView diagram={shown.diagram} compact />}
          {shown.kind === "picture" && <img src={shown.src} alt="" />}
          {shown.kind === "words" && <span class="quiet small">{shown.words}</span>}
        </>
      ) : undefined} />
  );
}
