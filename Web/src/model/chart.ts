// A chart the page draws (#836): ChartSpec, ChartHint, ChartMark and ChartProblem
// (Model/ChartSpec.swift), ported by hand with the same names and the same sentences.
//
// Only a subset of Vega-Lite: one mark, x, y and colour, the data inline or in a file beside the
// spec. Or a CSV with a hint the agent sent with `show_file`. Drawn as an SVG of our own, so
// nothing in the file runs and the chart follows the theme. A spec outside the subset is a
// ChartProblem, and its source is shown with the reason.
import type { ChartHint, ChartMark } from "../protocol/generated";

/** ChartHint (how to draw a CSV) and ChartMark (bar, line, point, area) come over the wire. */
export type { ChartHint, ChartMark };

const marks: readonly ChartMark[] = ["bar", "line", "point", "area"];

/** ChartMark.words: said on the card, "Bar chart". */
export function markWords(mark: ChartMark): string {
  switch (mark) {
    case "bar": return "Bar chart";
    case "line": return "Line chart";
    case "point": return "Scatter chart";
    case "area": return "Area chart";
  }
}

/** ChartSpec.Axis: names one bar each, numbers on a scale, dates on a time scale. */
export type Axis = "nominal" | "quantitative" | "temporal";

/** ChartSpec.XValue: a name, a number or a date, as the axis reads it. */
export type XValue = string | number | Date;

export interface Point {
  x: XValue;
  y: number;
  series?: string | undefined;
}

export interface ChartSpec {
  mark: ChartMark;
  title?: string | undefined;
  xField: string;
  yField: string;
  colorField?: string | undefined;
  xAxis: Axis;
  points: Point[];
  isCut: boolean;
}

/** Why a chart was not drawn, said above its source. */
export type ChartProblem =
  | { kind: "notJSON" }
  | { kind: "unsupported"; what: string }
  | { kind: "missingEncoding" }
  | { kind: "noData" }
  | { kind: "dataUnreadable"; url: string }
  | { kind: "noColumn"; name: string }
  | { kind: "noNumbers"; name: string };

export type ChartResult = { spec: ChartSpec } | { problem: ChartProblem };

/** ChartProblem.words. */
export function problemWords(problem: ChartProblem): string {
  switch (problem.kind) {
    case "notJSON": return "This is not a Vega-Lite spec: it does not read as a JSON object.";
    case "unsupported": return `This chart uses ${problem.what}, which the app does not draw. Its source is below.`;
    case "missingEncoding": return "The spec does not name an x and a y field.";
    case "noData": return "There is no data to draw.";
    case "dataUnreadable": return `The data at ${problem.url} could not be read.`;
    case "noColumn": return `There is no column called ${problem.name}.`;
    case "noNumbers": return `The ${problem.name} column has no numbers in it.`;
  }
}

/** Past this many points a chart is a smear; the rest are left out and said to be. */
export const pointLimit = 5_000;

function nameOf(path: string): string {
  return (path.split("/").filter(Boolean).pop() ?? path).toLowerCase();
}

function extensionOf(path: string): string {
  const name = nameOf(path);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1) : "";
}

/** Whether a file is a Vega-Lite spec by its name: `x.vl.json`, `x.vega-lite.json` or `x.vl`. */
export function isVegaLite(path: string): boolean {
  const name = nameOf(path);
  return name.endsWith(".vl.json") || name.endsWith(".vega-lite.json") || name.endsWith(".vl");
}

export function isCSV(path: string): boolean {
  const ext = extensionOf(path);
  return ext === "csv" || ext === "tsv";
}

/** Whether a file can be drawn as a chart: a spec, or a CSV the agent said how to draw. */
export function isChart(path: string, hint: ChartHint | undefined): boolean {
  return isVegaLite(path) || (hint !== undefined && isCSV(path));
}

type JSONObject = Record<string, unknown>;

function isObject(value: unknown): value is JSONObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function at(value: unknown, ...keys: string[]): unknown {
  let current = value;
  for (const key of keys) {
    if (!isObject(current) || !Object.hasOwn(current, key)) return undefined;
    current = current[key];
  }
  return current;
}

function stringAt(value: unknown, ...keys: string[]): string | undefined {
  const found = at(value, ...keys);
  return typeof found === "string" ? found : undefined;
}

/** JSONValue.chartText: a field of a data row as the chart reads it, a string or a number as text. */
function chartText(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return undefined;
}

