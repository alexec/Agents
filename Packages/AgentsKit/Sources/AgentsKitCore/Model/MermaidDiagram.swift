import Foundation

/// A Mermaid diagram the clients draw (#853): a `.mmd` file shown with `show_file`, or a
/// ```` ```mermaid ```` fence in a Markdown page.
///
/// Only a subset of Mermaid: flowcharts (`graph` or `flowchart`, its node shapes and
/// links) and sequence diagrams (participants, messages, notes and the loop/alt/opt
/// frames). It is read and laid out here, into boxes, lines and labels, and each client
/// only draws those: a Canvas on the Mac and the Remote (Shared/UI/MermaidView.swift),
/// an SVG on the web (Web/src/model/mermaid.ts is the port of this file). Nothing runs,
/// and no JavaScript is bundled. A diagram outside the subset is a `MermaidProblem`,
/// and its source is shown with the reason.
///
/// Text is measured by a fixed width per character, not by a font, so the three
/// clients lay a diagram out the same way.
public struct MermaidDiagram: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case flowchart, sequence
    }

    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public enum Shape: String, Hashable, Sendable {
        /// A flowchart's `[text]`, and a sequence diagram's participant.
        case rectangle
        /// `(text)` and `{{text}}`.
        case rounded
        /// `([text])`.
        case stadium
        /// `((text))`.
        case circle
        /// `{text}`: a decision.
        case diamond
        /// A sequence diagram's note.
        case note
        /// A sequence diagram's loop, alt or opt: drawn behind, not filled.
        case frame
    }

    public struct Box: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var shape: Shape
    }

    public enum Stroke: String, Hashable, Sendable {
        case solid, dashed, thick
    }

    /// The end of a line: a filled triangle, or strokes (an open arrow, a cross).
    public struct Head: Hashable, Sendable {
        public var points: [Point]
        public var filled: Bool
    }

    public struct Line: Hashable, Sendable {
        public var points: [Point]
        public var stroke: Stroke
        public var heads: [Head]
    }

    /// Words in a rectangle: one line of text per `lineHeight`, centred unless leading.
    /// A backed label has the page's colour behind it, so a line under it does not
    /// cross the words.
    public struct Label: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var lines: [String]
        public var leading: Bool
        public var backed: Bool
    }

    public var kind: Kind
    public var width: Double
    public var height: Double
    public var boxes: [Box]
    public var lines: [Line]
    public var labels: [Label]
    /// Said above it in the Files pane: "Flowchart · 5 boxes".
    public var summary: String

    /// The size text is drawn at, and the width and height it is measured by.
    public static let fontSize = 13.0
    public static let characterWidth = 7.0
    public static let lineHeight = 17.0
    /// Past this many boxes or messages, the source is shown instead.
    public static let elementLimit = 400

    public static let fileExtensions: Set<String> = ["mmd", "mermaid"]

    public static func isMermaid(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether a Markdown fence's tag is Mermaid's.
    public static func isFence(_ language: String?) -> Bool {
        language?.lowercased() == "mermaid"
    }

    /// The words of a box or a message, a line each, as Mermaid writes a break.
    static func textLines(_ text: String) -> [String] {
        var text = text
        for br in ["<br/>", "<br />", "<br>"] {
            text = text.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func measure(_ lines: [String]) -> (width: Double, height: Double) {
        let longest = lines.map(\.count).max() ?? 0
        return (Double(longest) * characterWidth, Double(lines.count) * lineHeight)
    }

    static func label(centreX: Double, centreY: Double, _ lines: [String], backed: Bool = false) -> Label {
        let size = measure(lines)
        return Label(x: centreX - size.width / 2, y: centreY - size.height / 2,
                     width: size.width, height: size.height, lines: lines, leading: false, backed: backed)
    }

    static func leadingLabel(x: Double, centreY: Double, _ lines: [String]) -> Label {
        let size = measure(lines)
        return Label(x: x, y: centreY - size.height / 2, width: size.width, height: size.height,
                     lines: lines, leading: true, backed: false)
    }

    /// The diagram a text describes, or why it is not drawn.
    public static func read(_ text: String) -> Result<MermaidDiagram, MermaidProblem> {
        let statements = MermaidStatements(text)
        guard let header = statements.lines.first else { return .failure(.empty) }
        let word = header.text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" })
            .first.map(String.init) ?? ""
        switch word {
        case "graph", "flowchart":
            return MermaidFlowchart.read(statements).map { $0.laidOut() }
        case "sequenceDiagram":
            return MermaidSequence.read(statements).map { $0.laidOut() }
        default:
            return .failure(.unsupportedKind(word))
        }
    }

    /// Everything moved so the nearest edge is `margin` from the top and left, and the
    /// size taken from the farthest.
    static func framed(kind: Kind, boxes: [Box], lines: [Line], labels: [Label], summary: String) -> MermaidDiagram {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        func take(_ x: Double, _ y: Double) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        for box in boxes { take(box.x, box.y); take(box.x + box.width, box.y + box.height) }
        for line in lines {
            for point in line.points { take(point.x, point.y) }
            for head in line.heads { for point in head.points { take(point.x, point.y) } }
        }
        for label in labels { take(label.x - 3, label.y); take(label.x + label.width + 3, label.y + label.height) }
        if minX == .infinity { minX = 0; minY = 0; maxX = 0; maxY = 0 }
        let margin = 12.0
        let dx = margin - minX, dy = margin - minY
        func move(_ p: Point) -> Point { Point(x: p.x + dx, y: p.y + dy) }
        return MermaidDiagram(
            kind: kind, width: maxX - minX + margin * 2, height: maxY - minY + margin * 2,
            boxes: boxes.map { Box(x: $0.x + dx, y: $0.y + dy, width: $0.width, height: $0.height, shape: $0.shape) },
            lines: lines.map { line in
                Line(points: line.points.map(move), stroke: line.stroke,
                     heads: line.heads.map { Head(points: $0.points.map(move), filled: $0.filled) })
            },
            labels: labels.map { label in
                var label = label
                label.x += dx
                label.y += dy
                return label
            },
            summary: summary)
    }

    enum HeadKind: Hashable, Sendable {
        case arrow, open, cross, circle
    }

    /// A line's end at `tip`, pointing away from `from`.
    static func head(_ kind: HeadKind, at tip: Point, from: Point) -> [Head] {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return [] }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        func at(_ back: Double, _ side: Double) -> Point {
            Point(x: tip.x - ux * back + nx * side, y: tip.y - uy * back + ny * side)
        }
        switch kind {
        case .arrow: return [Head(points: [at(9, 4.5), tip, at(9, -4.5)], filled: true)]
        case .open: return [Head(points: [at(9, 4.5), tip, at(9, -4.5)], filled: false)]
        case .cross:
            return [Head(points: [at(9, 4), at(1, -4)], filled: false),
                    Head(points: [at(9, -4), at(1, 4)], filled: false)]
        case .circle:
            let points = (0..<8).map { step -> Point in
                let angle = Double(step) * Double.pi / 4
                return at(4 + 4 * cos(angle), 4 * sin(angle))
            }
            return [Head(points: points, filled: true)]
        }
    }
}

/// Why a Mermaid diagram was not drawn, said above its source.
public enum MermaidProblem: Error, Hashable, Sendable {
    case empty
    case unsupportedKind(String)
    case unsupported(String)
    case unreadable(line: Int, text: String)
    case tooBig

    public var words: String {
        switch self {
        case .empty: return "There is no diagram here."
        case .unsupportedKind(let kind):
            return "The app draws flowcharts and sequence diagrams, not \(kind.isEmpty ? "this" : kind). Its source is below."
        case .unsupported(let what): return "This diagram uses \(what), which the app does not draw. Its source is below."
        case .unreadable(let line, let text): return "Line \(line) does not read as Mermaid: \(text)"
        case .tooBig: return "This diagram is too big to draw here. Its source is below."
        }
    }
}

/// A diagram's text as statements, each with the line it was on: comments, directives
/// and front matter left out, a line split at its semicolons.
struct MermaidStatements {
    struct Statement: Hashable {
        var line: Int
        var text: String
    }

    var lines: [Statement] = []

    init(_ text: String) {
        var inFrontMatter = false
        var seenContent = false
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---", !seenContent || inFrontMatter {
                inFrontMatter.toggle()
                seenContent = true
                continue
            }
            if inFrontMatter || line.isEmpty || line.hasPrefix("%%") { continue }
            seenContent = true
            for part in Self.split(line) {
                let part = part.trimmingCharacters(in: .whitespaces)
                if !part.isEmpty { lines.append(Statement(line: index + 1, text: part)) }
            }
        }
    }

    /// A line split at each semicolon outside quotes.
    static func split(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() }
            if character == ";", !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}

