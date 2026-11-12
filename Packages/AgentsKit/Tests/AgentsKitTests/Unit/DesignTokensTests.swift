import Foundation
import Testing

/// The Swift look against `design/tokens.json`, the design system's one source (#4602). The
/// CSS token files are made from it (`scripts/design.sh gen`); `Paper.swift`, `StateTint.swift`,
/// `TypeScale.swift` and the AccentColor assets stay written by hand, and this says what to
/// change in them, as `WireSchemaTests` does for the wire.
///
/// A source scan, as `ConsistencyTests` is: neither app has a test target. Each token names
/// where Swift holds it in `dev.agentloops.swift` (a colour, a radius) or which text style
/// each platform draws it in (`dev.agentloops.mac`, `dev.agentloops.ios`).
@Suite("Design tokens")
struct DesignTokensTests {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    struct Token {
        var path: String
        var fields: [String: Any]
        var extensions: [String: Any] { fields["$extensions"] as? [String: Any] ?? [:] }
        func string(_ key: String) -> String? { extensions[key] as? String }
    }

    /// Every token in the file, in its order, with its path (`color.tint.attention`).
    static func tokens() throws -> [Token] {
        let data = try Data(contentsOf: root.appending(path: "design/tokens.json"))
        let tree = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var found: [Token] = []
        func walk(_ node: [String: Any], _ path: [String]) {
            for key in node.keys.sorted() where !key.hasPrefix("$") {
                guard let child = node[key] as? [String: Any] else { continue }
                if child["$value"] != nil {
                    found.append(Token(path: (path + [key]).joined(separator: "."), fields: child))
                } else {
                    walk(child, path + [key])
                }
            }
        }
        walk(tree, [])
        return found
    }

    static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// `0xF7F8F9` from `#f7f8f9`.
    static func hex(_ css: String) -> String { "0x" + css.dropFirst().uppercased() }

    /// The `(light, dark)` pairs that `static let <name> = …(light: 0x…, dark: 0x…)` holds in
    /// a source, one per declaration (the Mac's and the phone's `paperSelection` are two).
    static func pairs(named name: String, in text: String) -> [(light: String, dark: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.contains("static let \(name) = "),
                  let light = line.range(of: "light: "), let dark = line.range(of: "dark: ")
            else { return nil }
            func value(after range: Range<String.Index>) -> String {
                String(line[range.upperBound...].prefix { $0 == "x" || $0.isHexDigit }).uppercased()
                    .replacingOccurrences(of: "0X", with: "0x")
            }
            return (value(after: light), value(after: dark))
        }
    }

    /// What is wrong with one colour token against its Swift source, or nil when they agree.
    static func colourMismatch(_ token: Token, file: String, name: String, text: String) -> [String] {
        guard let light = token.fields["$value"] as? String, let dark = token.string("dev.agentloops.dark") else {
            return ["design/tokens.json: \(token.path) has no light and dark value"]
        }
        let want = (light: hex(light), dark: hex(dark))
        let found = pairs(named: name, in: text)
        if found.isEmpty {
            return ["\(file): no `static let \(name) = …(light:, dark:)` for \(token.path)"]
        }
        return found.compactMap { pair in
            pair == want ? nil : "\(file): \(name) is light \(pair.light), dark \(pair.dark); "
                + "design/tokens.json's \(token.path) is light \(want.light), dark \(want.dark): change \(file)"
        }
    }

    /// The text between `start` and the next `end` after it in a source: one `switch` or one
    /// dictionary literal.
    static func block(_ text: String, from start: String, to end: String) -> Substring? {
        guard let open = text.range(of: start), let close = text[open.upperBound...].range(of: end) else { return nil }
        return text[open.upperBound..<close.lowerBound]
    }

    /// The `0x…` after `<key>: ` in a block (`case .green: 0x1A7F37`, `.keyword: 0x2B4C8C,`).
    static func keyed(_ key: String, in block: Substring?) -> String? {
        guard let block, let found = block.range(of: "\(key): 0x") else { return nil }
        return "0x" + String(block[found.upperBound...].prefix { $0.isHexDigit }).uppercased()
    }

