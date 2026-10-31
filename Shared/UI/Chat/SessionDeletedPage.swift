import AgentsKitCore
import SwiftUI

/// What a chat shows when the session it was opened on has gone (#826, #2651): in a
/// session's own window on the Mac and the phone, and in the main window when the
/// selection names a session there is no more. One copy of the words for all of them.
struct SessionDeletedPage: View {
    /// Where the person goes next.
    enum Next {
        /// A window of its own, which has nothing else to show.
        case closeWindow
        /// A window with a sidebar of sessions.
        case pickAnother
        /// A phone's stack of screens, with the list one Back away (#2652).
        case goBack
    }

    let next: Next

    var body: some View {
        ContentUnavailableView("This session was deleted", systemImage: "trash",
                               description: Text(description))
    }

    private var description: String {
        switch next {
        case .closeWindow: "There is nothing left of it to show. Close this window."
        case .pickAnother: "There is nothing left of it to show. Pick another session on the left."
        case .goBack: "There is nothing left of it to show. Go back to pick another session."
        }
    }
}

/// What a chat shows in place of a session not in hand whose lookup failed (#2743): the
/// machine offline, or no answer in time. Not called deleted, which only its host saying
/// it has no such session shows; said with Try Again, as the chat's own failure line (#400).
struct SessionNotLoadedPage: View {
    let failure: TranscriptLoadFailure
    let retry: @MainActor () async -> Void
    @State private var retrying = false

    var body: some View {
        ContentUnavailableView {
            Label("This session did not load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.reason)
        } actions: {
            Button("Try Again") {
                retrying = true
                Task {
                    await retry()
                    retrying = false
                }
            }
            .disabled(retrying)
        }
    }
}
