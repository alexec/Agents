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

    /// Every toolset the app carries, beside Claude's (047).
    static let allBundled = bundled.deletingLastPathComponent()

    @Test func everyBundledToolsetIsLoadedByTheRuntimeItsManifestNames() {
        let toolsets = Toolset.loadAll(from: Self.allBundled)
        #expect(toolsets["claude"]?.manifest.package == "@agentclientprotocol/claude-agent-acp")
        #expect(toolsets["codex"]?.manifest.package == "@agentclientprotocol/codex-acp")
        for (runtimeID, toolset) in toolsets { #expect(toolset.manifest.runtimeID == runtimeID) }
    }

    @Test func codexsToolsetPinsItsAdapterAndCarriesCodexForEveryPlatform() throws {
        let folder = Self.allBundled.appendingPathComponent("codex", isDirectory: true)
        let toolset = try Toolset.load(from: folder)
        #expect(toolset.manifest.entry == "dist/index.js")
        #expect(toolset.manifest.minFreeBytes == 1_073_741_824)
        #expect(toolset.manifest.forwardsArguments == nil)
        #expect(toolset.macNode?.sha256.keys.sorted() == ["arm64", "x64"])
        let lock = try String(contentsOf: folder.appendingPathComponent(Toolset.lockFile), encoding: .utf8)
        for platform in ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"] {
            #expect(lock.contains("\"node_modules/@openai/codex-\(platform)\""))
        }
    }

    @Test func theShimRunsThePinnedPackageAndForwardsArgumentsOnlyWhenAsked() throws {
        var toolset = try Toolset.load(from: Self.bundled)
        #expect(toolset.shimName == "npx")
        #expect(toolset.shimLines.count == 4)
        #expect(toolset.shimLines[1] == "# Agents: runs the @agentclientprotocol/claude-agent-acp this toolset was installed with.")
        #expect(toolset.shimLines[3].hasSuffix(#"/claude-agent-acp/dist/index.js""#))
        #expect(!toolset.shimLines.joined().contains("'"))
        toolset.manifest.forwardsArguments = true
        #expect(toolset.shimLines[3].hasSuffix(#"dist/index.js" "$@""#))
    }

    // MARK: Gemini's (046)

    static var bundledGemini: URL { allBundled.appendingPathComponent("gemini", isDirectory: true) }

    @Test func geminisToolsetIsLoadedAndItsShimHandsOnItsArguments() throws {
        let toolset = try Toolset.load(from: Self.bundledGemini)
        #expect(Toolset.loadAll(from: Self.allBundled)["gemini"]?.id == toolset.id)
        #expect(toolset.manifest.package == "@google/gemini-cli")
        #expect(toolset.manifest.forwardsArguments == true)
        #expect(toolset.shimName == "gemini")
        #expect(toolset.manifest.entryPath == "lib/node_modules/@google/gemini-cli/bundle/gemini.js")
        #expect(toolset.shimLines.last?.hasSuffix(#"bundle/gemini.js" "$@""#) == true)
        #expect(toolset.macNode?.sha256.keys.sorted() == ["arm64", "x64"])
    }
}