    /// What is wrong with a colour token whose Swift home holds its light and dark apart, in a
    /// dictionary (`InkValues`); nil when they agree.
    static func splitMismatch(_ token: Token, file: String, key: String, light: Substring?, dark: Substring?) -> [String] {
        guard let want = token.fields["$value"] as? String, let wantDark = token.string("dev.agentloops.dark") else {
            return ["design/tokens.json: \(token.path) has no light and dark value"]
        }
        let found = (light: keyed(key, in: light), dark: keyed(key, in: dark))
        guard found.light == hex(want), found.dark == hex(wantDark) else {
            return ["\(file): \(key) is light \(found.light ?? "missing"), dark \(found.dark ?? "missing"); "
                + "design/tokens.json's \(token.path) is light \(hex(want)), dark \(hex(wantDark)): change \(file)"]
        }
        return []
    }

    @Test("Paper's, StateTint's and the code inks' colours are the tokens'")
    func colours() throws {
        let paper = try Self.source("Shared/UI/Paper.swift")
        let tints = try Self.source("Shared/UI/StateTint.swift")
        let inks = try Self.source("Packages/CodeText/Sources/CodeText/InkValues.swift")
        var wrong: [String] = []
        var checked = 0
        for token in try Self.tokens() where token.path.hasPrefix("color.") {
            guard let swift = token.string("dev.agentloops.swift") else {
                wrong.append("design/tokens.json: \(token.path) names no Swift home (dev.agentloops.swift)")
                continue
            }
            if swift == "AccentColor.colorset" { continue }   // `accent()`, below
            if swift.hasPrefix("none:") { continue }          // the web page's alone; the words say why
            let parts = swift.split(separator: ".").map(String.init)
            switch parts.first {
            case "InkValues":
                let file = "Packages/CodeText/Sources/CodeText/InkValues.swift"
                wrong += Self.splitMismatch(token, file: file, key: ".\(parts.last ?? swift)",
                                            light: Self.block(inks, from: "static let light: [CodeRole: UInt32] = [", to: "]"),
                                            dark: Self.block(inks, from: "static let dark: [CodeRole: UInt32] = [", to: "]"))
                checked += 1
                continue
            default: break
            }
            let (file, text, name) = parts.first == "StateTint"
                ? ("Shared/UI/StateTint.swift", tints, parts.last ?? swift)
                : ("Shared/UI/Paper.swift", paper, parts.last ?? swift)
            wrong += Self.colourMismatch(token, file: file, name: name, text: text)
            if parts.first == "Paper", let alpha = token.extensions["dev.agentloops.alpha"] as? Double,
               !text.contains(".opacity(\(String(format: "%.2f", alpha)))") {
                wrong.append("\(file): \(name)'s opacity is not design/tokens.json's \(alpha)")
            }
            checked += 1
        }
        // The AppKit and UIKit copies of the ground and the ink (the terminals').
        let byPath = Dictionary(try Self.tokens().map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, path) in [("paperGround", "color.ground"), ("paperInk", "color.ink")] {
            let token = try #require(byPath[path])
            wrong += Self.colourMismatch(token, file: "Shared/UI/Paper.swift", name: name, text: paper)
        }
        #expect(checked >= 34, "the scan found \(checked) colours; it should find every Paper, StateTint and InkValues one")
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
    }

