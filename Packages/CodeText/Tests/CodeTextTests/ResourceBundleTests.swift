@testable import CodeText
import Foundation
import Testing

/// The queries' bundle is looked for, not trapped on (#178): `Bundle.module` killed the
/// window when the bundle was missing, and a missing bundle now means plain code.
struct ResourceBundleTests {
    @Test func theBundleIsFoundWhereItIsBuilt() {
        #expect(Grammar.resources != nil)
        #expect(Grammar.queryURL(for: .swift) != nil)
    }

    @Test func aFolderWithoutTheBundleFindsNone() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-codetext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(Grammar.resourceBundle(searching: [empty]) == nil)
    }

    /// No bundle, no query: the Colourer then says the text did not parse, and it shows plain.
    @Test(arguments: CodeLanguage.allCases)
    func aMissingBundleGivesPlainText(language: CodeLanguage) async {
        #expect(Grammar.queryURL(for: language, in: nil) == nil)
        #expect(await QueryCache(bundle: nil).query(for: language) == nil)
    }
}
