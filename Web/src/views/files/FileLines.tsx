// A file's text, numbered, wrapping rather than running off the pane (FileLines, #258).
// The numbers are drawn by the stylesheet, so the text a walk reads is still the file's.
import { useLayoutEffect, useRef } from "preact/hooks";
import { gutterIsWide, lineLabel, linePastEnd, splitLines } from "../../model/fileLines";

export function FileLines({ text, line }: { text: string; line?: number | undefined }) {
  const lines = splitLines(text);
  const pre = useRef<HTMLPreElement>(null);
  const past = linePastEnd(line, lines.length);
  useLayoutEffect(() => {
    const row = line && line >= 1 && line <= lines.length ? pre.current?.querySelector(`[data-line="${line}"]`) : null;
    row?.scrollIntoView({ block: "center" });
  }, [text, line]);
  return (
    <>
      {past && <p class="quiet small">{past}</p>}
      <pre class={`file-text file-lines${gutterIsWide(lines.length) ? " wide" : ""}`} ref={pre}>
        {lines.map((content, index) => {
          const number = index + 1;
          return (
            <span key={number} class={`file-line${number === line ? " named" : ""}`} data-line={number} aria-label={lineLabel(number, content)}>
              {index > 0 ? <span class="nl">{"\n"}</span> : null}
              <span class="code">{content}</span>
            </span>
          );
        })}
      </pre>
    </>
  );
}
