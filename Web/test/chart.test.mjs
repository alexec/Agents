// A chart from a file (#836): the port of ChartSpec.swift, the card's words from ShownFile.swift,
// and where the chat draws a file shown, as TranscriptDisplayBuilder does.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const chart = await load("src/model/chart.ts");
const shown = await load("src/model/shownFile.ts");
const turns = await load("src/model/turns.ts");

const spec = (result) => {
  assert.ok("spec" in result, "spec" in result ? "" : chart.problemWords(result.problem));
  return result.spec;
};
const words = (result) => {
  assert.ok("problem" in result);
  return chart.problemWords(result.problem);
};

test("a file is a chart by its name, or a CSV with a hint", () => {
  assert.equal(chart.isVegaLite("/r/turns.vl.json"), true);
  assert.equal(chart.isVegaLite("/r/Turns.Vega-Lite.json"), true);
  assert.equal(chart.isVegaLite("/r/turns.vl"), true);
  assert.equal(chart.isVegaLite("/r/turns.json"), false);
  const hint = { mark: "line", x: "day", y: "cost" };
  assert.equal(chart.isChart("/r/a.csv", hint), true);
  assert.equal(chart.isChart("/r/a.tsv", hint), true);
  assert.equal(chart.isChart("/r/a.csv", undefined), false);
  assert.equal(chart.isChart("/r/a.txt", hint), false);
});

test("a Vega-Lite spec with its values inline", () => {
  const s = spec(chart.vegaLite(JSON.stringify({
    title: { text: "Turns" }, mark: { type: "bar" },
    encoding: { x: { field: "runtime", type: "nominal" }, y: { field: "turns" } },
    data: { values: [{ runtime: "Claude", turns: 3 }, { runtime: "Codex", turns: 5.5 }, { runtime: "Grok", turns: "x" }] },
  })));
  assert.equal(s.mark, "bar");
  assert.equal(s.title, "Turns");
  assert.equal(s.xAxis, "nominal");
  assert.deepEqual(s.points.map((p) => [p.x, p.y]), [["Claude", 3], ["Codex", 5.5]]);
  assert.equal(chart.summary(s), "Bar chart · 2 rows");
});

test("a spec outside the subset says why, in the window's words", () => {
  assert.equal(words(chart.vegaLite("[1]")), "This is not a Vega-Lite spec: it does not read as a JSON object.");
  assert.equal(words(chart.vegaLite("{")), "This is not a Vega-Lite spec: it does not read as a JSON object.");
  assert.equal(words(chart.vegaLite(JSON.stringify({ layer: [], mark: "bar" }))),
    "This chart uses layer, which the app does not draw. Its source is below.");
  assert.equal(words(chart.vegaLite(JSON.stringify({ mark: "arc" }))),
    "This chart uses the arc mark, which the app does not draw. Its source is below.");
  assert.equal(words(chart.vegaLite("{}")), "This chart uses a spec with no mark, which the app does not draw. Its source is below.");
  assert.equal(words(chart.vegaLite(JSON.stringify({ mark: "line", encoding: { x: { field: "a" } } }))),
    "The spec does not name an x and a y field.");
  const encoding = { x: { field: "a" }, y: { field: "b" } };
  assert.equal(words(chart.vegaLite(JSON.stringify({ mark: "line", encoding }))), "There is no data to draw.");
  assert.equal(words(chart.vegaLite(JSON.stringify({ mark: "line", encoding, data: { values: [] } }))), "There is no data to draw.");
  assert.equal(words(chart.vegaLite(JSON.stringify({ mark: "line", encoding, data: { url: "d.csv" } }))),
    "The data at d.csv could not be read.");
  assert.equal(words(chart.vegaLite(JSON.stringify({ mark: "line", encoding, data: { values: [{ c: 1 }] } }))),
    "There is no column called a.");
  assert.equal(words(chart.vegaLite(JSON.stringify({ mark: "line", encoding, data: { values: [{ a: 1 }] } }))),
    "There is no column called b.");
  assert.equal(words(chart.vegaLite(JSON.stringify({ mark: "line", encoding, data: { values: [{ a: 1, b: "no" }] } }))),
    "The b column has no numbers in it.");
});

test("data beside the spec: a CSV, a TSV or JSON, named relative to its folder", () => {
  const encoding = { x: { field: "day" }, y: { field: "cost" }, color: { field: "who" } };
  const text = JSON.stringify({ mark: "line", encoding, data: { url: "data/cost.csv" } });
  assert.equal(chart.dataURL(text), "data/cost.csv");
  assert.equal(chart.neighbourURL("data/cost.csv", "/p/reports/c.vl.json"), "/p/reports/data/cost.csv");
  assert.equal(chart.neighbourURL("../cost.csv", "/p/reports/c.vl.json"), "/p/cost.csv");
  assert.equal(chart.neighbourURL("/etc/passwd", "/p/c.vl.json"), undefined);
  assert.equal(chart.neighbourURL("https://example.com/a.csv", "/p/c.vl.json"), undefined);
  const s = spec(chart.vegaLite(text, (url) => (url === "data/cost.csv"
    ? "day,cost,who\r\n2026-10-01,1.5,a\r\n2026-10-02,2,b\r\n2026-10-02T10:00:00Z,3,a\n" : null)));
  assert.equal(s.xAxis, "temporal");
  assert.deepEqual(s.points.map((p) => [p.x.toISOString(), p.y, p.series]), [
    ["2026-10-01T00:00:00.000Z", 1.5, "a"], ["2026-10-02T00:00:00.000Z", 2, "b"], ["2026-10-02T10:00:00.000Z", 3, "a"],
  ]);
  assert.deepEqual(chart.series(s), ["a", "b"]);
  const tsv = JSON.stringify({ mark: "point", encoding, data: { url: "c.tsv" } });
  assert.equal(spec(chart.vegaLite(tsv, () => "day\tcost\n1\t2\n3\t4")).xAxis, "quantitative");
  const json = JSON.stringify({ mark: "area", encoding, data: { url: "c.json" } });
  assert.deepEqual(spec(chart.vegaLite(json, () => JSON.stringify([{ day: "Mon", cost: 1 }, 3]))).points.map((p) => p.x), ["Mon"]);
});