function rowsOf(values: unknown[]): Map<string, string>[] {
  return values.flatMap((value) => {
    if (!isObject(value)) return [];
    const row = new Map<string, string>();
    for (const [key, field] of Object.entries(value)) {
      const text = chartText(field);
      if (text !== undefined) row.set(key, text);
    }
    return [row];
  });
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/**
 * The file a spec's `data.url` names, or undefined. The page reads it (beside the spec, see
 * `neighbourURL`) before it calls `vegaLite`, since a read here is not at once.
 */
export function dataURL(text: string): string | undefined {
  return stringAt(parseJSON(text), "data", "url");
}

/**
 * Where a `data.url` points, beside the spec, as an absolute path. Only a relative path: a web
 * address is not fetched, as the page never fetches one.
 */
export function neighbourURL(name: string, specPath: string): string | undefined {
  if (!name || name.startsWith("/") || name.includes("://")) return undefined;
  const folder = specPath.slice(0, specPath.lastIndexOf("/"));
  const settled: string[] = [];
  for (const part of `${folder}/${name}`.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") settled.pop();
    else settled.push(part);
  }
  return "/" + settled.join("/");
}

/**
 * A Vega-Lite spec. `neighbour` gives the text of a file a `data.url` names, read beforehand;
 * null when it could not be read.
 */
export function vegaLite(text: string, neighbour: (url: string) => string | null = () => null): ChartResult {
  const spec = parseJSON(text);
  if (!isObject(spec)) return { problem: { kind: "notJSON" } };
  for (const key of ["layer", "hconcat", "vconcat", "concat", "facet", "repeat", "transform"]) {
    if (Object.hasOwn(spec, key)) return { problem: { kind: "unsupported", what: key } };
  }
  const markName = stringAt(spec, "mark") ?? stringAt(spec, "mark", "type") ?? "";
  const mark = marks.find((m) => m === markName.toLowerCase());
  if (!mark) {
    return { problem: { kind: "unsupported", what: markName ? `the ${markName} mark` : "a spec with no mark" } };
  }
  const x = stringAt(spec, "encoding", "x", "field");
  const y = stringAt(spec, "encoding", "y", "field");
  if (x === undefined || y === undefined) return { problem: { kind: "missingEncoding" } };
  const color = stringAt(spec, "encoding", "color", "field");
  const title = stringAt(spec, "title") ?? stringAt(spec, "title", "text");

  let rows: Map<string, string>[];
  const values = at(spec, "data", "values");
  const url = stringAt(spec, "data", "url");
  if (Array.isArray(values)) {
    rows = rowsOf(values);
  } else if (url !== undefined) {
    const body = neighbour(url);
    if (body === null) return { problem: { kind: "dataUnreadable", url } };
    const lower = url.toLowerCase();
    const parsed = lower.endsWith(".json") ? parseJSON(body) : undefined;
    rows = Array.isArray(parsed) ? rowsOf(parsed) : csvRows(body, lower.endsWith(".tsv") ? "\t" : ",");
  } else {
    return { problem: { kind: "noData" } };
  }
  const type = stringAt(spec, "encoding", "x", "type");
  const declared = type === "nominal" || type === "quantitative" || type === "temporal" ? type : undefined;
  return make(mark, title, x, y, color, declared, rows);
}

/** A CSV, drawn as its hint says. */
export function csv(text: string, hint: ChartHint, tabs = false): ChartResult {
  return make(hint.mark, hint.title, hint.x, hint.y, hint.color, undefined, csvRows(text, tabs ? "\t" : ","));
}

/** Either, by the file's name. */
export function read(text: string, path: string, hint: ChartHint | undefined,
  neighbour: (url: string) => string | null = () => null): ChartResult {
  if (isVegaLite(path)) return vegaLite(text, neighbour);
  if (hint) return csv(text, hint, extensionOf(path) === "tsv");
  return { problem: { kind: "noData" } };
}

/** Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not line ends. */
function trimmed(text: string): string {
  return text.replace(/^[^\S\r\n]+|[^\S\r\n]+$/g, "");
}

/** Swift's `Double(_:)`: the whole text a number, with no space around it. */
function double(text: string): number | undefined {
  if (/^[+-]?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i.test(text)) return Number(text);
  if (/^[+-]?(inf|infinity)$/i.test(text)) return text.startsWith("-") ? -Infinity : Infinity;
  if (/^[+-]?nan$/i.test(text)) return NaN;
  return undefined;
}

export function make(mark: ChartMark, title: string | undefined, x: string, y: string, color: string | undefined,
  declared: Axis | undefined, rows: Map<string, string>[]): ChartResult {
  if (!rows.length) return { problem: { kind: "noData" } };
  if (!rows.some((row) => row.has(x))) return { problem: { kind: "noColumn", name: x } };
  if (!rows.some((row) => row.has(y))) return { problem: { kind: "noColumn", name: y } };
  const xs = rows.flatMap((row) => row.get(x) ?? []);
  const axis = declared ?? infer(xs);
  const points: Point[] = [];
  for (const row of rows) {
    const rawX = row.get(x);
    const rawY = row.get(y);
    if (rawX === undefined || rawY === undefined) continue;
    const value = double(trimmed(rawY));
    if (value === undefined || !Number.isFinite(value)) continue;
    const xValue = parse(rawX, axis);
    if (xValue === undefined) continue;
    points.push({ x: xValue, y: value, series: color === undefined ? undefined : row.get(color) });
  }
  if (!points.length) return { problem: { kind: "noNumbers", name: y } };
  return { spec: { mark, title, xField: x, yField: y, colorField: color, xAxis: axis,
    points: points.slice(0, pointLimit), isCut: points.length > pointLimit } };
}

export function infer(values: string[]): Axis {
  const kept = values.map(trimmed).filter((v) => v !== "");
  if (!kept.length) return "nominal";
  if (kept.every((v) => double(v) !== undefined)) return "quantitative";
  if (kept.every((v) => date(v) !== undefined)) return "temporal";
  return "nominal";
}

export function parse(raw: string, axis: Axis): XValue | undefined {
  const text = trimmed(raw);
  switch (axis) {
    case "nominal": return text;
    case "quantitative": return double(text);
    case "temporal": return date(text);
  }
}

function utc(year: string, month: string, day: string, hour = "0", minute = "0", second = "0"): Date | undefined {
  const [y, mo, d, h, mi, s] = [year, month, day, hour, minute, second].map(Number) as [number, number, number, number, number, number];
  const date = new Date(Date.UTC(y, mo - 1, d, h, mi, s));
  // A day or a time that does not exist is no date, as the formatter has it.
  if (date.getUTCFullYear() !== y || date.getUTCMonth() !== mo - 1 || date.getUTCDate() !== d
    || date.getUTCHours() !== h || date.getUTCMinutes() !== mi || date.getUTCSeconds() !== s) return undefined;
  return date;
}

/** An ISO 8601 date, with or without its time: what agents write. A time without a zone is UTC. */
export function date(text: string): Date | undefined {
  const full = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|[+-]\d{2}:?\d{2})?$/.exec(text);
  if (full) {
    const [, y, mo, d, h, mi, s, zone] = full as unknown as [string, string, string, string, string, string, string, string | undefined];
    const base = utc(y, mo, d, h, mi, s);
    if (!base || !zone || zone === "Z") return base;
    const sign = zone.startsWith("-") ? -1 : 1;
    const digits = zone.slice(1).replace(":", "");
    const offset = (Number(digits.slice(0, 2)) * 60 + Number(digits.slice(2))) * sign;
    return new Date(base.getTime() - offset * 60_000);
  }
  const day = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
  if (day) return utc(day[1]!, day[2]!, day[3]!);
  return undefined;
}