// MARK: - Flowchart

struct MermaidFlowchart {
    enum Direction: String { case down = "TD", up = "BT", right = "LR", left = "RL" }

    struct Node {
        var id: String
        var lines: [String]
        var shape: MermaidDiagram.Shape
    }

    struct Edge {
        var from: Int
        var to: Int
        var lines: [String]
        /// Nil for `~~~`, a link that places the nodes and is not drawn.
        var stroke: MermaidDiagram.Stroke?
        var start: MermaidDiagram.HeadKind?
        var end: MermaidDiagram.HeadKind?
    }

    var direction = Direction.down
    var nodes: [Node] = []
    var edges: [Edge] = []
    var index: [String: Int] = [:]

    static func read(_ statements: MermaidStatements) -> Result<MermaidFlowchart, MermaidProblem> {
        var chart = MermaidFlowchart()
        for (number, statement) in statements.lines.enumerated() {
            var text = statement.text
            if number == 0 {
                // `graph LR`, and perhaps a first statement after it on the same line.
                var words = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
                words.removeFirst()
                if let first = words.first {
                    switch first.uppercased() {
                    case "TD", "TB": chart.direction = .down
                    case "BT": chart.direction = .up
                    case "LR": chart.direction = .right
                    case "RL": chart.direction = .left
                    default: return .failure(.unreadable(line: statement.line, text: text))
                    }
                    words.removeFirst()
                }
                text = words.joined(separator: " ")
                if text.isEmpty { continue }
            }
            let first = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            switch first {
            case "classDef", "class", "style", "linkStyle", "click":
                // How it looks or what a click does: the app draws it in its own colours.
                continue
            case "subgraph", "end":
                return .failure(.unsupported("subgraphs"))
            default:
                guard chart.statement(text) else {
                    return .failure(.unreadable(line: statement.line, text: text))
                }
            }
            if chart.nodes.count > MermaidDiagram.elementLimit || chart.edges.count > MermaidDiagram.elementLimit * 2 {
                return .failure(.tooBig)
            }
        }
        if chart.nodes.isEmpty { return .failure(.empty) }
        return .success(chart)
    }

