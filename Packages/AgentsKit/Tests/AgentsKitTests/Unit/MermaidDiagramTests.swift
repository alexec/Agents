import Foundation
import Testing
@testable import AgentsKitCore

/// Mermaid diagrams (#853): a flowchart and sequence subset, read and laid out here and
/// drawn natively by each client. Web/test/mermaid.test.mjs holds the port to the same cases.
@Suite("Reading a Mermaid diagram")
struct MermaidDiagramTests {
    private func diagram(_ text: String) throws -> MermaidDiagram {
        try MermaidDiagram.read(text).get()
    }

    private func problem(_ text: String) -> String? {
        if case .failure(let problem) = MermaidDiagram.read(text) { return problem.words }
        return nil
    }

    private func words(_ diagram: MermaidDiagram) -> [String] {
        diagram.labels.flatMap(\.lines)
    }

    @Test func aFileOrAFenceIsMermaidByItsName() {
        #expect(MermaidDiagram.isMermaid(URL(filePath: "/r/flow.mmd")))
        #expect(MermaidDiagram.isMermaid(URL(filePath: "/r/Flow.Mermaid")))
        #expect(!MermaidDiagram.isMermaid(URL(filePath: "/r/flow.md")))
        #expect(MermaidDiagram.isFence("mermaid"))
        #expect(!MermaidDiagram.isFence("swift"))
        #expect(!MermaidDiagram.isFence(nil))
    }

    @Test func aFlowchartHasABoxPerNodeAndALinePerLink() throws {
        let chart = try diagram("""
            %% a comment
            flowchart TD
                A[Start] --> B{Is it?}
                B -->|Yes| C(Do it)
                B -- No --> D([Stop])
                C --> D
            """)
        #expect(chart.kind == .flowchart)
        #expect(chart.boxes.map(\.shape) == [.rectangle, .diamond, .rounded, .stadium])
        #expect(chart.lines.count == 4)
        #expect(chart.lines.allSatisfy { $0.heads.count == 1 && $0.heads[0].filled })
        #expect(Set(words(chart)) == ["Start", "Is it?", "Yes", "No", "Do it", "Stop"])
        #expect(chart.summary == "Flowchart · 4 boxes")
        // Top to bottom: each rank below the one before.
        let ys = chart.boxes.map { $0.y + $0.height / 2 }
        #expect(ys[0] < ys[1] && ys[1] < ys[2] && ys[2] < ys[3])
        #expect(chart.boxes.allSatisfy { $0.x >= 0 && $0.x + $0.width <= chart.width })
    }

    @Test func leftToRightPutsRanksSideBySide() throws {
        let chart = try diagram("graph LR; A --> B; B --> C")
        let xs = chart.boxes.map(\.x)
        #expect(xs[0] < xs[1] && xs[1] < xs[2])
        #expect(Set(chart.boxes.map(\.y)).count == 1)
    }

    @Test func linksTakeTheirStrokesAndEnds() throws {
        let chart = try diagram("""
            graph TD
            A --- B
            B -.-> C
            C ==> D
            D --x E
            E <--> F
            F ~~~ G
            G -. maybe .-> H
            """)
        #expect(chart.lines.map(\.stroke) == [.solid, .dashed, .thick, .solid, .solid, .dashed])
        #expect(chart.lines.map(\.heads.count) == [0, 1, 1, 2, 2, 1])
        #expect(words(chart).contains("maybe"))
        // `~~~` places G below F and draws nothing.
        #expect(chart.boxes.count == 8)
    }

    @Test func ampersandsAndChainsMakeEveryLink() throws {
        let chart = try diagram("graph TD\nA & B --> C --> D")
        #expect(chart.lines.count == 3)
    }

    @Test func aCycleIsDrawnWithoutLoopingTheRanks() throws {
        let chart = try diagram("graph TD\nA --> B\nB --> C\nC --> A\nC --> C")
        #expect(chart.boxes.count == 3)
        #expect(chart.lines.count == 4)
        #expect(chart.lines[3].points.count == 4)
    }

    @Test func aLinkThatWouldCrossABoxGoesRoundIt() throws {
        let chart = try diagram("graph TD\nA --> B\nB --> C\nA --> C")
        #expect(chart.lines.map(\.points.count) == [2, 2, 4])
        let lane = chart.lines[2].points[1].x
        #expect(chart.boxes.allSatisfy { $0.x + $0.width < lane })
    }

