import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The app's own tools and events as Packages/Wire/app-tools.json and event-catalogue.json
/// have them (#1136): what a host in another language offers its agents, names, descriptions
/// and schemas, word for word. The tools stay written in AppService and the events in
/// EventCatalogue; this keeps the files the same as them. After a change to either, run this
/// test with AGENTS_WRITE_APP_TOOLS=1, then `scripts/wire.sh gen`.
@Suite("App tools file")
struct AppToolsFileTests {
    static func encoded(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    /// Every event kind, with what a wait may narrow it by, and the list an agent reads.
    static var catalogue: JSONValue {
        let kinds: [JSONValue] = EventCatalogue.all.map { kind in
            ["name": .string(kind.name), "scope": .string(kind.scope.rawValue), "macOnly": .bool(kind.isMacOnly),
             "meaning": .string(kind.meaning), "inputSchema": kind.inputSchema, "payloadSchema": kind.payloadSchema]
        }
        return ["kinds": .array(kinds), "listText": .string(EventList.text())]
    }

    static func check(_ name: String, _ made: Data) throws {
        let file = WireSchemaTests.wire.appending(path: name)
        if ProcessInfo.processInfo.environment["AGENTS_WRITE_APP_TOOLS"] == "1" {
            try made.write(to: file)
        }
        #expect(try Data(contentsOf: file) == made,
                "Packages/Wire/\(name) is not today's: run this test with AGENTS_WRITE_APP_TOOLS=1, then scripts/wire.sh gen")
    }

    @Test func theFileIsTodaysTools() throws {
        try Self.check("app-tools.json", Self.encoded(.array(AppService.tools(movesItself: true))))
    }

    @Test func theFileIsTodaysEvents() throws {
        try Self.check("event-catalogue.json", Self.encoded(Self.catalogue))
    }
}
