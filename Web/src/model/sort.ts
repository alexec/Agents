// A table's order (#2142): which column it is sorted by and which way, kept for the tab
// (sessionStorage) as Agents' filters are (#2141), so a reload keeps it and another tab starts
// with each table's own order.

export type SortDir = "asc" | "desc";
export type SortOrder = { column: string; dir: SortDir };
/** What a column sorts by: a number, a word, or nothing (which goes last either way). */
export type SortKey = string | number | undefined | null;

const storage = globalThis.window?.sessionStorage;
const prefix = "tableSort.";

/** The order a table was left in, or its own when none was kept or the column is gone. */
export function keptOrder(table: string, fallback: SortOrder, columns: readonly string[]): SortOrder {
  try {
    const kept = JSON.parse(storage?.getItem(prefix + table) ?? "null") as Partial<SortOrder> | null;
    if (kept && typeof kept.column === "string" && columns.includes(kept.column) && (kept.dir === "asc" || kept.dir === "desc")) {
      return { column: kept.column, dir: kept.dir };
    }
  } catch { /* not kept, or not readable */ }
  return fallback;
}

export function keepOrder(table: string, order: SortOrder): void {
  try { storage?.setItem(prefix + table, JSON.stringify(order)); } catch { /* private mode: for this page only */ }
}

/** A header pressed: its column the first way it goes (`first`), or the other way when it is the column already. */
export function nextOrder(current: SortOrder, column: string, first: SortDir = "asc"): SortOrder {
  if (current.column !== column) return { column, dir: first };
  return { column, dir: current.dir === "asc" ? "desc" : "asc" };
}

const words = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

function compare(a: SortKey, b: SortKey): number {
  if (typeof a === "number" && typeof b === "number") return a - b;
  return words.compare(String(a), String(b));
}

/** The rows in the order asked, a new array; equal rows keep their order, and a row with no key goes last both ways. */
export function sortRows<T>(rows: readonly T[], key: (row: T) => SortKey, dir: SortDir): T[] {
  const sign = dir === "asc" ? 1 : -1;
  return rows.map((row, i) => ({ row, i, k: key(row) }))
    .sort((x, y) => {
      const xNone = x.k === undefined || x.k === null || x.k === "";
      const yNone = y.k === undefined || y.k === null || y.k === "";
      if (xNone || yNone) return xNone === yNone ? x.i - y.i : xNone ? 1 : -1;
      return sign * compare(x.k, y.k) || x.i - y.i;
    })
    .map((x) => x.row);
}
