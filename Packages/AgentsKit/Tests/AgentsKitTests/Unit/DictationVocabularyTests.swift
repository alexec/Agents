import Foundation
import Testing
@testable import AgentsKitCore

/// #2515: the transcriber is seeded with the product's words, the open folders, and
/// the selected folder's titles and issue numbers. Long titles stay out.
@Suite("Dictation vocabulary")
struct DictationVocabularyTests {
    @Test func theProductsWordsComeFirst() {
        let seeds = DictationVocabulary.merging(["Agents"])
        #expect(seeds.starts(with: ["GitHub", "GitLab", "TestFlight", "worktree"]))
        #expect(seeds.contains("merge wave"))
        #expect(seeds.contains("Scrum Master"))
        #expect(seeds.contains("control plane"))
        #expect(seeds.contains("Claude"))
        #expect(seeds.contains("OpenCode"))
        #expect(seeds.contains("Agents"))
    }

    @Test func aRepeatedNameIsOneSeed() {
        let seeds = DictationVocabulary.merging(["github", "GitHub", "GitHub"])
        #expect(seeds.filter { $0.compare("github", options: .caseInsensitive) == .orderedSame }.count == 1)
    }

    @Test func aSentenceIsNotAName() {
        let seeds = DictationVocabulary.merging(["Fix the crash in the prompt bar today"])
        #expect(!seeds.contains("Fix the crash in the prompt bar today"))
    }

    @Test func issueNumbersComeFromLabelsAndTitles() {
        #expect(DictationVocabulary.issueNumber("2515") == "2515")
        #expect(DictationVocabulary.issueNumber("#2444") == "2444")
        #expect(DictationVocabulary.issueNumber("lane") == nil)
        #expect(DictationVocabulary.issueNumber("12") == nil)
        #expect(DictationVocabulary.issueNumbers(in: "Voice mode #2515 and #12") == ["2515"])
    }

    @Test func seedsUseTheOpenFolderAndSkipAnArchivedSession() throws {
        let folderURL = URL(fileURLWithPath: "/tmp/agents-dictation-vocab")
        let folder = DaemonAPI.FolderSummary(
            folder: Folder(folder: folderURL), name: "Agents", exists: true,
            lastActivityAt: Date(), counts: [:])
        let archivedFolder = DaemonAPI.FolderSummary(
            folder: Folder(folder: URL(fileURLWithPath: "/tmp/agents-dictation-old"), archivedAt: Date()),
            name: "Old", exists: true, lastActivityAt: Date(), counts: [:])
        let live = Agent(runtimeID: "claude", cwd: folderURL, title: "Sidebar",
                         labels: [SessionLabel(value: "#2515", owner: .person)], state: .running)
        let archived = Agent(runtimeID: "claude", cwd: folderURL, title: "Gone", state: .archived)
        let elsewhere = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp/agents-dictation-other"),
                              title: "Other", state: .running)
        let seeds = DictationVocabulary.seeds(
            folders: [folder, archivedFolder], agents: [live, archived, elsewhere], in: folderURL)
        #expect(seeds.contains("Agents"))
        #expect(seeds.contains("Sidebar"))
        #expect(seeds.contains("2515"))
        #expect(!seeds.contains("Old"))
        #expect(!seeds.contains("Gone"))
        #expect(!seeds.contains("Other"))
    }
}