    /// `A[One] --> B & C -- label --> D`. False when it does not read.
    mutating func statement(_ text: String) -> Bool {
        var scanner = MermaidScanner(text)
        guard var group = nodeGroup(&scanner) else { return false }
        while true {
            scanner.skipSpaces()
            if scanner.atEnd { return true }
            guard let link = scanner.link(), let next = nodeGroup(&scanner) else { return false }
            for from in group {
                for to in next {
                    edges.append(Edge(from: from, to: to, lines: link.text.map(MermaidDiagram.textLines) ?? [],
                                      stroke: link.stroke, start: link.start, end: link.end))
                }
            }
            group = next
        }
    }

    private mutating func nodeGroup(_ scanner: inout MermaidScanner) -> [Int]? {
        var group: [Int] = []
        repeat {
            scanner.skipSpaces()
            guard let read = scanner.node() else { return nil }
            group.append(add(read))
            scanner.skipSpaces()
        } while scanner.take("&")
        return group
    }

    private mutating func add(_ read: MermaidScanner.ReadNode) -> Int {
        if let known = index[read.id] {
            if let shape = read.shape {
                nodes[known].shape = shape
                nodes[known].lines = MermaidDiagram.textLines(read.text ?? read.id)
            }
            return known
        }
        index[read.id] = nodes.count
        nodes.append(Node(id: read.id, lines: MermaidDiagram.textLines(read.text ?? read.id),
                          shape: read.shape ?? .rectangle))
        return nodes.count - 1
    }

    // MARK: Layout

    /// Layered: each node a rank below the deepest node with a link into it, links that
    /// go back up left out of the ranking; the order in a rank settled by a few sweeps
    /// toward the mean place of each node's neighbours.
    func laidOut() -> MermaidDiagram {
        let sizes = nodes.map(Self.size)
        let ranks = ranks()
        let rankCount = (ranks.max() ?? 0) + 1
        var layers = Array(repeating: [Int](), count: rankCount)
        for node in nodes.indices { layers[ranks[node]].append(node) }
        var place = Array(repeating: 0.0, count: nodes.count)
        for layer in layers { for (position, node) in layer.enumerated() { place[node] = Double(position) } }

        func sweep(_ order: [Int], neighbours: (Int) -> [Int]) {
            for rank in order {
                let keyed = layers[rank].map { node -> (key: Double, place: Double, node: Int) in
                    let around = neighbours(node)
                    let key = around.isEmpty ? place[node] : around.map { place[$0] }.reduce(0, +) / Double(around.count)
                    return (key, place[node], node)
                }
                layers[rank] = keyed.sorted { ($0.key, $0.place) < ($1.key, $1.place) }.map(\.node)
                for (position, node) in layers[rank].enumerated() { place[node] = Double(position) }
            }
        }
        let drawn = edges.filter { $0.from != $0.to }
        for _ in 0..<4 {
            sweep(Array(1..<max(1, rankCount))) { node in
                drawn.filter { $0.to == node && ranks[$0.from] < ranks[node] }.map(\.from)
            }
            sweep(Array((0..<max(0, rankCount - 1)).reversed())) { node in
                drawn.filter { $0.from == node && ranks[$0.to] > ranks[node] }.map(\.to)
            }
        }

        // Down the page for TD, across for LR: `along` is the rank's way, `across` the
        // way a rank's nodes are side by side.
        let sideways = direction == .right || direction == .left
        let rankGap = sideways ? 64.0 : 52.0
        let nodeGap = sideways ? 22.0 : 28.0
        func along(_ size: (width: Double, height: Double)) -> Double { sideways ? size.width : size.height }
        func across(_ size: (width: Double, height: Double)) -> Double { sideways ? size.height : size.width }
        let spans = layers.map { layer in
            layer.map { across(sizes[$0]) }.reduce(0, +) + nodeGap * Double(max(0, layer.count - 1))
        }
        let widest = spans.max() ?? 0
        var centres = Array(repeating: MermaidDiagram.Point(x: 0, y: 0), count: nodes.count)
        var depth = 0.0
        for (rank, layer) in layers.enumerated() {
            let thickness = layer.map { along(sizes[$0]) }.max() ?? 0
            var side = (widest - spans[rank]) / 2
            for node in layer {
                let middle = side + across(sizes[node]) / 2
                let deep = depth + thickness / 2
                centres[node] = sideways ? .init(x: deep, y: middle) : .init(x: middle, y: deep)
                side += across(sizes[node]) + nodeGap
            }
            depth += thickness + rankGap
        }
        let extent = depth - rankGap
        if direction == .up { centres = centres.map { .init(x: $0.x, y: extent - $0.y) } }
        if direction == .left { centres = centres.map { .init(x: extent - $0.x, y: $0.y) } }

        let boxes = nodes.indices.map { node in
            MermaidDiagram.Box(x: centres[node].x - sizes[node].width / 2, y: centres[node].y - sizes[node].height / 2,
                               width: sizes[node].width, height: sizes[node].height, shape: nodes[node].shape)
        }
        var lines: [MermaidDiagram.Line] = []
        var labels: [MermaidDiagram.Label] = []
        var lanes = 0
        for edge in edges {
            guard let stroke = edge.stroke else { continue }
            var points: [MermaidDiagram.Point]
            if edge.from == edge.to {
                let box = boxes[edge.from]
                let right = box.x + box.width
                let middle = box.y + box.height / 2
                points = [.init(x: right, y: middle - 8), .init(x: right + 22, y: middle - 8),
                          .init(x: right + 22, y: middle + 8), .init(x: right, y: middle + 8)]
            } else {
                points = [Self.border(boxes[edge.from], toward: centres[edge.to]),
                          Self.border(boxes[edge.to], toward: centres[edge.from])]
                let crossed = boxes.indices.contains { node in
                    node != edge.from && node != edge.to && Self.crosses(points[0], points[1], boxes[node])
                }
                if crossed {
                    // A straight line would cross another box, as a link back up does:
                    // it goes round the side instead, in a lane of its own.
                    let low = min(ranks[edge.from], ranks[edge.to]), high = max(ranks[edge.from], ranks[edge.to])
                    let beside = nodes.indices.filter { ranks[$0] >= low && ranks[$0] <= high }
                    let a = boxes[edge.from], b = boxes[edge.to]
                    if sideways {
                        let lane = (beside.map { boxes[$0].y + boxes[$0].height }.max() ?? 0) + 18 + Double(lanes) * 12
                        points = [.init(x: a.x + a.width / 2, y: a.y + a.height), .init(x: a.x + a.width / 2, y: lane),
                                  .init(x: b.x + b.width / 2, y: lane), .init(x: b.x + b.width / 2, y: b.y + b.height)]
                    } else {
                        let lane = (beside.map { boxes[$0].x + boxes[$0].width }.max() ?? 0) + 18 + Double(lanes) * 12
                        points = [.init(x: a.x + a.width, y: a.y + a.height / 2), .init(x: lane, y: a.y + a.height / 2),
                                  .init(x: lane, y: b.y + b.height / 2), .init(x: b.x + b.width, y: b.y + b.height / 2)]
                    }
                    lanes += 1
                }
            }
            var heads: [MermaidDiagram.Head] = []
            if let end = edge.end { heads += MermaidDiagram.head(end, at: points[points.count - 1], from: points[points.count - 2]) }
            if let start = edge.start { heads += MermaidDiagram.head(start, at: points[0], from: points[1]) }
            lines.append(.init(points: points, stroke: stroke, heads: heads))
            if !edge.lines.isEmpty {
                // On the middle stretch of the line: the only one, or the lane's.
                let a = points[points.count == 4 ? 1 : 0], b = points[points.count == 4 ? 2 : 1]
                let centreX = (a.x + b.x) / 2 + (edge.from == edge.to ? MermaidDiagram.measure(edge.lines).width / 2 + 6 : 0)
                labels.append(MermaidDiagram.label(centreX: centreX, centreY: (a.y + b.y) / 2, edge.lines, backed: true))
            }
        }
        for node in nodes.indices {
            labels.append(MermaidDiagram.label(centreX: centres[node].x, centreY: centres[node].y, nodes[node].lines))
        }
        let summary = "Flowchart · \(nodes.count) \(nodes.count == 1 ? "box" : "boxes")"
        return MermaidDiagram.framed(kind: .flowchart, boxes: boxes, lines: lines, labels: labels, summary: summary)
    }

