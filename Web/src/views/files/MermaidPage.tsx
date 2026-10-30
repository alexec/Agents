// A Mermaid file in the Files pane (#853): MermaidPage in Shared/UI/MermaidView.swift. The diagram
// or why it is not drawn, with its source a toggle away, as ChartPage is for a chart.
import { useSignal } from "@preact/signals";
import { useMemo } from "preact/hooks";
import { problemWords, read } from "../../model/mermaid";
import { MermaidView } from "../../render/MermaidView";
import { FileLines } from "./FileLines";

export function MermaidPage({ text, line }: { text: string; line?: number | undefined }) {
  const result = useMemo(() => read(text), [text]);
  const showsSource = useSignal(false);
  return (
    <div class="chart-page">
      <div class="chart-head">
        <span class="quiet small">{"diagram" in result ? result.diagram.summary : "Not drawn"}</span>
        <div class="tabs" role="tablist" aria-label="Show">
          {([false, true] as const).map((source) => (
            <button key={String(source)} role="tab" aria-selected={showsSource.value === source}
              class={showsSource.value === source ? "on" : ""} onClick={() => (showsSource.value = source)}>
              {source ? "Source" : "Diagram"}
            </button>
          ))}
        </div>
      </div>
      {showsSource.value ? <FileLines text={text} line={line} />
        : "diagram" in result ? <MermaidView diagram={result.diagram} />
        : <><p class="quiet small chart-problem">{problemWords(result.problem)}</p><FileLines text={text} line={line} /></>}
    </div>
  );
}
