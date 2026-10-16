import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The app's own tools as Packages/Wire/app-tools.json has them (#1136): what a host in
/// another language offers its agents, names, descriptions and schemas, word for word. The
/// tools stay written in AppService; this keeps the file the same as them. After a change to
/// a tool, run this test with AGENTS_WRITE_APP_TOOLS=1, then `scripts/wire.sh gen`.
@Suite("App tools file")
struct AppToolsFileTests {
    static let file = WireSchemaTests.wire.appending(path: "app-tools.json")

    static func made() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.array(AppService.tools(movesItself: true))) + Data("\n".utf8)
    }

    @Test func theFileIsTodaysTools() throws {
        let made = try Self.made()
        if ProcessInfo.processInfo.environment["AGENTS_WRITE_APP_TOOLS"] == "1" {
            try made.write(to: Self.file)
        }
        #expect(try Data(contentsOf: Self.file) == made,
                "Packages/Wire/app-tools.json is not today's tools: run this test with AGENTS_WRITE_APP_TOOLS=1, then scripts/wire.sh gen")
    }
}
