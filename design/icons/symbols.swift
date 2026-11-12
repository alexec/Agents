// Make the Mac's and the Remote's Lucide symbols (#4976; specs/4926-paper-v2/spec.md, Icons).
//
//   swift design/icons/symbols.swift design/icons.json <lucide icons dir> <out dir>
//
// scripts/design.sh icons runs it. For each icon in design/icons.json it reads Lucide's SVG,
// strokes every shape at icons.json's stroke with round caps and joins (CoreGraphics), joins
// the outlines into one shape with no overlaps (CGPath.normalized), and writes a symbol image
// template, so `Image("lucide.x")` is a symbol: it takes the text's size, scale and colour.
// It writes OUT/Shared/UI/Icons.xcassets and OUT/Shared/UI/LucideIcons.swift.
//
// Why our own code: SwiftDraw (Zlib) and picosvg (Apache-2.0) do this, but each is outside code
// that this Mac's agents may not build and run. CoreGraphics does the stroke and the union; only
// the SVG shape reader below is ours, and it reads only what Lucide's icons use: path (M L H V C
// S Q T A Z, absolute and relative), circle, ellipse, rect (rx), line, polyline and polygon.
import CoreGraphics
import Foundation

struct Spec: Decodable {
    struct Lucide: Decodable { let version: String }
    struct Icon: Decodable { let lucide: String; let group: String; let meaning: String; let sf: [String] }
    let lucide: Lucide
    let stroke: Double
    let icons: [Icon]
}

// MARK: The SVG shapes

/// One shape of an icon: its path in Lucide's 24 by 24 units, and whether it is filled as well.
struct Shape { let path: CGPath; let filled: Bool }

final class Reader: NSObject, XMLParserDelegate {
    var shapes: [Shape] = []
    var failure: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        func n(_ key: String, _ fallback: Double = 0) -> CGFloat { CGFloat(Double(a[key] ?? "") ?? fallback) }
        let path = CGMutablePath()
        switch name {
        case "svg": return
        case "path":
            do { var data = PathData(a["d"] ?? ""); try data.add(to: path) } catch { failure = "\(error)"; return }
        case "circle":
            let r = n("r")
            path.addEllipse(in: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r))
        case "ellipse":
            path.addEllipse(in: CGRect(x: n("cx") - n("rx"), y: n("cy") - n("ry"), width: 2 * n("rx"), height: 2 * n("ry")))
        case "rect":
            let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
            let rx = a["rx"] != nil ? n("rx") : n("ry"), ry = a["ry"] != nil ? n("ry") : rx
            if rx > 0 {
                path.addRoundedRect(in: rect, cornerWidth: min(rx, rect.width / 2), cornerHeight: min(ry, rect.height / 2))
            } else {
                path.addRect(rect)
            }
        case "line":
            path.move(to: CGPoint(x: n("x1"), y: n("y1")))
            path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
        case "polyline", "polygon":
            let v = numbers(a["points"] ?? "")
            guard v.count >= 4, v.count % 2 == 0 else { failure = "bad points"; return }
            path.move(to: CGPoint(x: v[0], y: v[1]))
            for i in stride(from: 2, to: v.count, by: 2) { path.addLine(to: CGPoint(x: v[i], y: v[i + 1])) }
            if name == "polygon" { path.closeSubpath() }
        default:
            failure = "an element Lucide's reader does not know: <\(name)>"
            return
        }
        shapes.append(Shape(path: path, filled: (a["fill"] ?? "none") != "none"))
    }
}

func numbers(_ text: String) -> [CGFloat] {
    var data = PathData(text)
    return data.allNumbers()
}

enum PathError: Error, CustomStringConvertible {
    case bad(String)
    var description: String { if case let .bad(s) = self { return "bad path data: \(s)" }; return "" }
}

/// SVG path data, read into a CGPath.
struct PathData {
    let chars: [Character]
    var i = 0
    init(_ text: String) { chars = Array(text) }

    mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i].isNewline || chars[i] == "\t" { i += 1 } }

    mutating func number() -> CGFloat? {
        skip()
        var s = ""
        if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
        var dot = false, exp = false
        while i < chars.count {
            let c = chars[i]
            if c.isNumber { s.append(c) } else if c == ".", !dot, !exp { dot = true; s.append(c) } else if c == "e" || c == "E", !exp {
                exp = true; s.append(c)
                if i + 1 < chars.count, chars[i + 1] == "-" || chars[i + 1] == "+" { i += 1; s.append(chars[i]) }
            } else { break }
            i += 1
        }
        return Double(s).map { CGFloat($0) }
    }

    /// An arc's flag: one digit, which SVG lets touch the next number ("a2 2 0 0010 10").
    mutating func flag() -> CGFloat? {
        skip()
        guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
        defer { i += 1 }
        return chars[i] == "1" ? 1 : 0
    }

    mutating func allNumbers() -> [CGFloat] {
        var out: [CGFloat] = []
        while let v = number() { out.append(v) }
        return out
    }

    mutating func nextIsNumber() -> Bool {
        skip()
        guard i < chars.count else { return false }
        let c = chars[i]
        return c.isNumber || c == "-" || c == "+" || c == "."
    }

    mutating func add(to path: CGMutablePath) throws {
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?, lastQuad: CGPoint?
        var command: Character = " "
        func need(_ v: CGFloat?) throws -> CGFloat { guard let v else { throw PathError.bad("at \(i)") }; return v }
        while true {
            skip()
            guard i < chars.count else { break }
            if chars[i].isLetter { command = chars[i]; i += 1 } else if command == " " { throw PathError.bad("no command") }
            let rel = command.isLowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y) }
            var control: CGPoint?, quad: CGPoint?
            switch command.uppercased().first! {
            case "M":
                current = pt(try need(number()), try need(number())); start = current
                path.move(to: current)
                command = rel ? "l" : "L" // further pairs are lines
            case "L":
                current = pt(try need(number()), try need(number())); path.addLine(to: current)
            case "H":
                let x = try need(number()); current = CGPoint(x: rel ? current.x + x : x, y: current.y); path.addLine(to: current)
            case "V":
                let y = try need(number()); current = CGPoint(x: current.x, y: rel ? current.y + y : y); path.addLine(to: current)
            case "C":
                let c1 = pt(try need(number()), try need(number())), c2 = pt(try need(number()), try need(number()))
                let end = pt(try need(number()), try need(number()))
                path.addCurve(to: end, control1: c1, control2: c2); current = end; control = c2
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = pt(try need(number()), try need(number())), end = pt(try need(number()), try need(number()))
                path.addCurve(to: end, control1: c1, control2: c2); current = end; control = c2
            case "Q":
                let c = pt(try need(number()), try need(number())), end = pt(try need(number()), try need(number()))
                path.addQuadCurve(to: end, control: c); current = end; quad = c
            case "T":
                let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = pt(try need(number()), try need(number()))
                path.addQuadCurve(to: end, control: c); current = end; quad = c
            case "A":
                let rx = try need(number()), ry = try need(number()), rotation = try need(number())
                let large = try need(flag()), sweep = try need(flag())
                let end = pt(try need(number()), try need(number()))
                arc(path, from: current, to: end, rx: rx, ry: ry, degrees: rotation, large: large == 1, sweep: sweep == 1)
                current = end
            case "Z":
                path.closeSubpath(); current = start
                lastControl = nil; lastQuad = nil
                continue
            default:
                throw PathError.bad("command \(command)")
            }
            lastControl = control; lastQuad = quad
            if !nextIsNumber() { command = command == "M" ? "L" : command == "m" ? "l" : command }
        }
    }
}

/// An SVG elliptical arc, from its end points (SVG 1.1, F.6.5) to CoreGraphics' centre form.
func arc(_ path: CGMutablePath, from p1: CGPoint, to p2: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
         degrees: CGFloat, large: Bool, sweep: Bool) {
    if p1 == p2 { return }
    var rx = abs(rx0), ry = abs(ry0)
    if rx == 0 || ry == 0 { path.addLine(to: p2); return }
    let phi = degrees * .pi / 180, c = cos(phi), s = sin(phi)
    let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
    let x1 = c * dx + s * dy, y1 = -s * dx + c * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var k = sqrt(max(0, num / den))
    if large == sweep { k = -k }
    let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
    let cx = c * cx1 - s * cy1 + (p1.x + p2.x) / 2, cy = s * cx1 + c * cy1 + (p1.y + p2.y) / 2
    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a
    }
    let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
    // A unit circle's arc, scaled to the ellipse, turned and moved to its centre
    let t = CGAffineTransform(translationX: cx, y: cy).rotated(by: phi).scaledBy(x: rx, y: ry)
    path.addRelativeArc(center: .zero, radius: 1, startAngle: theta, delta: delta, transform: t)
}

// MARK: The symbol template

/// The guides of a static symbol template (template v3.0): Xcode reads the baselines, the cap
/// lines and the margins by their ids, and the shape from the Symbols group's Regular-M.
let baselineM: CGFloat = 1126, caplineM: CGFloat = 1055.54
/// Lucide's 24 units are 5 template units: a 20-unit circle is 100, about the height of an
/// SF Symbol circle at a point size of 100 (the template's).
let unit: CGFloat = 5
let left: CGFloat = 1390

