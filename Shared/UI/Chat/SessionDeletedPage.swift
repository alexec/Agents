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