test("a declared x type wins over what the values look like", () => {
  const text = JSON.stringify({ mark: "bar", encoding: { x: { field: "year", type: "nominal" }, y: { field: "n" } },
    data: { values: [{ year: 2025, n: 1 }, { year: 2026, n: 2 }] } });
  assert.deepEqual(spec(chart.vegaLite(text)).points.map((p) => p.x), ["2025", "2026"]);
});

test("a CSV drawn as its hint says", () => {
  const s = spec(chart.csv(" day , cost \n1, 2\n2,x\n\n3,4.5\n", { mark: "point", x: "day", y: "cost", title: "Cost" }));
  assert.equal(s.xAxis, "quantitative");
  assert.deepEqual(s.points.map((p) => [p.x, p.y]), [[1, 2], [3, 4.5]]);
  assert.equal(chart.summary(s), "Scatter chart · 2 rows");
  assert.equal(chart.read("a,b\nx,1", "/p/a.csv", undefined).problem.kind, "noData");
  assert.equal(chart.summary(spec(chart.read("a\tb\nx\t1", "/p/a.TSV", { mark: "area", x: "a", y: "b" }))), "Area chart · 1 row");
});

test("past the limit the rest are left out, and the summary says so", () => {
  const rows = ["x,y", ...Array.from({ length: chart.pointLimit + 3 }, (_, i) => `${i},${i}`)].join("\n");
  const s = spec(chart.csv(rows, { mark: "line", x: "x", y: "y" }));
  assert.equal(s.points.length, chart.pointLimit);
  assert.equal(s.isCut, true);
  assert.equal(chart.summary(s), "Line chart · 5000 rows (first 5000)");
});

test("just enough CSV: quotes, doubled quotes, CRLF", () => {
  assert.deepEqual(chart.csvParse('a,"b, c","say ""hi"""\r\n1,"two\nlines",3'), [["a", "b, c", 'say "hi"'], ["1", "two\nlines", "3"]]);
  assert.deepEqual(chart.csvParse("a,b\n"), [["a", "b"]]);
  assert.deepEqual(chart.csvParse("a,\n"), [["a", ""]]);
  assert.deepEqual(chart.csvRows("a,b\n1\n").map((r) => Object.fromEntries(r)), [{ a: "1" }]);
});

test("dates as agents write them, and what is not one", () => {
  assert.equal(chart.date("2026-10-12")?.toISOString(), "2026-10-12T00:00:00.000Z");
  assert.equal(chart.date("2026-10-12T08:30:00+01:00")?.toISOString(), "2026-10-12T07:30:00.000Z");
  assert.equal(chart.date("2026-10-12T08:30:00")?.toISOString(), "2026-10-12T08:30:00.000Z");
  assert.equal(chart.date("2026-02-30"), undefined);
  assert.equal(chart.date("12/10/2026"), undefined);
  assert.equal(chart.infer(["1", " 2 ", ""]), "quantitative");
  assert.equal(chart.infer(["2026-10-01", "2026-10-02"]), "temporal");
  assert.equal(chart.infer(["1", "two"]), "nominal");
  assert.equal(chart.infer([]), "nominal");
});

test("the card's words: the look, the folder and the line", () => {
  const hint = { mark: "bar", x: "a", y: "b" };
  assert.equal(shown.look({ path: "/p/r/t.vl.json" }), "chart");
  assert.equal(shown.lookWords({ path: "/p/r/t.vl.json" }), "Chart");
  assert.equal(shown.cardLine({ path: "/p/reports/t.csv", chart: hint }), "Bar chart · reports/");
  assert.equal(shown.cardLine({ path: "/p/docs/a.svg" }), "Picture · docs/");
  assert.equal(shown.cardLine({ path: "/p/reports/report.md", line: 12 }), "Page · reports/ · line 12");
  assert.equal(shown.lookWords({ path: "/p/a.html" }), "Page");
  assert.equal(shown.lookWords({ path: "/p/a.csv" }), "File");
  assert.equal(shown.cardLine({ path: "/a.swift", line: 3 }), "File · line 3");
});

test("a file shown is its own item, after the run that called it, and an outcome", () => {
  const call = (id, n) => ({ id, at: n, kind: { toolCall: { _0: { toolCallID: `c${n}`, title: "Read", kind: "read" } } } });
  const entries = [
    { id: "u", at: 0, kind: { userMessage: { _0: "Chart it" } } },
    call("t1", 1),
    { id: "f", at: 2, kind: { fileShown: { _0: { path: "/p/t.csv", chart: { mark: "bar", x: "a", y: "b" } } } } },
    call("t2", 3),
  ];
  const items = turns.display(entries);
  assert.deepEqual(items.map((i) => i.kind === "run" ? `run:${i.calls.length}` : i.id), ["u", "run:1", "f", "run:1"]);
  const [turn] = turns.turns(items);
  const parts = turns.turnParts(turn.items, false);
  assert.deepEqual(parts.outcome.map((i) => i.id), ["f"]);
  assert.equal(parts.stepCount, 2);
});