/** The series, in the order they first came: the legend's order. */
export function series(spec: ChartSpec): string[] {
  const seen: string[] = [];
  for (const point of spec.points) if (point.series !== undefined && !seen.includes(point.series)) seen.push(point.series);
  return seen;
}

/** "Bar chart · 12 rows", for the card and the pane. */
export function summary(spec: ChartSpec): string {
  const rows = spec.points.length === 1 ? "1 row" : `${spec.points.length} rows`;
  return `${markWords(spec.mark)} · ${rows}${spec.isCut ? ` (first ${pointLimit})` : ""}`;
}

/** CSV.rows: a header row, then a row for each line, by the header's names. */
export function csvRows(text: string, separator = ","): Map<string, string>[] {
  const table = csvParse(text, separator);
  const header = table[0];
  if (!header) return [];
  const names = header.map(trimmed);
  return table.slice(1).flatMap((fields) => {
    if (fields.length === 1 && fields[0] === "") return [];
    const row = new Map<string, string>();
    names.forEach((name, index) => { if (index < fields.length) row.set(name, fields[index]!); });
    return [row];
  });
}

/** CSV.parse: just enough CSV, quoted fields with doubled quotes, CRLF or LF. */
export function csvParse(text: string, separator = ","): string[][] {
  const table: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i]!;
    if (quoted) {
      if (char === "\"") {
        if (text[i + 1] === "\"") { field += "\""; i++; } else quoted = false;
      } else {
        field += char;
      }
      continue;
    }
    if (char === "\"" && field === "") {
      quoted = true;
    } else if (char === separator) {
      row.push(field);
      field = "";
    } else if (char === "\n" || char === "\r") {
      // A CR and LF together are one line end.
      if (char === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      field = "";
      table.push(row);
      row = [];
    } else {
      field += char;
    }
  }
  if (field !== "" || row.length) { row.push(field); table.push(row); }
  return table;
}