    static func size(_ node: Node) -> (width: Double, height: Double) {
        let text = MermaidDiagram.measure(node.lines)
        let width = max(text.width + 28, 48), height = text.height + 18
        switch node.shape {
        case .diamond: return ((text.width + 24) * 1.5, (text.height + 16) * 1.5)
        case .circle:
            let side = max(text.width + 24, text.height + 24)
            return (side, side)
        default: return (width, height)
        }
    }

    /// Whether the line from `a` to `b` passes through the box, kept a point inside its edge.
    static func crosses(_ a: MermaidDiagram.Point, _ b: MermaidDiagram.Point, _ box: MermaidDiagram.Box) -> Bool {
        var enter = 0.0, leave = 1.0
        for (start, step, low, high) in [(a.x, b.x - a.x, box.x + 1, box.x + box.width - 1),
                                         (a.y, b.y - a.y, box.y + 1, box.y + box.height - 1)] {
            if step == 0 {
                if start < low || start > high { return false }
            } else {
                let first = (low - start) / step, second = (high - start) / step
                enter = max(enter, min(first, second))
                leave = min(leave, max(first, second))
                if enter > leave { return false }
            }
        }
        return true
    }

    /// Where a line from the box's centre toward `point` leaves the box.
    static func border(_ box: MermaidDiagram.Box, toward point: MermaidDiagram.Point) -> MermaidDiagram.Point {
        let centre = MermaidDiagram.Point(x: box.x + box.width / 2, y: box.y + box.height / 2)
        let dx = point.x - centre.x, dy = point.y - centre.y
        if dx == 0, dy == 0 { return centre }
        let halfWidth = box.width / 2, halfHeight = box.height / 2
        let scale: Double
        switch box.shape {
        case .diamond: scale = 1 / (abs(dx) / halfWidth + abs(dy) / halfHeight)
        case .circle: scale = halfWidth / (dx * dx + dy * dy).squareRoot()
        default: scale = min(dx == 0 ? .infinity : halfWidth / abs(dx), dy == 0 ? .infinity : halfHeight / abs(dy))
        }
        return .init(x: centre.x + dx * scale, y: centre.y + dy * scale)
    }

