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

    // MARK: A runtime that runs only the app's copy (046)

    private let appOnly = Runtime(id: "gemini", name: "Gemini", executable: "gemini", arguments: ["--acp"],
                                  install: .toolset(runtimeID: "gemini"), usesAppCopyOnly: true)

    private func geminiTools(whole: Bool) throws -> URL {
        let tools = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        let set = tools.appendingPathComponent("gemini/def456", isDirectory: true)
        try FileManager.default.createDirectory(at: set.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: set.appendingPathComponent("bin/gemini").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        if whole { FileManager.default.createFile(atPath: set.appendingPathComponent("ok").path, contents: Data()) }
        try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent("gemini/current").path,
                                                   withDestinationPath: "def456")
        return tools
    }

    private func discovery(tools: URL?, geminiOnPath: Bool) -> RuntimeDiscovery {
        var d = RuntimeDiscovery(searchPaths: ["/person/bin"]) { path in
            path == "/person/bin/gemini" ? geminiOnPath : FileManager.default.isExecutableFile(atPath: path)
        }
        d.macToolsHome = tools?.path
        return d
    }

    @Test func thePersonsOwnCopyIsNeverUsedForAnAppOnlyRuntime() {
        #expect(!discovery(tools: nil, geminiOnPath: true).locate(appOnly).isAvailable)
    }

    @Test func thePersonsOwnCopyDoesNotBeatTheApps() throws {
        let tools = try geminiTools(whole: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        #expect(discovery(tools: tools, geminiOnPath: true).locate(appOnly)
                == .available(path: "\(tools.path)/gemini/current/bin/gemini", supportsResume: false))
    }

    @Test func anAppOnlyRuntimeNeedsAWholeToolset() throws {
        let tools = try geminiTools(whole: false)
        defer { try? FileManager.default.removeItem(at: tools) }
        #expect(discovery(tools: tools, geminiOnPath: true).locate(appOnly)
                == .missing(lookedIn: ["\(tools.path)/gemini/current/bin"]))
    }
}