    @Test func quotedTextBreaksAndStylesAreRead() throws {
        let chart = try diagram("""
            graph TD
            A["One; two<br>three"]:::hot --> B
            classDef hot fill:#f00
            style B fill:#0f0
            """)
        #expect(words(chart).contains("One; two"))
        #expect(words(chart).contains("three"))
    }

    @Test func aSequenceDiagramHasParticipantsMessagesAndNotes() throws {
        let chart = try diagram("""
            sequenceDiagram
                autonumber
                participant A as Alice
                actor B as Bob
                A->>+B: Hello
                B-->>-A: Hi
                Note over A,B: Both
                loop Every minute
                    A-)B: Ping
                    alt Busy
                        B-xA: No
                    else
                        B->>B: Think
                    end
                end
            """)
        #expect(chart.kind == .sequence)
        #expect(chart.summary == "Sequence diagram · 5 messages")
        let all = words(chart)
        #expect(all.filter { $0 == "Alice" }.count == 2)
        #expect(all.contains("1. Hello"))
        #expect(all.contains("5. Think"))
        #expect(all.contains("loop [Every minute]"))
        #expect(all.contains("alt [Busy]"))
        #expect(chart.boxes.filter { $0.shape == .frame }.count == 2)
        #expect(chart.boxes.filter { $0.shape == .note }.count == 1)
        // Two lifelines, five messages and the alt's divider.
        #expect(chart.lines.count == 8)
        #expect(chart.lines.filter { $0.stroke == .dashed }.count == 4)
    }

    @Test func aMessageIsWideEnoughForItsWords() throws {
        let long = String(repeating: "word ", count: 20)
        let chart = try diagram("sequenceDiagram\nA->>B: \(long)")
        let arrow = chart.lines[2]
        #expect(arrow.points[1].x - arrow.points[0].x >= Double(long.trimmingCharacters(in: .whitespaces).count) * MermaidDiagram.characterWidth)
    }

    @Test func outsideTheSubsetSaysWhy() {
        #expect(problem("") == "There is no diagram here.")
        #expect(problem("%% only a comment") == "There is no diagram here.")
        #expect(problem("classDiagram\nA <|-- B") == "The app draws flowcharts and sequence diagrams, not classDiagram. Its source is below.")
        #expect(problem("graph TD\nsubgraph one\nA-->B\nend") == "This diagram uses subgraphs, which the app does not draw. Its source is below.")
        #expect(problem("graph TD\nA -> B") == "Line 2 does not read as Mermaid: A -> B")
        #expect(problem("graph XY") == "Line 1 does not read as Mermaid: graph XY")
        #expect(problem("sequenceDiagram\nbox Aqua Group\nend") == "This diagram uses boxes around participants, which the app does not draw. Its source is below.")
        #expect(problem("sequenceDiagram\nend") == "Line 2 does not read as Mermaid: end")
        #expect(problem("sequenceDiagram\nA B") == "Line 2 does not read as Mermaid: A B")
    }

    @Test func frontMatterIsLeftOut() throws {
        let chart = try diagram("---\ntitle: Flow\n---\ngraph TD\nA-->B")
        #expect(chart.boxes.count == 2)
    }

    @Test func aDiagramTooBigShowsItsSource() {
        let links = (0...MermaidDiagram.elementLimit).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        #expect(problem("graph TD\n" + links) == "This diagram is too big to draw here. Its source is below.")
    }

    /// The page lays the same diagrams out to the same sizes (Web/test/mermaid.test.mjs), so
    /// a diagram looks the same on all three clients.
    @Test func theLayoutIsTheSameOnEveryClient() throws {
        let flowchart = try diagram("""
            %% a comment
            flowchart TD
                A[Start] --> B{Is it?}
                B -->|Yes| C(Do it)
                B -- No --> D([Stop])
                C --> D
            """)
        #expect(flowchart.width == 151)
        #expect(flowchart.height == 334.5)
        let sequence = try diagram("""
            sequenceDiagram
                autonumber
                participant A as Alice
                actor B as Bob
                A->>+B: Hello
                B-->>-A: Hi
                Note over A,B: Both
                loop Every minute
                    A-)B: Ping
                    alt Busy
                        B-xA: No
                    else
                        B->>B: Think
                    end
                end
            """)
        #expect(sequence.width == 307)
        #expect(sequence.height == 473)
    }

    @Test func aShownMermaidFileIsADiagram() {
        let file = ShownFile(path: "/r/flow.mmd")
        #expect(file.look == .diagram)
        #expect(file.lookWords == "Diagram")
    }
}