    /// Each node's rank: one below the deepest node with a forward link into it. A link
    /// back to a node still being walked closes a cycle, and is left out.
    func ranks() -> [Int] {
        var state = Array(repeating: 0, count: nodes.count)
        var finished: [Int] = []
        var forward = Array(repeating: true, count: edges.count)
        func visit(_ node: Int) {
            state[node] = 1
            for (number, edge) in edges.enumerated() where edge.from == node {
                if edge.to == node || state[edge.to] == 1 {
                    forward[number] = false
                } else if state[edge.to] == 0 {
                    visit(edge.to)
                }
            }
            state[node] = 2
            finished.append(node)
        }
        for node in nodes.indices where state[node] == 0 { visit(node) }
        var rank = Array(repeating: 0, count: nodes.count)
        for node in finished.reversed() {
            for (number, edge) in edges.enumerated() where edge.from == node && forward[number] {
                rank[edge.to] = max(rank[edge.to], rank[node] + 1)
            }
        }
        return rank
    }
}

/// Reads a flowchart statement a piece at a time.
struct MermaidScanner {
    let characters: [Character]
    var position = 0

    init(_ text: String) { characters = Array(text) }

    var atEnd: Bool { position >= characters.count }

    func peek(_ offset: Int = 0) -> Character? {
        position + offset < characters.count ? characters[position + offset] : nil
    }

    func has(_ text: String) -> Bool {
        let wanted = Array(text)
        guard position + wanted.count <= characters.count else { return false }
        return Array(characters[position..<position + wanted.count]) == wanted
    }

    mutating func take(_ text: String) -> Bool {
        guard has(text) else { return false }
        position += text.count
        return true
    }

    mutating func skipSpaces() {
        while let character = peek(), character == " " || character == "\t" { position += 1 }
    }

    static func isIDCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    struct ReadNode {
        var id: String
        var text: String?
        var shape: MermaidDiagram.Shape?
    }

    /// Openers, longest first, each with the closers it takes and the shape it makes.
    static let shapes: [(open: String, close: [String], shape: MermaidDiagram.Shape)] = [
        ("(((", [")))"], .circle), ("((", ["))"], .circle), ("([", ["])"], .stadium),
        ("[[", ["]]"], .rectangle), ("[(", [")]"], .rectangle), ("[/", ["/]", "\\]"], .rectangle),
        ("[\\", ["\\]", "/]"], .rectangle), ("{{", ["}}"], .rounded), ("{", ["}"], .diamond),
        ("(", [")"], .rounded), ("[", ["]"], .rectangle), (">", ["]"], .rectangle),
    ]

    /// `id`, `id[text]`, `id("quoted text")`, and a `:::class` after it, left out.
    mutating func node() -> ReadNode? {
        let start = position
        while let character = peek(), Self.isIDCharacter(character) { position += 1 }
        guard position > start else { return nil }
        var node = ReadNode(id: String(characters[start..<position]))
        for entry in Self.shapes {
            guard take(entry.open) else { continue }
            guard let text = shapeText(entry.close) else { return nil }
            node.text = text
            node.shape = entry.shape
            break
        }
        if take(":::") {
            while let character = peek(), Self.isIDCharacter(character) || character == "-" { position += 1 }
        }
        return node
    }

    private mutating func shapeText(_ closers: [String]) -> String? {
        skipSpaces()
        if peek() == "\"" {
            position += 1
            let start = position
            while let character = peek(), character != "\"" { position += 1 }
            guard !atEnd else { return nil }
            let text = String(characters[start..<position])
            position += 1
            skipSpaces()
            for closer in closers where has(closer) {
                position += closer.count
                return Self.unquoted(text)
            }
            return nil
        }
        let start = position
        while !atEnd {
            for closer in closers where has(closer) {
                let text = String(characters[start..<position]).trimmingCharacters(in: .whitespaces)
                position += closer.count
                return Self.unquoted(text)
            }
            position += 1
        }
        return nil
    }

    /// A Markdown string's backquotes left out: "`**bold**`" reads as its words.
    static func unquoted(_ text: String) -> String {
        var text = text
        if text.hasPrefix("`"), text.hasSuffix("`"), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
        return text
    }

    struct Link {
        var stroke: MermaidDiagram.Stroke?
        var start: MermaidDiagram.HeadKind?
        var end: MermaidDiagram.HeadKind?
        var text: String?
    }

    static let linkCharacters: Set<Character> = ["-", "=", ".", "~"]

