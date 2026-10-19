// A file's change, read in full on a page (#1472), as the window's and the Remote's FileDiffView
// (Shared/UI/Code/FileDiffView.swift): every line with its number in the old file and the new, long
// unchanged runs folded behind "N unchanged lines", a break where lines between hunks are not shown,
// and changed words washed. Unified, or the old file beside the new on a wide page. Its input is
// rows (`hunkRows`), not what they came from, so a pull request's page (#1341) draws the same.
// It does not scroll: the page does. Long lines wrap.
import { useSignal } from "@preact/signals";
import { useMemo } from "preact/hooks";
import { diffItems, type FileDiffRow } from "../model/fileDiff";

export type DiffLayout = "unified" | "sideBySide";

export function FileDiff({ rows, layout = "unified" }: { rows: FileDiffRow[]; layout?: DiffLayout }) {
  const opened = useSignal<ReadonlySet<number>>(new Set());
  const items = useMemo(() => diffItems(rows, opened.value, layout === "sideBySide"), [rows, opened.value, layout]);
  return (
    <div class={`file-diff ${layout === "sideBySide" ? "split" : "unified"}`} role="table" aria-label="The change, line by line">
      {items.map((item) => {
        switch (item.kind) {
          case "row": return <Line key={`r${item.row}`} row={rows[item.row]!} />;
          case "pair": return (
            <div key={`p${item.old ?? ""}-${item.next ?? ""}`} class="pair" role="row">
              {item.old === undefined ? <span class="empty" /> : <Line row={rows[item.old]!} side="old" />}
              {item.next === undefined ? <span class="empty" /> : <Line row={rows[item.next]!} side="new" />}
            </div>
          );
          case "fold": {
            const count = item.fold.to - item.fold.from;
            return (
              <button key={`f${item.fold.from}`} type="button" class="fold" title="Show the unchanged lines"
                onClick={() => (opened.value = new Set([...opened.value, item.fold.from]))}>
                ↕ {count === 1 ? "1 unchanged line" : `${count} unchanged lines`}
              </button>
            );
          }
          case "gap": return <div key={`g${item.before}`} class="gap" aria-label="Lines not in the change">⋯</div>;
        }
        return null;
      })}
    </div>
  );
}

/** One line: its old and new numbers (or one, on its side), its mark, and the text, wrapped. */
function Line({ row, side }: { row: FileDiffRow; side?: "old" | "new" }) {
  const sign = row.kind === "added" ? "+" : row.kind === "removed" ? "−" : " ";
  return (
    <div class={`line ${row.kind}`} role={side ? "cell" : "row"}>
      {side !== "new" && <span class="number" aria-label={row.oldLine === undefined ? undefined : `old line ${row.oldLine}`}>{row.oldLine ?? ""}</span>}
      {side !== "old" && <span class="number" aria-label={row.newLine === undefined ? undefined : `new line ${row.newLine}`}>{row.newLine ?? ""}</span>}
      <span class="sign" aria-hidden="true">{sign}</span>
      <span class="text"><Marked text={row.text} changed={row.changed} /></span>
    </div>
  );
}

/** A line's text, its changed stretches each in a mark of their own. */
function Marked({ text, changed }: { text: string; changed: [number, number][] | undefined }) {
  if (!text) return <>{" "}</>;
  if (!changed?.length) return <>{text}</>;
  const pieces = [];
  let at = 0;
  for (const [from, to] of changed) {
    if (from > at) pieces.push(text.slice(at, from));
    pieces.push(<mark key={from} class="diff-word">{text.slice(from, to)}</mark>);
    at = to;
  }
  if (at < text.length) pieces.push(text.slice(at));
  return <>{pieces}</>;
}