    @Test("The AccentColor assets are the accent token")
    func accent() throws {
        let token = try #require(try Self.tokens().first { $0.path == "color.accent" })
        let light = try #require(token.fields["$value"] as? String)
        let dark = try #require(token.string("dev.agentloops.dark"))
        for app in ["App", "Remote"] {
            let file = "\(app)/Resources/Assets.xcassets/AccentColor.colorset/Contents.json"
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appending(path: file)))
            let colours = try #require((object as? [String: Any])?["colors"] as? [[String: Any]])
            for entry in colours {
                let isDark = (entry["appearances"] as? [[String: Any]])?.contains { $0["value"] as? String == "dark" } ?? false
                let components = try #require((entry["color"] as? [String: Any])?["components"] as? [String: String])
                let found = ["red", "green", "blue"].map { (components[$0] ?? "?").dropFirst(2).uppercased() }.joined()
                let want = Self.hex(isDark ? dark : light).dropFirst(2)
                #expect(found == want, "\(file): the \(isDark ? "dark" : "light") accent is #\(found); design/tokens.json's color.accent is #\(want)")
            }
        }
    }

    @Test("Paper's radii are the tokens'")
    func radii() throws {
        let paper = try Self.source("Shared/UI/Paper.swift")
        for token in try Self.tokens() where token.path.hasPrefix("radius.") {
            guard let swift = token.string("dev.agentloops.swift"), let name = swift.split(separator: ".").last else { continue }
            let value = try #require((token.fields["$value"] as? [String: Any])?["value"] as? Int)
            #expect(paper.contains("static let \(name): CGFloat = \(value)\n"),
                    "Shared/UI/Paper.swift: \(swift) is not design/tokens.json's \(token.path), \(value)")
        }
    }

    /// The text style a step draws in on one platform, from TypeScale's `font` switch:
    /// `.system(.title3)` and `.body.monospaced()` are `.title3` and `.body`.
    static func styles(in block: Substring) -> [String: String] {
        var found: [String: String] = [:]
        for line in block.components(separatedBy: "\n") {
            guard let caseRange = line.range(of: "case ."), let returnRange = line.range(of: "return ") else { continue }
            let step = String(line[caseRange.upperBound...].prefix { $0.isLetter })
            var style = String(line[returnRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            style = style.replacingOccurrences(of: ".system(", with: "").replacingOccurrences(of: ".monospaced()", with: "")
            found[step] = String(style.prefix { $0 != ")" })
        }
        return found
    }

    @Test("TypeScale's steps are the tokens'")
    func typeSteps() throws {
        let text = try Self.source("Shared/UI/TypeScale.swift")
        let body = try #require(text.range(of: "var font: Font {")).upperBound
        let rest = text[body...]
        let split = try #require(rest.range(of: "#else"))
        let end = try #require(rest.range(of: "#endif"))
        let mac = Self.styles(in: rest[..<split.lowerBound])
        let ios = Self.styles(in: rest[split.upperBound..<end.lowerBound])
        var checked = 0
        for token in try Self.tokens() where token.path.hasPrefix("type.") && !token.path.hasPrefix("type.display") {
            let step = String(token.path.dropFirst("type.".count))
            for (platform, styles) in [("mac", mac), ("ios", ios)] {
                let want = token.string("dev.agentloops.\(platform)")
                #expect(styles[step] == want,
                        "Shared/UI/TypeScale.swift: \(step) on \(platform) is \(styles[step] ?? "missing"); design/tokens.json's \(token.path) is \(want ?? "missing")")
            }
            checked += 1
        }
        #expect(checked == 5)
    }

    /// A switch's light and dark are read apart, and a wrong one is named with the fix.
    @Test("A tone that disagrees is named with the value to change")
    func splitMismatchIsReported() {
        let token = Token(path: "color.forge.open", fields: ["$value": "#1a7f37", "$extensions": ["dev.agentloops.dark": "#3fb950"]])
        let light: Substring = "\n            case .green: 0x1A7F37\n"
        let right: Substring = "\n            case .green: 0x3FB950\n"
        let wrongDark: Substring = "\n            case .green: 0x2EA043\n"
        #expect(Self.splitMismatch(token, file: "WorkLook.swift", key: "case .green", light: light, dark: right).isEmpty)
        #expect(Self.splitMismatch(token, file: "WorkLook.swift", key: "case .green", light: light, dark: wrongDark)
            == ["WorkLook.swift: case .green is light 0x1A7F37, dark 0x2EA043; design/tokens.json's color.forge.open is light 0x1A7F37, dark 0x3FB950: change WorkLook.swift"])
        #expect(Self.splitMismatch(token, file: "WorkLook.swift", key: "case .green", light: nil, dark: right).count == 1)
    }

    /// The scan bites: a wrong value in a source is found, and named with the fix.
    @Test("A colour that disagrees is named with the value to change")
    func mismatchIsReported() {
        let token = Token(path: "color.ground", fields: ["$value": "#f7f8f9", "$extensions": ["dev.agentloops.dark": "#1c1d20"]])
        let wrong = "    static let ground = Color(light: 0xFFFFFF, dark: 0x1C1D20)\n"
        let found = Self.colourMismatch(token, file: "Paper.swift", name: "ground", text: wrong)
        #expect(found == ["Paper.swift: ground is light 0xFFFFFF, dark 0x1C1D20; design/tokens.json's color.ground is light 0xF7F8F9, dark 0x1C1D20: change Paper.swift"])
        let right = "    static let ground = Color(light: 0xF7F8F9, dark: 0x1C1D20)\n"
        #expect(Self.colourMismatch(token, file: "Paper.swift", name: "ground", text: right).isEmpty)
        #expect(Self.colourMismatch(token, file: "Paper.swift", name: "ground", text: "").count == 1)
    }
}
