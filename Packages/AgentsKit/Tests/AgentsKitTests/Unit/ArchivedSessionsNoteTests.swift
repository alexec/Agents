import Testing
@testable import AgentsKitCore

/// What a folder's Archived page says under its sessions (#664): loading, a silent
/// host and a capped page are not an empty archive.
@Suite("The Archived page's note")
struct ArchivedSessionsNoteTests {
    private let cap = SidebarFolderFold.archivedShown

    @Test func anEmptyListIsLoadingUntilTheHostAnswers() {
        #expect(ArchivedSessionsNote.note(shown: 0, total: 3, answered: nil, hostOffline: false) == .loading)
        #expect(ArchivedSessionsNote.note(shown: 0, total: 0, answered: true, hostOffline: false) == ArchivedSessionsNote.none)
    }

    @Test func aFailedAskOrAnOfflineHostIsNotAnEmptyArchive() {
        #expect(ArchivedSessionsNote.note(shown: 0, total: 0, answered: false, hostOffline: false) == .hostSilent)
        #expect(ArchivedSessionsNote.note(shown: 0, total: 0, answered: nil, hostOffline: true) == .hostSilent)
    }

    @Test func aFullPageSaysHowManyThereAre() {
        #expect(ArchivedSessionsNote.note(shown: cap, total: 300, answered: true, hostOffline: false)
            == .capped(shown: cap, total: 300))
        #expect(ArchivedSessionsNote.note(shown: cap, total: cap, answered: true, hostOffline: false) == nil)
        #expect(ArchivedSessionsNote.note(shown: 12, total: 12, answered: true, hostOffline: false) == nil)
        #expect(ArchivedSessionsNote.capped(shown: 50, total: 300).text == "The newest 50 of 300. Search to find an older one.")
    }
}
