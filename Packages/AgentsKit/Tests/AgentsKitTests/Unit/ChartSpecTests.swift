import Foundation
import Testing
@testable import AgentsKitCore

/// Charts from a file (#836): a Vega-Lite subset, or a CSV with a hint, drawn natively.
@Suite("Reading a chart")
struct ChartSpecTests {
    @Test func aVegaLiteSpecWithInlineValuesIsABarChart() throws {
        let spec = try ChartSpec.vegaLite("""
            {"title": "Turns", "mark": "bar",
             "data": {"values": [{"runtime": "Claude", "turns": 12}, {"runtime": "Codex", "turns": 7.5}]},
             "encoding": {"x": {"field": "runtime", "type": "nominal"}, "y": {"field": "turns"}}}
            """).get()
        #expect(spec.mark == .bar)
        #expect(spec.title == "Turns")
        #expect(spec.xAxis == .nominal)
        #expect(spec.points == [.init(x: .name("Claude"), y: 12, series: nil),
                                .init(x: .name("Codex"), y: 7.5, series: nil)])
        #expect(spec.summary == "Bar chart · 2 rows")
    }

    @Test func aMarkObjectAndADataURLBesideTheSpecAreRead() throws {
        let spec = try ChartSpec.vegaLite("""
            {"mark": {"type": "line"}, "data": {"url": "days.csv"},
             "encoding": {"x": {"field": "day"}, "y": {"field": "cost"}, "color": {"field": "who"}}}
            """, neighbour: { $0 == "days.csv" ? "day,cost,who\n2026-10-01,1.5,a\n2026-10-02,2,b\n" : nil }).get()
        #expect(spec.mark == .line)
        #expect(spec.xAxis == .temporal)
        #expect(spec.series == ["a", "b"])
    }

    @Test func whatTheAppDoesNotDrawIsSaid() {
        #expect(ChartSpec.vegaLite(#"{"layer": [], "mark": "bar"}"#) == .failure(.unsupported("layer")))
        #expect(ChartSpec.vegaLite(#"{"mark": "arc"}"#) == .failure(.unsupported("the arc mark")))
        #expect(ChartSpec.vegaLite("not json") == .failure(.notJSON))
        #expect(ChartSpec.vegaLite(#"{"mark": "bar", "encoding": {"x": {"field": "a"}}}"#) == .failure(.missingEncoding))
        #expect(ChartSpec.vegaLite(#"{"mark": "bar", "data": {"url": "gone.csv"}, "encoding": {"x": {"field": "a"}, "y": {"field": "b"}}}"#)
            == .failure(.dataUnreadable("gone.csv")))
    }

    @Test func aCSVWithAHintIsDrawnAsTheHintSays() throws {
        let hint = ChartHint(mark: .point, x: "size", y: "time")
        let spec = try ChartSpec.csv("size,time\n1,0.5\n2,\"1,0\"\n3,x\n4,2\n", hint: hint).get()
        #expect(spec.xAxis == .quantitative)
        // A row whose y is not a number is left out, not drawn at zero.
        #expect(spec.points.map(\.y) == [0.5, 2])
        #expect(ChartSpec.csv("a,b\n1,2\n", hint: ChartHint(mark: .bar, x: "a", y: "c")) == .failure(.noColumn("c")))
    }

    @Test func csvQuotesAndLineEndings() {
        #expect(CSV.parse("a,b\r\n\"x, y\",\"say \"\"hi\"\"\"\r\n") == [["a", "b"], ["x, y", "say \"hi\""]])
        #expect(CSV.rows("a\tb\n1\t2", separator: "\t") == [["a": "1", "b": "2"]])
    }

    @Test func aHintFromTheWireNeedsBothColumns() {
        #expect(ChartHint(wire: ["x": "a", "y": "b", "mark": "LINE"]) == ChartHint(mark: .line, x: "a", y: "b"))
        #expect(ChartHint(wire: ["x": "a", "mark": "bar"]) == nil)
        #expect(ChartHint(wire: ["x": "a", "y": "b", "mark": "pie"])?.mark == .bar)
    }

    @Test func aShownFileSaysWhatItsCardIs() {
        #expect(ShownFile(path: "/w/turns.vl.json").look == .chart)
        #expect(ShownFile(path: "/w/t.csv").look == .file)
        #expect(ShownFile(path: "/w/t.csv", chart: ChartHint(mark: .area, x: "a", y: "b")).lookWords == "Area chart")
        #expect(ShownFile(path: "/w/a.svg").look == .picture)
        #expect(ShownFile(path: "/w/report.md").lookWords == "Page")
        #expect(ShownFile(wire: ["path": "/w/t.csv", "chart": ["x": "a", "y": "b"]])?.chart?.y == "b")
    }

    /// The card is on the record and drawn at every level, after the run that called it.
    @Test func aFileShownIsAnOutcomeOfItsOwn() throws {
        let file = ShownFile(path: "/w/turns.vl.json", line: 3)
        let entry = TranscriptEntry(kind: .fileShown(file))
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.kind == .fileShown(file))

        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .toolCall(ToolCall(toolCallID: "1", title: "show_file", name: AppTool.showFile))),
            entry,
        ])
        #expect(items.count == 2)
        #expect(items.last == .entry(entry))
        #expect(items.last?.isOutcome == true)
    }
}