    /// `-->`, `---`, `-.->`, `==>`, `~~~`, `<-->`, `--x`, `--o`, with `|text|` after or
    /// `-- text -->` around its words.
    mutating func link() -> Link? {
        var link = Link()
        if take("<") { link.start = .arrow }
        let start = position
        while let character = peek(), Self.linkCharacters.contains(character) { position += 1 }
        let body = String(characters[start..<position])
        if ["--", "==", "-."].contains(body), peek() == " " {
            // `-- text -->`: the words run to the next run of two link characters.
            let textStart = position
            while !atEnd {
                if let character = peek(), Self.linkCharacters.contains(character),
                   let next = peek(1), Self.linkCharacters.contains(next) { break }
                position += 1
            }
            guard !atEnd else { return nil }
            link.text = String(characters[textStart..<position]).trimmingCharacters(in: .whitespaces)
            while let character = peek(), Self.linkCharacters.contains(character) { position += 1 }
            link.stroke = body == "==" ? .thick : body == "-." ? .dashed : .solid
        } else {
            guard let stroke = Self.stroke(body) else { return nil }
            link.stroke = stroke
        }
        if take(">") {
            link.end = .arrow
        } else if let character = peek(), character == "x" || character == "o",
                  peek(1) == nil || peek(1) == " " || peek(1) == "|" {
            link.end = character == "x" ? .cross : .circle
            position += 1
        }
        if link.start != nil, link.end == nil { return nil }
        if link.text == nil {
            skipSpaces()
            if take("|") {
                let textStart = position
                while let character = peek(), character != "|" { position += 1 }
                guard !atEnd else { return nil }
                link.text = Self.unquoted(String(characters[textStart..<position])
                    .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                position += 1
            }
        }
        if link.text?.isEmpty == true { link.text = nil }
        return link
    }

    /// A link's line from its characters: nil (wrapped in `.some`) for `~~~`, which is
    /// not drawn; nil for anything that is not a link.
    static func stroke(_ body: String) -> MermaidDiagram.Stroke?? {
        if body.count >= 2, body.allSatisfy({ $0 == "-" }) { return .some(.solid) }
        if body.count >= 2, body.allSatisfy({ $0 == "=" }) { return .some(.thick) }
        if body.count >= 3, body.allSatisfy({ $0 == "~" }) { return .some(nil) }
        if body.count >= 3, body.first == "-", body.last == "-",
           body.dropFirst().dropLast().allSatisfy({ $0 == "." }) { return .some(.dashed) }
        return nil
    }
}

// MARK: - Sequence diagram

struct MermaidSequence {
    struct Participant {
        var id: String
        var lines: [String]
    }

    enum Event {
        case message(from: Int, to: Int, lines: [String], dashed: Bool,
                     start: MermaidDiagram.HeadKind?, end: MermaidDiagram.HeadKind?)
        case note(Int, Int?, side: NoteSide, lines: [String])
        case open(kind: String, lines: [String])
        case divider(lines: [String])
        case close
    }

    enum NoteSide { case left, right, over }

    var participants: [Participant] = []
    var events: [Event] = []
    var index: [String: Int] = [:]

    static let frames: Set<String> = ["loop", "alt", "opt", "par", "critical", "break", "rect"]
    static let dividers: Set<String> = ["else", "and", "option"]
    static let ignored: Set<String> = ["activate", "deactivate", "title", "title:", "accTitle:", "accDescr:"]
    static let refused: [String: String] = [
        "box": "boxes around participants", "create": "created participants", "destroy": "destroyed participants",
        "link": "participant links", "links": "participant links", "properties": "participant properties",
        "details": "participant details",
    ]
    /// Longest first, so `-->>` is not read as `-->`.
    static let arrows: [(text: String, dashed: Bool, start: MermaidDiagram.HeadKind?, end: MermaidDiagram.HeadKind?)] = [
        ("<<-->>", true, .arrow, .arrow), ("<<->>", false, .arrow, .arrow),
        ("-->>", true, nil, .arrow), ("->>", false, nil, .arrow),
        ("--x", true, nil, .cross), ("-x", false, nil, .cross),
        ("--)", true, nil, .open), ("-)", false, nil, .open),
        ("-->", true, nil, nil), ("->", false, nil, nil),
    ]

    static func read(_ statements: MermaidStatements) -> Result<MermaidSequence, MermaidProblem> {
        var diagram = MermaidSequence()
        var numbered = false
        var number = 0
        var depth = 0
        for statement in statements.lines.dropFirst() {
            let text = statement.text
            let first = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let rest = text.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
            let word = first.lowercased()
            if let what = refused[word] { return .failure(.unsupported(what)) }
            if ignored.contains(first) { continue }
            if word == "autonumber" { numbered = true; continue }
            if word == "participant" || word == "actor" {
                let parts = rest.components(separatedBy: " as ")
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty else { return .failure(.unreadable(line: statement.line, text: text)) }
                let shown = parts.count > 1 ? parts.dropFirst().joined(separator: " as ").trimmingCharacters(in: .whitespaces) : id
                if let known = diagram.index[id] {
                    diagram.participants[known].lines = MermaidDiagram.textLines(shown)
                } else {
                    diagram.index[id] = diagram.participants.count
                    diagram.participants.append(Participant(id: id, lines: MermaidDiagram.textLines(shown)))
                }
                continue
            }
            if word == "note" {
                guard let note = diagram.note(rest) else { return .failure(.unreadable(line: statement.line, text: text)) }
                diagram.events.append(note)
                continue
            }
            if frames.contains(word) {
                depth += 1
                diagram.events.append(.open(kind: word, lines: word == "rect" ? [] : MermaidDiagram.textLines(rest)))
                continue
            }
            if dividers.contains(word) {
                guard depth > 0 else { return .failure(.unreadable(line: statement.line, text: text)) }
                diagram.events.append(.divider(lines: MermaidDiagram.textLines(rest)))
                continue
            }
            if word == "end" {
                guard depth > 0 else { return .failure(.unreadable(line: statement.line, text: text)) }
                depth -= 1
                diagram.events.append(.close)
                continue
            }
            guard var message = diagram.message(text) else {
                return .failure(.unreadable(line: statement.line, text: text))
            }
            if numbered, case .message(let from, let to, let lines, let dashed, let start, let end) = message {
                number += 1
                var numberedLines = lines.isEmpty ? [""] : lines
                numberedLines[0] = "\(number). " + numberedLines[0]
                message = .message(from: from, to: to, lines: numberedLines, dashed: dashed, start: start, end: end)
            }
            diagram.events.append(message)
            if diagram.events.count > MermaidDiagram.elementLimit * 2 { return .failure(.tooBig) }
        }
        for _ in 0..<depth { diagram.events.append(.close) }
        if diagram.participants.isEmpty { return .failure(.empty) }
        if diagram.participants.count > MermaidDiagram.elementLimit / 10 { return .failure(.tooBig) }
        return .success(diagram)
    }

