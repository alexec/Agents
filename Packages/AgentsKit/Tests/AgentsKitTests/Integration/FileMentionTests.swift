import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Naming a file with an `@` from a phone (033).
///
/// The Mac's window walks its own disk for these. A phone has no disk of the Mac's to
/// walk, so the daemon does the same capped walk for it and answers with the Mac's
/// paths, which is where the agent reads them.
@Suite("Files named with an @, found by the daemon", .timeLimit(.minutes(1)))
struct FileMentionTests {
    private func temporary() throws -> (StoreLocations, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsMentionTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: work.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try manager.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: work.appendingPathComponent("Sources/Transcript.swift"))
        try Data("x".utf8).write(to: work.appendingPathComponent("README.md"))
        try Data("x".utf8).write(to: extra.appendingPathComponent("TranscriptNotes.md"))
        return (StoreLocations(root: root), work, extra)
    }

    private func core(locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: FakeLauncher(script: FakeACPAgent.Script()))
    }

    @Test func aTermFindsTheFileUnderTheAgentsFolderByItsMacPath() async throws {
        let (locations, work, _) = try temporary()
        let core = try core(locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "hello"))

        let answer = await core.handle(method: DaemonAPI.Method.filesMention,
                                       params: try JSONValue.encoding(DaemonAPI.FileMentionRequest(agentID: id, term: "Transc")))
        guard case .success(let value) = answer else { Issue.record("expected an answer"); return }
        let found = try value.decode([DaemonAPI.FileMentionDTO].self)
        #expect(found.map(\.relativePath) == ["Sources/Transcript.swift"])
        #expect(found.first.map { URL(filePath: $0.path).standardizedFileURL.path }
                == work.appendingPathComponent("Sources/Transcript.swift").standardizedFileURL.path)
    }

    @Test func theFoldersTheAgentWasGivenAreSearchedToo() async throws {
        let (locations, work, extra) = try temporary()
        let core = try core(locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "hello",
                                            additionalDirectories: [extra]))
        let found = try await core.fileMentions(.init(agentID: id, term: "Transcript"))
        #expect(Set(found.map { URL(filePath: $0.path).lastPathComponent })
                == ["Transcript.swift", "TranscriptNotes.md"])
    }

    @Test func nothingTypedIsNothingWalked() async throws {
        let (locations, work, _) = try temporary()
        let core = try core(locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "hello"))
        #expect(try await core.fileMentions(.init(agentID: id, term: "")).isEmpty)
    }

    @Test func anAgentThatIsNotHereIsSaidSo() async throws {
        let (locations, _, _) = try temporary()
        let core = try core(locations: locations)
        let answer = await core.handle(method: DaemonAPI.Method.filesMention,
                                       params: try JSONValue.encoding(DaemonAPI.FileMentionRequest(agentID: UUID(), term: "a")))
        guard case .failure(let error) = answer else { Issue.record("expected a refusal"); return }
        #expect(error.code == DaemonAPI.Failure.noSuchAgent)
    }

    // MARK: What is left out

    /// Build output and what the project ignores. An index record under `build/DD`
    /// matched "PromptBar" before the source did, on the Mac and the phone alike.
    @Test func buildOutputAndWhatGitIgnoresAreNotOffered() async throws {
        let (locations, work, _) = try temporary()
        let manager = FileManager.default
        for folder in ["build/DD/Index", "DerivedData/x", "Generated", "Sources/out"] {
            try manager.createDirectory(at: work.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["build/DD/Index/Transcript.swift-1RMN", "DerivedData/x/Transcript.o",
                     "Generated/TranscriptModel.swift", "Sources/out/TranscriptOut.swift",
                     "Sources/Transcript.xcuserstate"] {
            try Data("x".utf8).write(to: work.appendingPathComponent(file))
        }
        try Data("# ours\n/Generated/\n*.xcuserstate\nSources/out/\n!keep.txt\nweird/*/glob\n".utf8)
            .write(to: work.appendingPathComponent(".gitignore"))
        let core = try core(locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "hello"))

        let found = try await core.fileMentions(.init(agentID: id, term: "Transcript"))
        #expect(found.map(\.relativePath) == ["Sources/Transcript.swift"])
    }

    @Test func onlyTheShapesOfGitignoreItCanHonourAreRead() {
        typealias Rule = MentionIgnore.Rule
        #expect(MentionIgnore.rule("build/") == Rule(kind: .name("build"), directoriesOnly: true))
        #expect(MentionIgnore.rule("/DerivedData") == Rule(kind: .path("DerivedData"), directoriesOnly: false))
        #expect(MentionIgnore.rule(".claude/worktrees/") == Rule(kind: .path(".claude/worktrees"), directoriesOnly: true))
        #expect(MentionIgnore.rule("*.xcuserstate") == Rule(kind: .suffix(".xcuserstate"), directoriesOnly: false))
        #expect(MentionIgnore.rule("# a comment") == nil)
        #expect(MentionIgnore.rule("!keep.txt") == nil)
        #expect(MentionIgnore.rule("weird/*/glob") == nil)
        #expect(MentionIgnore.rule("*.o*") == nil)

        let ignore = MentionIgnore(gitignore: "xcuserdata/\n/Top\n")
        #expect(ignore.skips("a/b/xcuserdata", isDirectory: true))
        // A rule for folders does not hide a file of the same name.
        #expect(!ignore.skips("a/b/xcuserdata", isDirectory: false))
        #expect(ignore.skips("Top", isDirectory: false))
        #expect(!ignore.skips("nested/Top", isDirectory: false))
        #expect(ignore.skips("App/build", isDirectory: true))
        #expect(!ignore.skips("App/build.swift", isDirectory: false))
    }
}
