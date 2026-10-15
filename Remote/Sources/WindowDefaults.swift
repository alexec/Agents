import Foundation

/// Where the views shared with the Mac (`Shared/UI`) keep their preferences. The Mac's own
/// gives a scratch copy of the window a domain of its own (#1029); there are no scratch
/// copies of the Remote, so here it is the app's own defaults.
enum WindowDefaults {
    nonisolated(unsafe) static let store = UserDefaults.standard
}