func template(_ d: String, name: String, version: String) -> String {
    let right = left + 24 * unit
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Lucide \(version) (ISC): \(name). Made by scripts/design.sh icons (#4976); do not edit. -->
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">
     <g id="Notes">
      <text id="template-version" x="3036" y="1933">Template v.3.0</text>
     </g>
     <g id="Guides">
      <line id="Baseline-S" x1="263" x2="3036" y1="696" y2="696"/>
      <line id="Capline-S" x1="263" x2="3036" y1="625.541" y2="625.541"/>
      <line id="Baseline-M" x1="263" x2="3036" y1="\(baselineM)" y2="\(baselineM)"/>
      <line id="Capline-M" x1="263" x2="3036" y1="\(caplineM)" y2="\(caplineM)"/>
      <line id="Baseline-L" x1="263" x2="3036" y1="1556" y2="1556"/>
      <line id="Capline-L" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
      <line id="left-margin-Regular-M" x1="\(left)" x2="\(left)" y1="1030" y2="1151"/>
      <line id="right-margin-Regular-M" x1="\(right)" x2="\(right)" y1="1030" y2="1151"/>
     </g>
     <g id="Symbols">
      <g id="Regular-M">
       <path d="\(d)"/>
      </g>
     </g>
    </svg>

    """
}

func f(_ v: CGFloat) -> String {
    var s = String(format: "%.3f", Double(v))
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

func svgData(_ path: CGPath) -> String {
    var out: [String] = []
    path.applyWithBlock { e in
        let p = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: out.append("M\(f(p[0].x)) \(f(p[0].y))")
        case .addLineToPoint: out.append("L\(f(p[0].x)) \(f(p[0].y))")
        case .addQuadCurveToPoint: out.append("Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))")
        case .addCurveToPoint: out.append("C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))")
        case .closeSubpath: out.append("Z")
        @unknown default: break
        }
    }
    return out.joined(separator: " ")
}

/// The icon's outline in template units: every shape stroked, the filled ones filled, all joined.
func outline(_ shapes: [Shape], stroke: CGFloat) -> CGPath {
    let all = CGMutablePath()
    for shape in shapes {
        all.addPath(shape.path.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10))
        if shape.filled { all.addPath(shape.path) }
    }
    // Lucide's box is 24 units with its middle on the template's: the middle of the cap height
    let middle = baselineM - (baselineM - caplineM) / 2
    let place = CGAffineTransform(translationX: left, y: middle - 12 * unit).scaledBy(x: unit, y: unit)
    return all.normalized(using: .winding).copy(using: [place])!
}

// MARK: Main

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: symbols.swift icons.json <lucide icons dir> <out dir>\n".data(using: .utf8)!)
    exit(2)
}
let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let source = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
let catalogue = out.appendingPathComponent("Shared/UI/Icons.xcassets")
let fm = FileManager.default
try? fm.removeItem(at: catalogue)
try fm.createDirectory(at: catalogue, withIntermediateDirectories: true)
try #"{"info":{"author":"xcode","version":1}}"#.appending("\n").write(to: catalogue.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

var failed = false
for icon in spec.icons {
    let file = source.appendingPathComponent("\(icon.lucide).svg")
    guard let parser = XMLParser(contentsOf: file) else {
        FileHandle.standardError.write("symbols.swift: no Lucide icon \(icon.lucide)\n".data(using: .utf8)!)
        failed = true; continue
    }
    let reader = Reader()
    parser.delegate = reader
    if !parser.parse() || reader.failure != nil || reader.shapes.isEmpty {
        FileHandle.standardError.write("symbols.swift: \(icon.lucide): \(reader.failure ?? parser.parserError.map { "\($0)" } ?? "no shapes")\n".data(using: .utf8)!)
        failed = true; continue
    }
    let name = "lucide.\(icon.lucide)"
    let set = catalogue.appendingPathComponent("\(name).symbolset")
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    let d = svgData(outline(reader.shapes, stroke: CGFloat(spec.stroke)))
    try template(d, name: icon.lucide, version: spec.lucide.version).write(to: set.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
    try """
    {"info":{"author":"xcode","version":1},"symbols":[{"filename":"\(name).svg","idiom":"universal"}]}

    """.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

// The table the clients draw from: an SF Symbol's name, as the model still names an icon, to the
// Lucide symbol that means the same
var swift = """
// Made by scripts/design.sh icons from design/icons.json (#4976); do not edit.
// Lucide \(spec.lucide.version) (ISC), at a \(spec.stroke) stroke.

/// The one icon set (Paper v2): Lucide's symbols in Icons.xcassets, by meaning.
enum LucideIcons {
    /// Lucide's version, pinned in design/icons.json.
    static let version = "\(spec.lucide.version)"

    /// Every symbol in Icons.xcassets.
    static let names: [String] = [

"""
for icon in spec.icons { swift += "        \"lucide.\(icon.lucide)\",\n" }
swift += """
    ]

    /// The Lucide symbol for each SF Symbol it replaces, by meaning.
    static let bySystemName: [String: String] = [

"""
for icon in spec.icons {
    for sf in icon.sf { swift += "        \"\(sf)\": \"lucide.\(icon.lucide)\", // \(icon.meaning)\n" }
}
swift += "    ]\n}\n"
try swift.write(to: out.appendingPathComponent("Shared/UI/LucideIcons.swift"), atomically: true, encoding: .utf8)
exit(failed ? 1 : 0)
