import Foundation
import Testing

/// Paper v2's one icon set (#4976): `design/icons.json` against what `scripts/design.sh icons`
/// made from it, and the Mac's views against SF Symbols drawn around the set. A source scan, as
/// `DesignTokensTests` is: neither app has a test target. `scripts/design.sh icons --check`
/// checks the symbols' shapes as well, but it fetches Lucide, so it is not run here.
@Suite("Lucide icons")
struct LucideIconsTests {
    static let root = DesignTokensTests.root

    struct Icon: Decodable { let lucide: String; let meaning: String; let sf: [String] }
    struct Spec: Decodable { let icons: [Icon] }

    static func spec() throws -> Spec {
        try JSONDecoder().decode(Spec.self, from: Data(contentsOf: root.appending(path: "design/icons.json")))
    }

    @Test("every icon has its symbol in Icons.xcassets, and only those do")
    func everyIconHasASymbol() throws {
        let icons = try Self.spec().icons
        let catalogue = Self.root.appending(path: "Shared/UI/Icons.xcassets")
        let sets = try FileManager.default.contentsOfDirectory(atPath: catalogue.path(percentEncoded: false))
            .filter { $0.hasSuffix(".symbolset") }
        #expect(Set(sets) == Set(icons.map { "lucide.\($0.lucide).symbolset" }),
                "run scripts/design.sh icons and commit what it writes")
        #expect(Set(icons.map(\.lucide)).count == icons.count, "an icon is listed twice in design/icons.json")
    }

    @Test("LucideIcons.swift maps each SF Symbol as design/icons.json does")
    func tableIsFresh() throws {
        let table = try String(contentsOf: Self.root.appending(path: "Shared/UI/LucideIcons.swift"), encoding: .utf8)
        var seen: Set<String> = []
        for icon in try Self.spec().icons {
            #expect(!icon.meaning.isEmpty, "\(icon.lucide) has no meaning")
            for sf in icon.sf {
                #expect(seen.insert(sf).inserted, "\(sf) means two icons")
                #expect(table.contains("\"\(sf)\": \"lucide.\(icon.lucide)\""),
                        "LucideIcons.swift is stale for \(sf): run scripts/design.sh icons")
            }
        }
    }

    /// A view draws an icon through `Image(icon:)` and its kin, so the Mac and the Remote draw Lucide's; a bare
    /// SF Symbol would draw Apple's set beside it.
    @Test("the Mac's and the Remote's views draw icons through Image(icon:)")
    func viewsDrawThroughTheSet() throws {
        let allowed = ["Shared/UI/PaperIcon.swift", "Shared/UI/WorkingMarks.swift"]
        let pattern = /Image\(systemName:|NSImage\(systemSymbolName:|(Label|Button|Menu|Toggle|ContentUnavailableView)\([^\n]*\bsystemImage:/
        var found: [String] = []
        for folder in ["App/Sources", "Remote/Sources", "Shared/UI"] {
            let base = Self.root.appending(path: folder)
            let files = FileManager.default.enumerator(atPath: base.path(percentEncoded: false))?
                .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
            for file in files where !allowed.contains("\(folder)/\(file)") {
                let text = try String(contentsOf: base.appending(path: file), encoding: .utf8)
                for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains(pattern) {
                    found.append("\(folder)/\(file):\(n + 1)")
                }
            }
        }
        #expect(found.isEmpty, "use Image(icon:), Label(_:icon:) or Button(_:icon:): \(found)")
    }
}
