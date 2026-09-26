import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A vendor's own installer, run for a runtime that is missing (048).
@Suite("Installing a runtime with its vendor's script", .timeLimit(.minutes(1)))
struct RuntimeInstallerTests {
    /// A folder to search, a folder of fake tools, and a script served from `file://`.
    private struct Scene {
        let root: URL
        var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
        var fakes: URL { root.appendingPathComponent("fakes", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("rti-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("fakes"), withIntermediateDirectories: true)
        }

        func script(_ body: String) throws -> URL {
            let url = root.appendingPathComponent("install-\(UUID().uuidString).sh")
            try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func runtime(_ url: URL, install: RuntimeInstall? = nil) -> Runtime {
            Runtime(id: "grok", name: "Grok", executable: "grok", arguments: [],
                    install: install ?? .script(url: url), installPage: URL(string: "https://x.ai/cli")!)
        }

        func installer(path: String? = nil) -> RuntimeInstaller {
            RuntimeInstaller(discovery: RuntimeDiscovery(searchPaths: [bin.path]), toolset: nil,
                             environment: ["PATH": path ?? "/usr/bin:/bin", "HOME": root.path],
                             timeout: .seconds(20))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aScriptThatPutsTheBinaryWhereTheAppLooksMakesItAvailable() async throws {
        let scene = try Scene()
        defer { scene.remove() }
        let url = try scene.script("""
            printf '#!/bin/sh\\n' > "\(scene.bin.path)/grok"; chmod +x "\(scene.bin.path)/grok"
            """)
        let result = await scene.installer().install(scene.runtime(url)) { _ in }
        #expect(result == .available(path: "\(scene.bin.path)/grok", supportsResume: false))
    }

    @Test func aScriptThatFailsSaysWhatItSaidAndThePageIsOffered() async throws {
        let scene = try Scene()
        defer { scene.remove() }
        try FakeMacToolset.script(at: scene.fakes.appendingPathComponent("bash"), """
            #!/bin/sh
            cat >/dev/null
            echo "downloading…"
            echo "error: this platform is not supported" >&2
            exit 1
            """)
        let url = try scene.script("echo never run by the real bash")
        let runtime = scene.runtime(url)
        let result = await scene.installer(path: "\(scene.fakes.path):/usr/bin:/bin").install(runtime) { _ in }
        guard case .installFailed(let reason) = result else { Issue.record("\(result)"); return }
        #expect(reason.contains("error: this platform is not supported"))
        let status = RuntimeStatus(runtime: runtime, availability: result)
        #expect(status.unavailableReason?.contains("https://x.ai/cli") == true)
    }

    @Test func aScriptThatCannotBeDownloadedFails() async throws {
        let scene = try Scene()
        defer { scene.remove() }
        let result = await scene.installer().install(
            scene.runtime(scene.root.appendingPathComponent("not-there.sh"))) { _ in }
        guard case .installFailed(let reason) = result else { Issue.record("\(result)"); return }
        #expect(reason.contains("curl"), "pipefail: the download's failure, not bash's empty success")
    }

    @Test func exitZeroWithNoBinaryIsNotWhereTheAppLooks() async throws {
        let scene = try Scene()
        defer { scene.remove() }
        let result = await scene.installer().install(scene.runtime(try scene.script("true"))) { _ in }
        guard case .installFailed(let reason) = result else { Issue.record("\(result)"); return }
        #expect(reason.contains("not where the app looks"))
        #expect(reason.contains(scene.bin.path))
    }

    @Test func npmThatCannotWriteItsGlobalFolderIsNotRetriedWithSudo() async throws {
        let scene = try Scene()
        defer { scene.remove() }
        try FakeMacToolset.script(at: scene.bin.appendingPathComponent("npm"), """
            #!/bin/sh
            echo "npm error code EACCES" >&2
            exit 243
            """)
        let runtime = scene.runtime(scene.root, install: .npmGlobal(package: "@github/copilot"))
        let installer = scene.installer()
        #expect(installer.recipe(for: runtime) == .npmGlobal(package: "@github/copilot"))
        let result = await installer.install(runtime) { _ in }
        #expect(result == .installFailed(reason: "npm can’t write its global folder."))
    }

    @Test func npmGlobalIsOfferedOnlyWithAnNpm() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let runtime = scene.runtime(scene.root, install: .npmGlobal(package: "@github/copilot"))
        #expect(scene.installer().recipe(for: runtime) == nil)
    }

    @Test func claudeIsOfferedOnlyWhenTheBuildCarriesItsToolset() throws {
        let scene = try Scene()
        defer { scene.remove() }
        #expect(scene.installer().recipe(for: RuntimeCatalog.claude) == nil)
        var withToolset = scene.installer()
        withToolset.toolset = MacToolsetInstaller(toolset: try Toolset.load(from: ToolsetTests.bundled),
                                                  tools: scene.root)
        #expect(withToolset.recipe(for: RuntimeCatalog.claude) == .toolset(runtimeID: "claude"))
    }
}
