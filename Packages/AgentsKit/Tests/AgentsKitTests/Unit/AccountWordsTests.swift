import AgentsKitCore
import Foundation
import Testing

/// The words of an added account that the Mac and the Remote share (#2264, #2265).
struct AccountWordsTests {
    @Test func removeCountsTheSessionsAndCannotBeUndone() {
        #expect(AccountWords.removeMessage(stopping: 0, from: "this Mac")
                == "Nothing is running on it. Its sign-in is deleted from this Mac. This can’t be undone.")
        #expect(AccountWords.removeMessage(stopping: 1, from: "the Mac")
                == "This stops 1 session mid-conversation. Its sign-in is deleted from the Mac. This can’t be undone.")
    }

    @Test func aChoiceSaysWhyItCannotBeUsed() {
        let work = AccountProfile(id: "work", runtimeID: "claude", name: "Work", reach: .signIn(folder: "/w"),
                                  signedIn: true, signedInAs: "a@b.c")
        var notSignedIn = work
        notSignedIn.signedIn = false
        #expect(AccountWords.choiceNote(notSignedIn, row: nil, now: Date()) == "Not signed in")
        #expect(AccountWords.choiceNote(work, row: nil, now: Date()) == "a@b.c")
        #expect(AccountWords.choiceNote(nil, row: nil, now: Date()) == nil)
    }
}
