import AgentsKitCore
import Foundation

/// Since when each server that was connected has been gone, and the moments it went
/// and came back (037, 042's `server.offline` and `server.online`).
///
/// The window's retries pass through `connecting` again and again while a server is
/// gone; this keeps the first "since" through them, and says each going and each coming
/// back once. A server that was never connected in this window has not gone offline:
/// it has not arrived yet.
public struct ServerReachability: Sendable {
    public enum Edge: Sendable, Equatable {
        case wentOffline
        case cameBack
    }

    public private(set) var offlineSince: [HostID: Date] = [:]

    public init() {}

    /// A server's new state, and whether that was it going or coming back.
    public mutating func moved(_ id: HostID, to state: ServerConnection.State) -> Edge? {
        switch state {
        // Waiting to update is still talking to the old daemon: it is there.
        case .connected, .updateWaiting:
            return offlineSince.removeValue(forKey: id) == nil ? nil : .cameBack
        case .offline(let since):
            guard offlineSince[id] == nil else { return nil }
            offlineSince[id] = since
            return .wentOffline
        case .idle, .connecting, .failed:
            return nil
        }
    }

    /// A server taken out of the window: nothing more to say about it.
    public mutating func forget(_ id: HostID) {
        offlineSince[id] = nil
    }
}
