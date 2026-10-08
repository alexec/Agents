import Foundation
import Testing
@testable import AgentsKitCore

/// The words for deleting archived agents (051, #398), as each client shows them.
@Suite("Deletion words")
struct DeletionWordsTests {
    @Test func theConfirmation() {
        #expect(DeletionWords.confirmTitle("Title") == "Delete \u{201C}Title\u{201D}?")
        #expect(DeletionWords.confirmTitle("  ") == "Delete this session?")
        #expect(DeletionWords.confirmTitle(nil) == "Delete this session?")
        #expect(DeletionWords.confirmMessage == "Its conversation and record are removed. This cannot be undone.")
    }

    @Test func settings() {
        #expect(DeletionWords.settingsSummary(archivedCount: 263, archivedBytes: 791_000_000,
                                              settings: RetentionSettings())
                == "263 archived agents, 791 MB. Each is deleted 30 days after it was archived.")
        #expect(DeletionWords.settingsSummary(archivedCount: 1, archivedBytes: 5_000_000,
                                              settings: RetentionSettings(keepFor: .forever))
                == "1 archived agent, 5 MB. Archived agents are kept until you delete them.")
        #expect(DeletionWords.confirmSettings(count: 41, bytes: 584_000_000)
                == "This deletes 41 archived agents now and frees 584 MB. Their conversations are deleted and cannot be brought back.")
        #expect(DeletionWords.keepForLabel(.forever) == "Never")
    }

    /// A file from before #398 has a size cap too; it is read without one.
    @Test func anOlderSettingsFileReadsWithoutItsCap() throws {
        let old = Data(#"{"keepFor":"days14","cap":"gb2"}"#.utf8)
        #expect(try JSONDecoder().decode(RetentionSettings.self, from: old) == RetentionSettings(keepFor: .days14))
    }
}
