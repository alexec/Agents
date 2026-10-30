// The console's table (#2142): one for every list a person scans (machines, agents, people, requests,
// events). A header sorts by its column and again the other way (aria-sort, ▲ ▼); the order is kept for
// the tab. The header stays at the top while the page scrolls; below 760 the table scrolls sideways
// with its first column fixed. A row that opens something takes `onOpen`, the whole row its target.
import { useSignal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import { keepOrder, keptOrder, nextOrder, sortRows, type SortDir, type SortKey, type SortOrder } from "../model/sort";

export type Column<T> = {
  id: string;
  title: string;
  cell: (row: T) => ComponentChildren;
  /** What the column sorts by; none, and its header does not sort. */
  sort?: (row: T) => SortKey;
  /** The way a first press sorts: numbers and times go biggest or newest first. */
  first?: SortDir;
  /** Right-aligned, in tabular figures. */
  num?: boolean;
  class?: string;
};

export function DataTable<T>({ id, label, columns, rows, rowKey, order, empty, onOpen, rowClass }: {
  /** Names the table's kept order. */
  id: string;
  label: string;
  columns: readonly Column<T>[];
  rows: readonly T[];
  rowKey: (row: T) => string;
  order: SortOrder;
  empty: string;
  onOpen?: (row: T) => void;
  rowClass?: (row: T) => string | undefined;
}) {
  const sorted = useSignal<SortOrder>(keptOrder(id, order, columns.filter((c) => c.sort).map((c) => c.id)));
  const by = columns.find((c) => c.id === sorted.value.column && c.sort);
  const shown = by?.sort ? sortRows(rows, by.sort, sorted.value.dir) : rows;
  const press = (c: Column<T>) => {
    sorted.value = nextOrder(sorted.value, c.id, c.first);
    keepOrder(id, sorted.value);
  };
  return (
    <div class="data-table-wrap">
      <table class="data-table console-table" aria-label={label}>
        <thead>
          <tr>
            {columns.map((c) => {
              const on = by?.id === c.id;
              const cls = [c.num ? "num" : "", c.class ?? ""].filter(Boolean).join(" ") || undefined;
              return (
                <th key={c.id} scope="col" class={cls} aria-sort={on ? (sorted.value.dir === "asc" ? "ascending" : "descending") : undefined}>
                  {c.sort ? (
                    <button type="button" class={`sort${on ? " on" : ""}`} onClick={() => press(c)}>
                      {c.title}<span class="sort-mark" aria-hidden="true">{on ? (sorted.value.dir === "asc" ? "▲" : "▼") : ""}</span>
                    </button>
                  ) : c.title}
                </th>
              );
            })}
          </tr>
        </thead>
        <tbody>
          {shown.length === 0 && <tr class="empty"><td colSpan={columns.length}>{empty}</td></tr>}
          {shown.map((row) => (
            <tr key={rowKey(row)} class={[onOpen ? "opens" : "", rowClass?.(row) ?? ""].filter(Boolean).join(" ") || undefined}
              onClick={onOpen ? (e) => { if (!(e.target as HTMLElement).closest("button, a, input, select, textarea")) onOpen(row); } : undefined}>
              {columns.map((c) => (
                <td key={c.id} class={[c.num ? "num" : "", c.class ?? ""].filter(Boolean).join(" ") || undefined}>{c.cell(row)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
