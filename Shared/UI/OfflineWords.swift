import AgentsKitCore
import Foundation

/// What the strip over a chat says when its host is down (#83, #239), once for both
/// apps. This Mac's host down is not the same news as a server's: nothing of this
/// Mac's moves until it is back, so it does not say the agents keep working.
enum OfflineWords {
    static func line(host: HostID, name: String, since: String?) -> String {
        let since = since.map { " since \($0)" } ?? ""
        return host == .mac
            ? "This Mac’s host hasn’t answered\(since). Nothing here can change until it’s back. Trying again…"
            : "\(name) is offline\(since). Agents there keep working."
    }
}