    private mutating func participant(_ id: String) -> Int {
        if let known = index[id] { return known }
        index[id] = participants.count
        participants.append(Participant(id: id, lines: MermaidDiagram.textLines(id)))
        return participants.count - 1
    }

    /// `A->>B: words`, with a `+` or `-` before B for an activation, which is not drawn.
    private mutating func message(_ text: String) -> Event? {
        let characters = Array(text)
        for position in characters.indices {
            for arrow in Self.arrows {
                let token = Array(arrow.text)
                guard position + token.count <= characters.count,
                      Array(characters[position..<position + token.count]) == token else { continue }
                let from = String(characters[..<position]).trimmingCharacters(in: .whitespaces)
                var rest = String(characters[(position + token.count)...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("+") || rest.hasPrefix("-") { rest.removeFirst() }
                let colon = rest.firstIndex(of: ":")
                let to = String(colon.map { rest[..<$0] } ?? rest[...]).trimmingCharacters(in: .whitespaces)
                let words = colon.map { String(rest[rest.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
                guard !from.isEmpty, !to.isEmpty else { return nil }
                return .message(from: participant(from), to: participant(to),
                                lines: words.isEmpty ? [] : MermaidDiagram.textLines(words),
                                dashed: arrow.dashed, start: arrow.start, end: arrow.end)
            }
        }
        return nil
    }

    /// `right of A: words`, `left of A: words`, `over A: words`, `over A,B: words`.
    private mutating func note(_ text: String) -> Event? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let place = text[..<colon].trimmingCharacters(in: .whitespaces)
        let words = MermaidDiagram.textLines(String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        let lower = place.lowercased()
        let side: NoteSide
        let names: String
        if lower.hasPrefix("right of ") {
            side = .right; names = String(place.dropFirst(9))
        } else if lower.hasPrefix("left of ") {
            side = .left; names = String(place.dropFirst(8))
        } else if lower.hasPrefix("over ") {
            side = .over; names = String(place.dropFirst(5))
        } else {
            return nil
        }
        let ids = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = ids.first, ids.count <= 2 else { return nil }
        let a = participant(first)
        let b = ids.count == 2 ? participant(ids[1]) : nil
        return .note(a, side == .over ? b : nil, side: side, lines: words)
    }

    // MARK: Layout

    /// Participants in columns, spaced so every message's words fit between its two;
    /// then each message, note and frame a row of its own, down the page.
    func laidOut() -> MermaidDiagram {
        let count = participants.count
        let headSizes = participants.map { participant -> (width: Double, height: Double) in
            let text = MermaidDiagram.measure(participant.lines)
            return (max(text.width + 24, 90), text.height + 16)
        }
        let headHeight = headSizes.map(\.height).max() ?? 0
        var gaps = (0..<max(0, count - 1)).map { headSizes[$0].width / 2 + headSizes[$0 + 1].width / 2 + 30 }
        var needs: [(low: Int, high: Int, room: Double)] = []
        for event in events {
            switch event {
            case .message(let from, let to, let lines, _, _, _):
                let width = MermaidDiagram.measure(lines).width
                if from == to {
                    needs.append((from, from + 1, width + 44))
                } else {
                    needs.append((min(from, to), max(from, to), width + 30))
                }
            case .note(let a, let b, let side, let lines):
                let width = MermaidDiagram.measure(lines).width + 16
                switch side {
                case .right: needs.append((a, a + 1, width + 20))
                case .left: needs.append((a - 1, a, width + 20))
                case .over:
                    if let b { needs.append((min(a, b), max(a, b), width - 50)) }
                }
            default: break
            }
        }
        // By span, then as written: the page sorts them the same way.
        let ordered = needs.enumerated().sorted { ($0.element.high - $0.element.low, $0.offset) < ($1.element.high - $1.element.low, $1.offset) }
        for need in ordered.map(\.element) {
            // Past either end there is nothing to push aside: the frame grows to fit.
            if need.low >= 0, need.high < count, need.high > need.low {
                let have = gaps[need.low..<need.high].reduce(0, +)
                if have < need.room { gaps[need.high - 1] += need.room - have }
            }
        }
        var xs = [0.0]
        for gap in gaps { xs.append(xs[xs.count - 1] + gap) }

        var boxes: [MermaidDiagram.Box] = []
        var lines: [MermaidDiagram.Line] = []
        var labels: [MermaidDiagram.Label] = []
        var frameBoxes: [MermaidDiagram.Box] = []

        struct OpenFrame {
            var kind: String
            var lines: [String]
            var top: Double
            var low = Double.infinity
            var high = -Double.infinity
            var dividers: [(y: Double, lines: [String])] = []
        }
        var open: [OpenFrame] = []
        func reach(_ low: Double, _ high: Double) {
            for index in open.indices {
                open[index].low = min(open[index].low, low)
                open[index].high = max(open[index].high, high)
            }
        }

        var y = headHeight + 24
        let lineHeight = MermaidDiagram.lineHeight
        for event in events {
            switch event {
            case .message(let from, let to, let words, let dashed, let start, let end):
                let size = MermaidDiagram.measure(words)
                let stroke: MermaidDiagram.Stroke = dashed ? .dashed : .solid
                if from == to {
                    let x = xs[from]
                    let tall = max(size.height, 24)
                    let points: [MermaidDiagram.Point] = [.init(x: x, y: y), .init(x: x + 30, y: y),
                                                          .init(x: x + 30, y: y + tall), .init(x: x + 2, y: y + tall)]
                    var heads: [MermaidDiagram.Head] = []
                    if let end { heads += MermaidDiagram.head(end, at: points[3], from: points[2]) }
                    lines.append(.init(points: points, stroke: stroke, heads: heads))
                    if !words.isEmpty { labels.append(MermaidDiagram.leadingLabel(x: x + 38, centreY: y + tall / 2, words)) }
                    reach(x, x + 38 + size.width)
                    y += tall + 18
                } else {
                    let middle = (xs[from] + xs[to]) / 2
                    if !words.isEmpty {
                        labels.append(MermaidDiagram.label(centreX: middle, centreY: y + size.height / 2, words))
                    }
                    let arrowY = y + size.height + 4
                    let a = MermaidDiagram.Point(x: xs[from], y: arrowY), b = MermaidDiagram.Point(x: xs[to], y: arrowY)
                    var heads: [MermaidDiagram.Head] = []
                    if let end { heads += MermaidDiagram.head(end, at: b, from: a) }
                    if let start { heads += MermaidDiagram.head(start, at: a, from: b) }
                    lines.append(.init(points: [a, b], stroke: stroke, heads: heads))
                    reach(min(a.x, b.x, middle - size.width / 2), max(a.x, b.x, middle + size.width / 2))
                    y = arrowY + 18
                }
            case .note(let a, let b, let side, let words):
                let size = MermaidDiagram.measure(words)
                let width = size.width + 16, height = size.height + 12
                let left: Double
                var noteWidth = width
                switch side {
                case .right: left = xs[a] + 10
                case .left: left = xs[a] - 10 - width
                case .over:
                    if let b {
                        let low = min(xs[a], xs[b]) - 25, high = max(xs[a], xs[b]) + 25
                        noteWidth = max(high - low, width)
                        left = (low + high) / 2 - noteWidth / 2
                    } else {
                        noteWidth = max(width, 80)
                        left = xs[a] - noteWidth / 2
                    }
                }
                boxes.append(.init(x: left, y: y, width: noteWidth, height: height, shape: .note))
                labels.append(MermaidDiagram.label(centreX: left + noteWidth / 2, centreY: y + height / 2, words))
                reach(left, left + noteWidth)
                y += height + 14
            case .open(let kind, let words):
                open.append(OpenFrame(kind: kind, lines: words, top: y))
                y += 28
            case .divider(let words):
                open[open.count - 1].dividers.append((y, words))
                y += 28
            case .close:
                let frame = open.removeLast()
                let pad = 12.0
                var low = frame.low, high = frame.high
                if low == .infinity {
                    low = (xs.first ?? 0) - (headSizes.first?.width ?? 0) / 2 + pad
                    high = (xs.last ?? 0) + (headSizes.last?.width ?? 0) / 2 - pad
                }
                let left = low - pad, right = max(high + pad, left + Double(frame.kind.count + 3) * MermaidDiagram.characterWidth
                                                   + MermaidDiagram.measure(frame.lines).width + 12)
                frameBoxes.append(.init(x: left, y: frame.top, width: right - left, height: y + 2 - frame.top, shape: .frame))
                if frame.kind != "rect" {
                    let title = frame.lines.first.map { $0.isEmpty ? frame.kind : "\(frame.kind) [\($0)]" } ?? frame.kind
                    labels.append(MermaidDiagram.leadingLabel(x: left + 6, centreY: frame.top + 4 + lineHeight / 2, [title]))
                }
                for divider in frame.dividers {
                    lines.append(.init(points: [.init(x: left, y: divider.y), .init(x: right, y: divider.y)],
                                       stroke: .dashed, heads: []))
                    if let words = divider.lines.first, !words.isEmpty {
                        labels.append(MermaidDiagram.leadingLabel(x: left + 6, centreY: divider.y + 4 + lineHeight / 2, ["[\(words)]"]))
                    }
                }
                reach(left, right)
                y += 14
            }
        }
        let bottom = y + 6
        var lifelines: [MermaidDiagram.Line] = []
        for (column, participant) in participants.enumerated() {
            let size = headSizes[column]
            for top in [0, bottom] {
                boxes.append(.init(x: xs[column] - size.width / 2, y: top + (headHeight - size.height) / 2,
                                   width: size.width, height: size.height, shape: .rectangle))
                labels.append(MermaidDiagram.label(centreX: xs[column], centreY: top + headHeight / 2, participant.lines))
            }
            lifelines.append(.init(points: [.init(x: xs[column], y: headHeight), .init(x: xs[column], y: bottom)],
                                   stroke: .dashed, heads: []))
        }
        let messages = events.filter { if case .message = $0 { return true } else { return false } }.count
        let summary = "Sequence diagram · \(messages) \(messages == 1 ? "message" : "messages")"
        return MermaidDiagram.framed(kind: .sequence, boxes: frameBoxes + boxes, lines: lifelines + lines,
                                     labels: labels, summary: summary)
    }
}
