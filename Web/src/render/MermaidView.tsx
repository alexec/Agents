// A Mermaid diagram (#853), drawn as an SVG of our own from the boxes, lines and labels
// model/mermaid.ts laid out: in the Files pane, in a ```mermaid fence, and small on the chat's
// card. The window and the Remote draw the same layout with a Canvas (Shared/UI/MermaidView.swift).
// Nothing in the file runs; the colours are the theme's.
//
// Fitted to the width it is offered, never drawn larger than its own size.
import type { ComponentChildren } from "preact";
import { useMemo } from "preact/hooks";
import { fontSize, lineHeight, problemWords, read, type Box, type MermaidDiagram } from "../model/mermaid";

function shape(box: Box, key: number) {
  const { x, y, width, height } = box;
  const cls = `mermaid-box mermaid-${box.shape}`;
  switch (box.shape) {
    case "circle":
      return <ellipse key={key} class={cls} cx={x + width / 2} cy={y + height / 2} rx={width / 2} ry={height / 2} />;
    case "diamond":
      return <polygon key={key} class={cls}
        points={`${x + width / 2},${y} ${x + width},${y + height / 2} ${x + width / 2},${y + height} ${x},${y + height / 2}`} />;
    default: {
      const radius = box.shape === "rounded" ? 10 : box.shape === "stadium" ? height / 2 : box.shape === "frame" ? 0 : box.shape === "note" ? 2 : 3;
      return <rect key={key} class={cls} x={x} y={y} width={width} height={height} rx={radius} />;
    }
  }
}

const pointsOf = (points: { x: number; y: number }[]) => points.map((p) => `${p.x},${p.y}`).join(" ");

export function MermaidView({ diagram, compact = false }: { diagram: MermaidDiagram; compact?: boolean }) {
  // On the card it sits in a button, where only phrasing content goes: a span, not a figure.
  const Root = compact ? "span" : "figure";
  const words = diagram.labels.flatMap((l) => l.lines).join(", ");
  return (
    <Root class={`mermaid${compact ? " compact" : ""}`} role="img" aria-label={`${diagram.summary}: ${words}`}>
      <svg viewBox={`0 0 ${diagram.width} ${diagram.height}`} class="mermaid-svg" aria-hidden="true"
        style={compact ? undefined : { maxWidth: `${diagram.width}px` }}>
        {diagram.boxes.map((box, i) => box.shape === "frame" && shape(box, i))}
        {diagram.lines.map((line, i) => (
          <g key={`l${i}`} class={`mermaid-line mermaid-${line.stroke}`}>
            <polyline points={pointsOf(line.points)} />
            {line.heads.map((h, j) => h.filled
              ? <polygon key={j} class="mermaid-head" points={pointsOf(h.points)} />
              : <polyline key={j} class="mermaid-head-open" points={pointsOf(h.points)} />)}
          </g>
        ))}
        {diagram.boxes.map((box, i) => box.shape !== "frame" && shape(box, i))}
        {diagram.labels.map((label, i) => (
          <g key={`t${i}`}>
            {label.backed && <rect class="mermaid-backing" x={label.x - 3} y={label.y} width={label.width + 6} height={label.height} />}
            <text class="mermaid-text" font-size={fontSize} text-anchor={label.leading ? "start" : "middle"}>
              {label.lines.map((words, j) => (
                <tspan key={j} x={label.leading ? label.x : label.x + label.width / 2}
                  y={label.y + lineHeight * (j + 0.5)} dominant-baseline="central">{words}</tspan>
              ))}
            </text>
          </g>
        ))}
      </svg>
    </Root>
  );
}

/** A ```mermaid fence (#853): the diagram, or the fence's code with why it is not drawn. */
export function MermaidFence({ text, code }: { text: string; code: ComponentChildren }) {
  const result = useMemo(() => read(text), [text]);
  if ("diagram" in result) return <div class="mermaid-fence"><MermaidView diagram={result.diagram} /></div>;
  return <><p class="quiet small mermaid-problem">{problemWords(result.problem)}</p>{code}</>;
}
