import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Changing one key in a file somebody wrote.
///
/// This is the only thing in the app that writes into a person's own file. A failure
/// here is not a failing test: it is the app having moved something nobody asked it to
/// move, in a repository, in a diff somebody is going to read. `everyWorkflowInThisRepositoryRoundTrips`
/// is the one that would catch it — it sets a key and takes it away again, and expects
/// the file back byte for byte.
@Suite("Changing one key in a file somebody wrote")
struct FrontMatterEditTests {
    private let sample = """
        ---
        name: Morning build check
        on:
          - schedule:
              at: [":00"]
              model: something-nested
        agent: new   # a fresh one every time
        ---

        Check whether the build is still green.

        ---

        Don't fix anything.
        """

    // MARK: What it does

    @Test func addingAKeyPutsItJustInsideTheFence() throws {
        let edited = try FrontMatterEdit.set("permission-mode", to: "plan", in: sample)
        #expect(edited.contains("agent: new   # a fresh one every time\npermission-mode: plan\n---"))
    }

    @Test func changingAValueLeavesTheCommentAfterIt() throws {
        let edited = try FrontMatterEdit.set("agent", to: "triggering", in: sample)
        #expect(edited.contains("agent: triggering   # a fresh one every time"))
        #expect(!edited.contains("agent: new"))
    }

    @Test func theBodyIsReturnedByteForByte() throws {
        let edited = try FrontMatterEdit.set("permission-mode", to: "plan", in: sample)
        // The body has its own `---` in it, which is a horizontal rule and not a fence.
        let body = FrontMatter.strip(edited)
        #expect(body == FrontMatter.strip(sample))
        #expect(body.contains("\n---\n"))
    }

    @Test func anIndentedKeyOfTheSameNameIsNotTouched() throws {
        let edited = try FrontMatterEdit.set("model", to: "grok-4", in: sample)
        #expect(edited.contains("      model: something-nested"))
        #expect(edited.contains("\nmodel: grok-4\n---"))
    }

    @Test func removingAKeyTakesOnlyItsLine() throws {
        let edited = try FrontMatterEdit.set("name", to: nil, in: sample)
        #expect(!edited.contains("Morning build check"))
        #expect(edited.hasPrefix("---\non:\n"))
        #expect(edited.contains("agent: new   # a fresh one every time"))
    }

    @Test func aValueThatWouldNotReadBackPlainIsQuoted() throws {
        let edited = try FrontMatterEdit.set("model", to: "# not a comment", in: sample)
        #expect(edited.contains("model: \"# not a comment\""))
    }

    // MARK: What it will not do

    @Test func aDocumentWithNoFrontMatterIsRefused() {
        #expect(throws: FrontMatterEdit.Refusal.self) {
            try FrontMatterEdit.set("model", to: "grok-4", in: "Just a prompt, no metadata.\n")
        }
        #expect(throws: FrontMatterEdit.Refusal.self) {
            try FrontMatterEdit.set("model", to: "grok-4", in: "---\nname: Unclosed\n")
        }
    }

    @Test func aKeyTwiceIsRefusedRatherThanPicked() {
        let twice = """
            ---
            model: one
            on: agent-finished
            model: two
            ---

            Go.
            """
        #expect(throws: FrontMatterEdit.Refusal.self) {
            try FrontMatterEdit.set("model", to: "three", in: twice)
        }
    }

    @Test func aKeyWithAListUnderItIsRefused() {
        let listed = """
            ---
            model:
              - one
              - two
            on: agent-finished
            ---

            Go.
            """
        #expect(throws: FrontMatterEdit.Refusal.self) {
            try FrontMatterEdit.set("model", to: "three", in: listed)
        }
        #expect(throws: FrontMatterEdit.Refusal.self) {
            try FrontMatterEdit.set("on", to: "agent-stopped", in: sample)
        }
    }

    // MARK: A key under a block

    @Test func aKeyUnderABlockThatIsNotThereAddsTheBlock() throws {
        let edited = try FrontMatterEdit.set("fast", under: "options", to: "true", in: sample)
        #expect(edited.contains("agent: new   # a fresh one every time\noptions:\n  fast: true\n---"))
        // And taking it away again gives the file back byte for byte.
        #expect(try FrontMatterEdit.set("fast", under: "options", to: nil, in: edited) == sample)
    }

    @Test func aKeyUnderABlockIsChangedInItsOwnIndentation() throws {
        let source = "---\non: [x]\noptions:\n    fast: false  # quick\n    allow_all: on\nagent: new\n---\n\nGo.\n"
        let edited = try FrontMatterEdit.set("fast", under: "options", to: "true", in: source)
        #expect(edited == source.replacingOccurrences(of: "fast: false", with: "fast: true"))
        let added = try FrontMatterEdit.set("speed", under: "options", to: "high", in: source)
        #expect(added.contains("    allow_all: on\n    speed: high\nagent: new"))
    }

    @Test func theLastKeyUnderABlockTakesTheBlockWithIt() throws {
        let source = "---\non: [x]\noptions:\n  fast: true\nagent: new\n---\n\nGo.\n"
        let edited = try FrontMatterEdit.set("fast", under: "options", to: nil, in: source)
        #expect(edited == "---\non: [x]\nagent: new\n---\n\nGo.\n")
    }

    @Test func aBlockWrittenOnOneLineIsRefused() {
        let source = "---\non: [x]\noptions: {fast: true}\n---\n\nGo.\n"
        #expect(throws: FrontMatterEdit.Refusal.self) {
            try FrontMatterEdit.set("fast", under: "options", to: "false", in: source)
        }
    }

    @Test func windowsLineEndingsSurvive() throws {
        let windows = sample.replacingOccurrences(of: "\n", with: "\r\n")
        let edited = try FrontMatterEdit.set("permission-mode", to: "plan", in: windows)
        #expect(edited.contains("\r\npermission-mode: plan\r\n---"))
        #expect(!edited.contains("\n\n"))
    }

    // MARK: The one that would catch it

    @Test func everyWorkflowInThisRepositoryRoundTrips() throws {
        // The samples are here so this cannot pass vacuously in a checkout with no
        // workflows in it. The real files are the point: they were written by hand and
        // by agents, and they are the shapes this has to survive.
        var subjects = [("the suite's sample", sample)]
        for url in workflowFiles() {
            subjects.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        for (name, original) in subjects {
            let added = try FrontMatterEdit.set("x-round-trip", to: "yes", in: original)
            #expect(added != original, "nothing was added to \(name)")
            let removed = try FrontMatterEdit.set("x-round-trip", to: nil, in: added)
            #expect(removed == original, "\(name) did not come back as it was")
        }
    }

    /// Every workflow file in this repository, found by walking `#filePath` up to the
    /// root the way `MarkdownBlockTests` does.
    private func workflowFiles() -> [URL] {
        var root = URL(filePath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appending(path: "project.yml").path) {
            root.deleteLastPathComponent()
        }
        let folder = root.appending(path: ".agents/workflows", directoryHint: .isDirectory)
        let found = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return (found ?? []).filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
    }
}
