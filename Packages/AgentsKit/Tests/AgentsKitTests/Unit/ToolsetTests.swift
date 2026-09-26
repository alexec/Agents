import Foundation
import Testing
@testable import AgentsKitCore

/// The pinned toolset the app installs on servers (043, R2).
@Suite("A runtime's toolset")
struct ToolsetTests {
    static let bundled = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/toolsets/claude", isDirectory: true)

    @Test func theBundledClaudeToolsetReadsAndNamesBothArchitectures() throws {
        let toolset = try Toolset.load(from: Self.bundled)
        #expect(toolset.manifest.runtimeID == "claude")
        #expect(toolset.id.count == 16)
        #expect(toolset.manifest.nodeSHA256(for: .x86_64)?.count == 64)
        #expect(toolset.manifest.nodeSHA256(for: .aarch64)?.count == 64)
        #expect(toolset.manifest.nodeSHA256(for: .other("riscv64")) == nil)
        #expect(toolset.manifest.nodeTarball(for: .aarch64)?.hasSuffix("-linux-arm64.tar.xz") == true)
        #expect(toolset.manifest.entryPath.hasPrefix("lib/node_modules/@agentclientprotocol/claude-agent-acp/"))
    }

    @Test func theLockCarriesTheClaudeBinaryForBothLinuxArchitectures() throws {
        let lock = try String(contentsOf: Self.bundled.appendingPathComponent(Toolset.lockFile), encoding: .utf8)
        #expect(lock.contains("claude-agent-sdk-linux-x64\""))
        #expect(lock.contains("claude-agent-sdk-linux-arm64\""))
        #expect(lock.contains("\"integrity\""))
    }

    @Test func anyChangeToTheManifestOrLockIsANewToolset() {
        let manifest = Data("{\"a\":1}".utf8), lock = Data("{}".utf8)
        let id = Toolset.id(manifest: manifest, lock: lock)
        #expect(id == Toolset.id(manifest: manifest, lock: lock))
        #expect(id != Toolset.id(manifest: Data("{\"a\":2}".utf8), lock: lock))
        #expect(id != Toolset.id(manifest: manifest, lock: Data("{ }".utf8)))
        #expect(id.allSatisfy { $0.isHexDigit })
    }
}
