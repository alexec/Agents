import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Where a server's daemon finds Claude (043, R4): the app's toolset first, when whole.
@Suite("Finding Claude on a server")
struct ServerDiscoveryTests {
    private func home(withToolset whole: Bool?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("disc-\(UUID().uuidString)")
        if let whole {
            let set = home.appendingPathComponent(".agents-server/tools/claude/abc123", isDirectory: true)
            try FileManager.default.createDirectory(at: set.appendingPathComponent("bin"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: set.appendingPathComponent("bin/npx").path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o700])
            if whole { FileManager.default.createFile(atPath: set.appendingPathComponent("ok").path, contents: Data()) }
            try FileManager.default.createSymbolicLink(
                atPath: home.appendingPathComponent(".agents-server/tools/claude/current").path, withDestinationPath: "abc123")
        } else {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        return home
    }

    private func discovery(home: URL?, npxOnPath: Bool) -> RuntimeDiscovery {
        var d = RuntimeDiscovery(searchPaths: ["/person/bin"]) { path in
            path == "/person/bin/npx" ? npxOnPath : FileManager.default.isExecutableFile(atPath: path)
        }
        d.serverHome = home?.path
        return d
    }

    @Test func theToolsetComesBeforeThePersonsOwnNpx() throws {
        let home = try home(withToolset: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let found = discovery(home: home, npxOnPath: true).locate(RuntimeCatalog.claude)
        #expect(found == .available(path: "\(home.path)/.agents-server/tools/claude/current/bin/npx", supportsResume: false))
    }

    @Test func aToolsetWithoutOkIsNeverUsed() throws {
        let home = try home(withToolset: false)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(discovery(home: home, npxOnPath: true).locate(RuntimeCatalog.claude)
                == .available(path: "/person/bin/npx", supportsResume: false))
    }

    @Test func theMacNeverLooksThere() throws {
        let home = try home(withToolset: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(discovery(home: nil, npxOnPath: false).locate(RuntimeCatalog.claude)
                == .missing(lookedIn: ["/person/bin"]))
    }

    @Test func otherRuntimesAreFoundAsBefore() throws {
        let home = try home(withToolset: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(discovery(home: home, npxOnPath: false).locate(RuntimeCatalog.grok) == .missing(lookedIn: ["/person/bin"]))
    }
}
