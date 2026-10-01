import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Where the Mac's daemon finds Claude once the app has installed it (048): the person's
/// own `npx` first, the app's toolset only when there is none, and only when whole.
@Suite("Finding the app's own Claude on this Mac")
struct AppToolsetDiscoveryTests {
    private func tools(whole: Bool) throws -> URL {
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        let set = tools.appendingPathComponent("claude/abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: set.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: set.appendingPathComponent("bin/npx").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        if whole { FileManager.default.createFile(atPath: set.appendingPathComponent("ok").path, contents: Data()) }
        try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent("claude/current").path,
                                                   withDestinationPath: "abc123")
        return tools
    }

    private func discovery(tools: URL?, npxOnPath: Bool) -> RuntimeDiscovery {
        var d = RuntimeDiscovery(searchPaths: ["/person/bin"]) { path in
            path == "/person/bin/npx" ? npxOnPath : FileManager.default.isExecutableFile(atPath: path)
        }
        d.macToolsHome = tools?.path
        return d
    }

    @Test func theToolsetIsFoundWhenThereIsNoNpx() throws {
        let tools = try tools(whole: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        #expect(discovery(tools: tools, npxOnPath: false).locate(RuntimeCatalog.claude)
                == .available(path: "\(tools.path)/claude/current/bin/npx", supportsResume: false))
    }

    @Test func onlyWithOk() throws {
        let tools = try tools(whole: false)
        defer { try? FileManager.default.removeItem(at: tools) }
        #expect(discovery(tools: tools, npxOnPath: false).locate(RuntimeCatalog.claude)
                == .missing(lookedIn: ["/person/bin"]))
    }

    @Test func thePersonsOwnNpxWins() throws {
        let tools = try tools(whole: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        #expect(discovery(tools: tools, npxOnPath: true).locate(RuntimeCatalog.claude)
                == .available(path: "/person/bin/npx", supportsResume: false))
    }

    @Test func otherRuntimesNeverLookThere() throws {
        let tools = try tools(whole: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        #expect(discovery(tools: tools, npxOnPath: false).locate(RuntimeCatalog.grok) == .missing(lookedIn: ["/person/bin"]))
    }

    /// A runtime that is only ever the app's own copy (047): Codex. Made up here, so the
    /// rule is tested apart from whether the catalog lists Codex yet.
    private let appCopyOnly = Runtime(id: "only", name: "Only", executable: "only-acp", arguments: [],
                                      install: .toolset(runtimeID: "only"), usesAppCopyOnly: true)

    private func onlyTools(whole: Bool) throws -> URL {
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        let set = tools.appendingPathComponent("only/abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: set.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: set.appendingPathComponent("bin/only-acp").path,
                                       contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o700])
        if whole { FileManager.default.createFile(atPath: set.appendingPathComponent("ok").path, contents: Data()) }
        try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent("only/current").path,
                                                   withDestinationPath: "abc123")
        return tools
    }

    @Test func anAppCopyOnlyRuntimeIgnoresTheSameNameOnThePath() throws {
        var d = RuntimeDiscovery(searchPaths: ["/person/bin"]) { $0 == "/person/bin/only-acp" || $0 == "/person/bin/npx" }
        d.macToolsHome = "/nowhere"
        #expect(d.locate(appCopyOnly) == .missing(lookedIn: ["/nowhere/only/current/bin"]))
    }

    @Test func anAppCopyOnlyRuntimeIsItsWholeToolset() throws {
        let tools = try onlyTools(whole: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        var d = RuntimeDiscovery(searchPaths: ["/person/bin"]) { $0 == "/person/bin/only-acp" || FileManager.default.isExecutableFile(atPath: $0) }
        d.macToolsHome = tools.path
        #expect(d.locate(appCopyOnly) == .available(path: "\(tools.path)/only/current/bin/only-acp", supportsResume: false))
    }

    @Test func anAppCopyOnlyRuntimeIsNotAHalfInstalledToolset() throws {
        let tools = try onlyTools(whole: false)
        defer { try? FileManager.default.removeItem(at: tools) }
        var d = RuntimeDiscovery(searchPaths: []) { FileManager.default.isExecutableFile(atPath: $0) }
        d.macToolsHome = tools.path
        #expect(!d.locate(appCopyOnly).isAvailable)
    }

}
